//! 通过 CLI 的 SDK initialize 控制请求读取目录，不发送 user 消息。

use std::path::{Path, PathBuf};
use std::sync::Arc;
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
/// 前台 `model/list` 最多等这么久；客户端自己 20 秒就会超时并负缓存 5 分钟。
pub const CATALOG_QUERY_TIMEOUT: Duration = Duration::from_secs(10);
/// 后台发现任务本身的预算：CLI 冷启动可能超过 10 秒，前台调用者超时后它继续跑，
/// 结果写进缓存供下一次请求使用。
pub const CATALOG_DISCOVERY_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Default)]
struct CatalogState {
    models: Option<Vec<ClaudeModelInfo>>,
    fetched_at: Option<Instant>,
    failed_at: Option<Instant>,
    in_flight: bool,
}

/// 进程级目录缓存。此前每次 `model/list` 都现起一个 CLI 做发现，首次失败或超时
/// 就回退成无版本别名，而客户端会把这次结果缓存几分钟——用户看到的就是"第一次
/// 打开只有 Opus / Sonnet / Haiku，第二次才正常"。这里做四件事：缓存、单飞
/// （同一时刻只有一个后台发现任务）、发现失败时优先返回上一次成功的目录、
/// 前台调用者只等自己的预算——等不到就先回退，发现任务继续跑完填缓存。
pub struct ModelCatalogCache {
    state: std::sync::Mutex<CatalogState>,
    generation: tokio::sync::watch::Sender<u64>,
    ttl: Duration,
    failure_cooldown: Duration,
    discovery_timeout: Duration,
}

impl Default for ModelCatalogCache {
    fn default() -> Self {
        Self::with_limits(
            CATALOG_TTL,
            CATALOG_FAILURE_COOLDOWN,
            CATALOG_DISCOVERY_TIMEOUT,
        )
    }
}

impl ModelCatalogCache {
    pub fn with_limits(
        ttl: Duration,
        failure_cooldown: Duration,
        discovery_timeout: Duration,
    ) -> Self {
        Self {
            state: std::sync::Mutex::new(CatalogState::default()),
            generation: tokio::sync::watch::Sender::new(0),
            ttl,
            failure_cooldown,
            discovery_timeout,
        }
    }

