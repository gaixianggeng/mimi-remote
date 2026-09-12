//! 通过 CLI 的 SDK initialize 控制请求读取目录，不发送 user 消息。

use std::path::Path;
use std::time::{Duration, Instant};

use alleycat_bridge_core::{ProcessLauncher, ProcessSpec, StdioMode};
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeModelInfo {
    pub value: String,
    pub display_name: String,
    #[serde(default)]
    pub resolved_model: Option<String>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub supports_effort: Option<bool>,
    #[serde(default)]
    pub supported_effort_levels: Option<Vec<String>>,
}

pub(super) async fn discover(
    launcher: &dyn ProcessLauncher,
    claude_bin: &Path,
) -> Result<Vec<ClaudeModelInfo>> {
    discover_with_timeout(launcher, claude_bin, Duration::from_secs(10)).await
}

async fn discover_with_timeout(
    launcher: &dyn ProcessLauncher,
    claude_bin: &Path,
    timeout: Duration,
) -> Result<Vec<ClaudeModelInfo>> {
    let mut spec = ProcessSpec::new(claude_bin);
    // 查询独立于会话进程，避免 initialize 干扰正在运行的 turn。
    // 保留 CLI 的账号/模型配置，但关闭工具、MCP 和用户 hooks，且不写会话历史。
    spec.args = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--tools",
        "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--settings",
        r#"{"disableAllHooks":true}"#,
    ]
    .into_iter()
    .map(Into::into)
    .collect();
    spec.stderr = StdioMode::Null;
    let mut child = tokio::time::timeout(timeout, launcher.launch(spec)).await??;
    let result = tokio::time::timeout(timeout, async {
        let mut stdin = child.take_stdin().context("missing CLI stdin")?;
        let stdout = child.take_stdout().context("missing CLI stdout")?;
        let request = json!({
            "type": "control_request",
            "request_id": "model-catalog",
            "request": { "subtype": "initialize" },
        });
        stdin.write_all(format!("{request}\n").as_bytes()).await?;
        stdin.flush().await?;
        // initialize 还会返回 commands 等信息；限定总读取量，防止异常输出无限占用内存。
        let mut lines = BufReader::new(stdout.take(1024 * 1024)).lines();
        while let Some(line) = lines.next_line().await? {
            let Ok(frame) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            if frame["type"] != "control_response"
                || frame["response"]["request_id"] != "model-catalog"
            {
                continue;
            }
            if frame["response"]["subtype"] != "success" {
                // CLI 错误可能带账号信息；只返回固定诊断，不透传原始响应。
                bail!("CLI rejected model catalog initialization");
            }
            return serde_json::from_value(frame["response"]["response"]["models"].clone())
                .context("invalid CLI model catalog");
        }
        bail!("CLI exited without a model catalog")
    })
    .await
    .context("CLI model catalog timed out")
    .and_then(|result| result);
    // stdin 在上面的查询完成/取消时关闭。无论成功还是超时，都回收短命查询进程。
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

/// 目录有效期。CLI 目录只随 CLI 升级变化，10 分钟内重复查询没有意义。
pub const CATALOG_TTL: Duration = Duration::from_secs(10 * 60);
/// 发现失败后的冷却：期间不再为每个 model/list 都起一个 CLI。
pub const CATALOG_FAILURE_COOLDOWN: Duration = Duration::from_secs(15);
/// 按需查询的超时；启动预热允许更久，CLI 冷启动可能超过 10 秒。
pub const CATALOG_QUERY_TIMEOUT: Duration = Duration::from_secs(10);
pub const CATALOG_WARM_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Default)]
struct CatalogState {
    models: Option<Vec<ClaudeModelInfo>>,
    fetched_at: Option<Instant>,
    failed_at: Option<Instant>,
}

/// 进程级目录缓存。此前每次 `model/list` 都现起一个 CLI 做发现，首次失败或超时
/// 就回退成无版本别名，而客户端会把这次结果缓存几分钟——用户看到的就是"第一次
/// 打开只有 Opus / Sonnet / Haiku，第二次才正常"。这里做三件事：缓存、单飞
/// （并发调用等同一次发现）、发现失败时优先返回上一次成功的目录。
pub struct ModelCatalogCache {
    state: tokio::sync::Mutex<CatalogState>,
    ttl: Duration,
    failure_cooldown: Duration,
}

impl Default for ModelCatalogCache {
    fn default() -> Self {
        Self::with_limits(CATALOG_TTL, CATALOG_FAILURE_COOLDOWN)
    }
}