    /// 返回目录：命中缓存直接回；否则确保有一个后台发现任务在跑，并最多等 `wait`。
    /// 等到结果就回结果；等不到时有旧目录回旧目录，没有才报错。
    pub async fn get_or_discover(
        self: &Arc<Self>,
        launcher: Arc<dyn ProcessLauncher>,
        claude_bin: PathBuf,
        wait: Duration,
    ) -> Result<Vec<ClaudeModelInfo>> {
        let mut rx = self.generation.subscribe();
        {
            let mut state = self.state.lock().unwrap();
            let now = Instant::now();
            if let (Some(models), Some(fetched_at)) = (&state.models, state.fetched_at)
                && now.duration_since(fetched_at) < self.ttl
            {
                return Ok(models.clone());
            }
            if !state.in_flight {
                if let Some(failed_at) = state.failed_at
                    && now.duration_since(failed_at) < self.failure_cooldown
                {
                    return state
                        .models
                        .clone()
                        .ok_or_else(|| anyhow::anyhow!("CLI model catalog recently failed"));
                }
                state.in_flight = true;
                let cache = Arc::clone(self);
                tokio::spawn(async move {
                    let result = discover_with_timeout(
                        launcher.as_ref(),
                        &claude_bin,
                        cache.discovery_timeout,
                    )
                    .await;
                    let mut state = cache.state.lock().unwrap();
                    state.in_flight = false;
                    match result {
                        Ok(models) => {
                            state.models = Some(models);
                            state.fetched_at = Some(Instant::now());
                            state.failed_at = None;
                        }
                        Err(err) => {
                            tracing::debug!(error = %err, "claude model catalog discovery failed");
                            state.failed_at = Some(Instant::now());
                        }
                    }
                    drop(state);
                    cache.generation.send_modify(|generation| *generation += 1);
                });
            }
        }
        // 等这一代发现结束；超过自己的预算就不再陪它等。
        let _ = tokio::time::timeout(wait, rx.changed()).await;
        let state = self.state.lock().unwrap();
        if let (Some(models), Some(fetched_at)) = (&state.models, state.fetched_at)
            && Instant::now().duration_since(fetched_at) < self.ttl
        {
            return Ok(models.clone());
        }
        state.models.clone().ok_or_else(|| {
            if state.in_flight {
                anyhow::anyhow!("CLI model catalog is still loading")
            } else {
                anyhow::anyhow!("CLI model catalog unavailable")
            }
        })
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
        delay: Duration,
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
                let delay = self.delay;
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
                    if !delay.is_zero() {
                        tokio::time::sleep(delay).await;
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
            delay: Duration::ZERO,
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

    fn fake_launcher(
        output: String,
        hang: bool,
        delay: Duration,
    ) -> (Arc<FakeLauncher>, Arc<Mutex<usize>>) {
        let launches: Arc<Mutex<usize>> = Arc::default();
        let launcher = Arc::new(FakeLauncher {
            output,
            hang,
            delay,
            events: Arc::default(),
            request: Arc::default(),
            launches: Arc::clone(&launches),
        });
        (launcher, launches)
    }

    fn short_cache(ttl: Duration, discovery_timeout: Duration) -> Arc<ModelCatalogCache> {
        Arc::new(ModelCatalogCache::with_limits(
            ttl,
            Duration::from_secs(60),
            discovery_timeout,
        ))
    }

    #[tokio::test]
    async fn cache_serves_repeat_queries_without_relaunching_the_cli() {
        let (launcher, launches) =
            fake_launcher(catalog_response("claude-fable-9-1"), false, Duration::ZERO);
        let cache = Arc::new(ModelCatalogCache::default());
        for _ in 0..3 {
            let models = cache
                .get_or_discover(
                    launcher.clone() as Arc<dyn ProcessLauncher>,
                    PathBuf::from("claude"),
                    Duration::from_millis(500),
                )
                .await
                .unwrap();
            assert_eq!(models[0].value, "claude-fable-9-1");
        }
        assert_eq!(*launches.lock().unwrap(), 1, "TTL 内不得重复起 CLI");
    }

    #[tokio::test]
    async fn cache_keeps_last_good_catalog_when_refresh_fails_and_cools_down() {
        // ttl=0 强制每次都刷新，便于模拟过期后的失败。
        let cache = short_cache(Duration::ZERO, Duration::from_millis(500));
        let (good, _) = fake_launcher(catalog_response("claude-fable-9-1"), false, Duration::ZERO);
        cache
            .get_or_discover(
                good as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(500),
            )
            .await
            .unwrap();

        let (broken, broken_launches) = fake_launcher(String::new(), false, Duration::ZERO);
        let models = cache
            .get_or_discover(
                broken.clone() as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(500),
            )
            .await
            .expect("刷新失败时必须返回上一次成功的目录");
        assert_eq!(models[0].value, "claude-fable-9-1");
        assert_eq!(*broken_launches.lock().unwrap(), 1);

        let again = cache
            .get_or_discover(
                broken.clone() as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(500),
            )
            .await
            .unwrap();
        assert_eq!(again[0].value, "claude-fable-9-1");
        assert_eq!(*broken_launches.lock().unwrap(), 1, "冷却期内不得再起 CLI");

        let never_succeeded = short_cache(Duration::ZERO, Duration::from_millis(500));
        assert!(
            never_succeeded
                .get_or_discover(
                    broken as Arc<dyn ProcessLauncher>,
                    PathBuf::from("claude"),
                    Duration::from_millis(500)
                )
                .await
                .is_err(),
            "从未成功过时才把错误抛给调用方"
        );
    }

    #[tokio::test]
    async fn foreground_caller_waits_only_its_own_budget_and_later_call_hits_cache() {
        // 发现要 300ms（模拟冷启动），前台只肯等 30ms：应立即回退，而不是陪发现任务等完。
        let (slow, launches) = fake_launcher(
            catalog_response("claude-fable-9-1"),
            false,
            Duration::from_millis(300),
        );
        let cache = short_cache(CATALOG_TTL, Duration::from_secs(5));
        let started = Instant::now();
        let first = cache
            .get_or_discover(
                slow.clone() as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(30),
            )
            .await;
        assert!(first.is_err(), "预算内等不到就回退");
        assert!(
            started.elapsed() < Duration::from_millis(250),
            "不能陪后台发现等完"
        );

        // 后台发现继续跑完并填缓存；下一次请求直接命中，不再起 CLI。
        tokio::time::sleep(Duration::from_millis(500)).await;
        let second = cache
            .get_or_discover(
                slow as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(30),
            )
            .await
            .unwrap();
        assert_eq!(second[0].value, "claude-fable-9-1");
        assert_eq!(*launches.lock().unwrap(), 1, "同一次发现被前台和后台共享");
    }

    #[tokio::test]
    async fn hung_discovery_is_bounded_by_its_own_timeout_not_the_caller() {
        let (hung, launches) = fake_launcher(String::new(), true, Duration::ZERO);
        let cache = short_cache(CATALOG_TTL, Duration::from_millis(100));
        let first = cache
            .get_or_discover(
                hung.clone() as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(20),
            )
            .await;
        assert!(first.is_err());
        tokio::time::sleep(Duration::from_millis(250)).await;
        // 发现任务已按自己的 100ms 超时结束并进入冷却；期间不再起新 CLI。
        let second = cache
            .get_or_discover(
                hung as Arc<dyn ProcessLauncher>,
                PathBuf::from("claude"),
                Duration::from_millis(20),
            )
            .await;
        assert!(second.is_err());
        assert_eq!(*launches.lock().unwrap(), 1, "冷却期内不得重复起 CLI");
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