impl ModelCatalogCache {
    pub fn with_limits(ttl: Duration, failure_cooldown: Duration) -> Self {
        Self {
            state: tokio::sync::Mutex::new(CatalogState::default()),
            ttl,
            failure_cooldown,
        }
    }

    pub async fn get_or_discover(
        &self,
        launcher: &dyn ProcessLauncher,
        claude_bin: &Path,
        timeout: Duration,
    ) -> Result<Vec<ClaudeModelInfo>> {
        // 持锁跨越整个发现过程就是单飞：后来的调用者等它结束后直接命中缓存。
        let mut state = self.state.lock().await;
        let now = Instant::now();
        if let (Some(models), Some(fetched_at)) = (&state.models, state.fetched_at)
            && now.duration_since(fetched_at) < self.ttl
        {
            return Ok(models.clone());
        }
        if let Some(failed_at) = state.failed_at
            && now.duration_since(failed_at) < self.failure_cooldown
        {
            return state
                .models
                .clone()
                .ok_or_else(|| anyhow::anyhow!("CLI model catalog recently failed"));
        }
        match discover_with_timeout(launcher, claude_bin, timeout).await {
            Ok(models) => {
                state.models = Some(models.clone());
                state.fetched_at = Some(Instant::now());
                state.failed_at = None;
                Ok(models)
            }
            Err(err) => {
                state.failed_at = Some(Instant::now());
                // 旧目录比无版本别名更接近事实；只有从未成功过才把错误抛给调用方。
                match &state.models {
                    Some(models) => Ok(models.clone()),
                    None => Err(err),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alleycat_bridge_core::launcher::{ChildProcess, ChildStderr, ChildStdin, ChildStdout};
    use futures::future::BoxFuture;
    use std::sync::{Arc, Mutex};

    struct FakeLauncher {
        output: String,
        hang: bool,
        events: Arc<Mutex<Vec<&'static str>>>,
        request: Arc<Mutex<String>>,
        launches: Arc<Mutex<usize>>,
    }

    struct FakeChild {
        stdin: Mutex<Option<ChildStdin>>,
        stdout: Mutex<Option<ChildStdout>>,
        task: tokio::task::JoinHandle<()>,
        events: Arc<Mutex<Vec<&'static str>>>,
    }

    impl ProcessLauncher for FakeLauncher {
        fn launch(
            &self,
            spec: ProcessSpec,
        ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
            Box::pin(async move {
                *self.launches.lock().unwrap() += 1;
                let args: Vec<_> = spec.args.iter().map(|s| s.to_string_lossy()).collect();
                assert!(args.contains(&"--no-session-persistence".into()));
                assert!(args.contains(&"--strict-mcp-config".into()));
                assert!(args.contains(&r#"{"disableAllHooks":true}"#.into()));
                assert!(args.windows(2).any(|pair| pair == ["--tools", ""]));
                let (stdin, read_request) = tokio::io::duplex(4096);
                let (mut write_response, stdout) = tokio::io::duplex(4096);
                let output = self.output.clone();
                let request = self.request.clone();
                let hang = self.hang;
                let task = tokio::spawn(async move {
                    let mut line = String::new();
                    BufReader::new(read_request)
                        .read_line(&mut line)
                        .await
                        .unwrap();
                    *request.lock().unwrap() = line;
                    if hang {
                        std::future::pending::<()>().await;
                    }
                    write_response.write_all(output.as_bytes()).await.unwrap();
                });
                Ok(Box::new(FakeChild {
                    stdin: Mutex::new(Some(Box::new(stdin))),
                    stdout: Mutex::new(Some(Box::new(stdout))),
                    task,
                    events: self.events.clone(),
                }) as Box<dyn ChildProcess>)
            })
        }
    }

    impl ChildProcess for FakeChild {
        fn take_stdin(&mut self) -> Option<ChildStdin> {
            self.stdin.get_mut().unwrap().take()
        }
        fn take_stdout(&mut self) -> Option<ChildStdout> {
            self.stdout.get_mut().unwrap().take()
        }
        fn take_stderr(&mut self) -> Option<ChildStderr> {
            None
        }
        fn id(&self) -> Option<u32> {
            None
        }
        fn kill(&mut self) -> BoxFuture<'_, std::io::Result<()>> {
            Box::pin(async move {
                self.events.lock().unwrap().push("kill");
                self.task.abort();
                Ok(())
            })
        }
        fn wait(&mut self) -> BoxFuture<'_, std::io::Result<std::process::ExitStatus>> {
            Box::pin(async move {
                self.events.lock().unwrap().push("wait");
                Err(std::io::Error::other("fake exit"))
            })
        }
    }

    async fn query(output: String, hang: bool) -> Result<Vec<ClaudeModelInfo>> {
        let launcher = FakeLauncher {
            output,
            hang,
            events: Arc::default(),
            request: Arc::default(),
            launches: Arc::default(),
        };
        let result =
            discover_with_timeout(&launcher, Path::new("claude"), Duration::from_millis(100)).await;
        assert_eq!(*launcher.events.lock().unwrap(), vec!["kill", "wait"]);
        let request: serde_json::Value =
            serde_json::from_str(&launcher.request.lock().unwrap()).unwrap();
        assert_eq!(
            request,
            json!({"type":"control_request","request_id":"model-catalog","request":{"subtype":"initialize"}})
        );
        result
    }

    #[tokio::test]
    async fn catalog_is_fresh_and_only_matching_initialize_response_is_used() {
        for version in ["claude-fable-9-1", "claude-fable-9-2"] {
            let response = json!({"type":"control_response","response":{"subtype":"success","request_id":"model-catalog","response":{"models":[{"value":version,"displayName":"Future"}]}}});
            let models = query(
                format!("noise\n{{\"type\":\"system\"}}\n{response}\n"),
                false,
            )
            .await
            .unwrap();
            assert_eq!(models[0].value, version);
        }
    }

    fn catalog_response(version: &str) -> String {
        let response = json!({"type":"control_response","response":{"subtype":"success","request_id":"model-catalog","response":{"models":[{"value":version,"displayName":"Future"}]}}});
        format!("{response}\n")
    }

    fn fake_launcher(output: String) -> FakeLauncher {
        FakeLauncher {
            output,
            hang: false,
            events: Arc::default(),
            request: Arc::default(),
            launches: Arc::default(),
        }
    }

    #[tokio::test]
    async fn cache_serves_repeat_queries_without_relaunching_the_cli() {
        let launcher = fake_launcher(catalog_response("claude-fable-9-1"));
        let cache = ModelCatalogCache::default();
        for _ in 0..3 {
            let models = cache
                .get_or_discover(&launcher, Path::new("claude"), Duration::from_millis(200))
                .await
                .unwrap();
            assert_eq!(models[0].value, "claude-fable-9-1");
        }
        assert_eq!(
            *launcher.launches.lock().unwrap(),
            1,
            "TTL 内不得重复起 CLI"
        );
    }

    #[tokio::test]
    async fn cache_keeps_last_good_catalog_when_refresh_fails_and_cools_down() {
        // ttl=0 强制每次都刷新，便于模拟过期后的失败。
        let cache = ModelCatalogCache::with_limits(Duration::ZERO, Duration::from_secs(60));
        let good = fake_launcher(catalog_response("claude-fable-9-1"));
        cache
            .get_or_discover(&good, Path::new("claude"), Duration::from_millis(200))
            .await
            .unwrap();

        let broken = fake_launcher(String::new());
        let models = cache
            .get_or_discover(&broken, Path::new("claude"), Duration::from_millis(200))
            .await
            .expect("刷新失败时必须返回上一次成功的目录");
        assert_eq!(models[0].value, "claude-fable-9-1");
        assert_eq!(*broken.launches.lock().unwrap(), 1);

        let again = cache
            .get_or_discover(&broken, Path::new("claude"), Duration::from_millis(200))
            .await
            .unwrap();
        assert_eq!(again[0].value, "claude-fable-9-1");
        assert_eq!(*broken.launches.lock().unwrap(), 1, "冷却期内不得再起 CLI");

        let never_succeeded =
            ModelCatalogCache::with_limits(Duration::ZERO, Duration::from_secs(60));
        assert!(
            never_succeeded
                .get_or_discover(&broken, Path::new("claude"), Duration::from_millis(200))
                .await
                .is_err(),
            "从未成功过时才把错误抛给调用方"
        );
    }

    #[tokio::test]
    async fn failed_empty_and_timed_out_queries_reap_the_process() {
        assert!(query(String::new(), false).await.is_err());
        let response = json!({"type":"control_response","response":{"subtype":"error","request_id":"model-catalog","error":"private account"}});
        let error = query(format!("{response}\n"), false).await.unwrap_err();
        assert!(!error.to_string().contains("private account"));
        let error = query(String::new(), true).await.unwrap_err();
        assert!(error.to_string().contains("timed out"));
    }
}
