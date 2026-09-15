//! 回归：历史会话重复 resume 后，若 runtime control 导致进程退出，
//! bridge 的冷重试必须改用启动参数，不能再重复同一条失败控制请求。

mod support;

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use alleycat_bridge_core::framing::write_json_line;
use alleycat_claude_bridge::index::ThreadIndex;
use alleycat_claude_bridge::pool::ClaudePool;
use alleycat_claude_bridge::run_connection;
use alleycat_claude_bridge::state::ThreadIndexHandle;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};
use tokio::time::timeout;

use support::fake_claude_path;

const STEP_TIMEOUT: Duration = Duration::from_secs(8);

static TEST_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

#[tokio::test]
async fn cold_start_unsupported_effort_control_uses_runtime_fallback() {
    let _test_guard = TEST_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;
    let fixture = TempDir::new().expect("fixture");
    let cwd = TempDir::new().expect("cwd");
    let turn_log = fixture.path().join("turns.log");
    let argv_log = fixture.path().join("argv.jsonl");
    let _restore_reject_arg = EnvRestore::set(
        "FAKE_CLAUDE_REJECT_EFFORT_ARG",
        &fixture.path().join("reject-arg"),
    );
    let _restore_reject_control = EnvRestore::set(
        "FAKE_CLAUDE_REJECT_EFFORT_CONTROL",
        &fixture.path().join("reject-control"),
    );
    let _restore_turn_log = EnvRestore::set("FAKE_CLAUDE_TURN_LOG", &turn_log);
    let _restore_argv_log = EnvRestore::set("FAKE_CLAUDE_ARGV_LOG", &argv_log);

    let claude_pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let codex_home = TempDir::new().expect("codex home");
    let thread_index: Arc<dyn ThreadIndexHandle> = ThreadIndex::open_and_hydrate(codex_home.path())
        .await
        .expect("thread index");
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);
    let bridge_pool = Arc::clone(&claude_pool);
    let codex_home_path = codex_home.path().to_path_buf();
    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            bridge_pool,
            thread_index,
            codex_home_path,
        )
        .await
    });

    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);
    send(
        &mut client_writer,
        1,
        "initialize",
        json!({"clientInfo": {"name": "runtime-recovery", "version": "0.0.1"}}),
    )
    .await;
    let _ = await_response(&mut client_reader, 1).await;

    send(
        &mut client_writer,
        2,
        "thread/start",
        json!({"cwd": cwd.path().to_string_lossy()}),
    )
    .await;
    let started = await_response(&mut client_reader, 2).await;
    let thread_id = started["result"]["thread"]["id"]
        .as_str()
        .expect("thread id")
        .to_string();

    send(
        &mut client_writer,
        3,
        "turn/start",
        json!({
            "threadId": thread_id,
            "input": [{"type": "text", "text": "old cli fallback"}],
            "effort": "high"
        }),
    )
    .await;
    let messages = collect_turn(&mut client_reader, 3).await;
    let response = messages
        .iter()
        .find(|message| message["id"].as_u64() == Some(3))
        .expect("turn/start response");
    assert!(
        response.get("error").is_none(),
        "unexpected error: {response:#?}"
    );
    let completed = messages
        .iter()
        .find(|message| message["method"] == "turn/completed")
        .expect("turn/completed");
    assert_eq!(completed["params"]["turn"]["status"], "completed");
    assert_eq!(
        std::fs::read_to_string(&turn_log).expect("turn log"),
        "old cli fallback\n"
    );

    let argv = read_argv_log(&argv_log);
    assert_eq!(argv.len(), 1, "ordinary cold acquire must spawn once");
    assert!(!argv[0].iter().any(|arg| arg == "--effort"));
    assert!(!argv[0].iter().any(|arg| arg == "--permission-mode"));

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
}

#[tokio::test]
async fn duplicate_resume_control_exit_recovers_with_spawn_time_overrides() {
    let _test_guard = TEST_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;
    let fixture = TempDir::new().expect("fixture");
    let cwd = TempDir::new().expect("cwd");
    let turn_log = fixture.path().join("turns.log");
    let argv_log = fixture.path().join("argv.jsonl");
    let _restore_control_exit =
        EnvRestore::set("FAKE_CLAUDE_EXIT_ON_CONTROL_ALWAYS", fixture.path());
    let _restore_turn_log = EnvRestore::set("FAKE_CLAUDE_TURN_LOG", &turn_log);
    let _restore_argv_log = EnvRestore::set("FAKE_CLAUDE_ARGV_LOG", &argv_log);

    let claude_pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let codex_home = TempDir::new().expect("codex home");
    let index = ThreadIndex::open_and_hydrate(codex_home.path())
        .await
        .expect("thread index");
    let thread_index: Arc<dyn ThreadIndexHandle> = index.clone();
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);
    let bridge_pool = Arc::clone(&claude_pool);
    let codex_home_path = codex_home.path().to_path_buf();
    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            bridge_pool,
            thread_index,
            codex_home_path,
        )
        .await
    });

    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);
    send(
        &mut client_writer,
        1,
        "initialize",
        json!({"clientInfo": {"name": "runtime-recovery", "version": "0.0.1"}}),
    )
    .await;
    let _ = await_response(&mut client_reader, 1).await;

    send(
        &mut client_writer,
        2,
        "thread/start",
        json!({"cwd": cwd.path().to_string_lossy()}),
    )
    .await;
    let started = await_response(&mut client_reader, 2).await;
    let thread_id = started["result"]["thread"]["id"]
        .as_str()
        .expect("thread id")
        .to_string();
    let transcript = index
        .lookup(&thread_id)
        .await
        .expect("indexed thread")
        .metadata
        .claude_session_path;
    std::fs::create_dir_all(transcript.parent().expect("transcript parent"))
        .expect("create transcript parent");
    std::fs::write(&transcript, "").expect("create historical transcript");

    for id in [3, 4] {
        send(
            &mut client_writer,
            id,
            "thread/resume",
            json!({
                "threadId": thread_id,
                "model": "opus",
                "excludeTurns": true
            }),
        )
        .await;
        let resumed = await_response(&mut client_reader, id).await;
        assert!(
            resumed.get("error").is_none(),
            "unexpected resume error: {resumed:#?}"
        );
    }

    send(
        &mut client_writer,
        5,
        "turn/start",
        json!({
            "threadId": thread_id,
            "input": [{"type": "text", "text": "recover exactly once"}],
            "model": "opus",
            "effort": "high"
        }),
    )
    .await;
    let messages = collect_turn(&mut client_reader, 5).await;
    let response = messages
        .iter()
        .find(|message| message["id"].as_u64() == Some(5))
        .expect("turn/start response");
    assert!(
        response.get("error").is_none(),
        "unexpected error: {response:#?}"
    );
    let completed = messages
        .iter()
        .find(|message| message["method"] == "turn/completed")
        .expect("turn/completed");
    assert_eq!(completed["params"]["turn"]["status"], "completed");
    assert_eq!(
        std::fs::read_to_string(&turn_log).expect("turn log"),
        "recover exactly once\n",
        "the user envelope must not be replayed"
    );
    let argv = read_argv_log(&argv_log);
    assert_eq!(
        argv.len(),
        2,
        "recovery must create exactly one new generation"
    );
    assert!(!argv[0].iter().any(|arg| arg == "--effort"));
    assert!(!argv[0].iter().any(|arg| arg == "--permission-mode"));
    assert!(has_arg_pair(&argv[1], "--effort", "high"));
    assert!(has_arg_pair(&argv[1], "--permission-mode", "default"));
    assert_eq!(claude_pool.len().await, 1);

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
}

#[tokio::test]
async fn full_access_switch_restarts_same_session_and_restores_sandbox() {
    let _guard = TEST_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;
    let fixture = TempDir::new().unwrap();
    let cwd = TempDir::new().unwrap();
    let argv_log = fixture.path().join("argv.jsonl");
    let turn_log = fixture.path().join("turns.log");
    let _argv = EnvRestore::set("FAKE_CLAUDE_ARGV_LOG", &argv_log);
    let _turns = EnvRestore::set("FAKE_CLAUDE_TURN_LOG", &turn_log);
    let pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let codex_home = TempDir::new().unwrap();
    let index = ThreadIndex::open_and_hydrate(codex_home.path())
        .await
        .unwrap();
    let (client, bridge) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
    let bridge_pool = pool.clone();
    let bridge_index: Arc<dyn ThreadIndexHandle> = index.clone();
    let home_path = codex_home.path().to_path_buf();
    let task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            bridge_pool,
            bridge_index,
            home_path,
        )
        .await
    });
    let (reader, mut writer) = tokio::io::split(client);
    let mut reader = BufReader::new(reader);
    send(
        &mut writer,
        1,
        "initialize",
        json!({"clientInfo":{"name":"full-access","version":"1"}}),
    )
    .await;
    let _ = await_response(&mut reader, 1).await;
    send(&mut writer, 2, "thread/start", json!({"cwd":cwd.path()})).await;
    let started = await_response(&mut reader, 2).await;
    let thread_id = started["result"]["thread"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    // fake 不写 Claude transcript，模拟真实 CLI 在首轮后留下的历史文件。
    let transcript = index
        .lookup(&thread_id)
        .await
        .unwrap()
        .metadata
        .claude_session_path;
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, "").unwrap();

    for (offset, sandbox, policy, reviewer) in [
        (0, "dangerFullAccess", "never", "user"),
        (1, "dangerFullAccess", "never", "user"),
        (2, "readOnly", "on-request", "user"),
        (3, "workspaceWrite", "on-request", "auto_review"),
        (4, "dangerFullAccess", "never", "user"),
    ] {
        let id = 3 + offset;
        send(&mut writer, id, "turn/start", json!({
            "threadId":thread_id, "input":[{"type":"text","text":format!("turn-{offset}")}],
            "sandboxPolicy":{"type":sandbox}, "approvalPolicy":policy, "approvalsReviewer":reviewer,
        })).await;
        let frames = collect_turn(&mut reader, id).await;
        let response = frames
            .iter()
            .find(|f| f["id"].as_u64() == Some(id))
            .unwrap();
        assert!(response.get("error").is_none(), "{response:#?}");
        let complete = frames
            .iter()
            .find(|f| f["method"] == "turn/completed")
            .unwrap();
        assert_eq!(complete["params"]["turn"]["status"], "completed");
        let handle = pool.get(&thread_id).await.unwrap();
        assert_eq!(handle.uses_full_access(), sandbox == "dangerFullAccess");
        let (_, _, mode) = handle.runtime_snapshot().await;
        assert_eq!(
            mode.as_deref(),
            Some(match sandbox {
                "dangerFullAccess" => "bypassPermissions",
                "readOnly" => "plan",
                _ => "auto",
            })
        );
    }
    let argv = read_argv_log(&argv_log);
    assert_eq!(
        argv.len(),
        3,
        "只在进出完全访问时换代，普通档位沿用控制协议"
    );
    for position in [0, 2] {
        assert!(has_arg_pair(
            &argv[position],
            "--permission-mode",
            "bypassPermissions"
        ));
        assert!(has_arg_pair(
            &argv[position],
            "--settings",
            r#"{"sandbox":{"enabled":false}}"#
        ));
        assert!(!argv[position].iter().any(|a| a == "--disallowedTools"));
    }
    assert!(has_arg_pair(&argv[1], "--permission-mode", "plan"));
    for generation in &argv {
        assert!(has_arg_pair(generation, "--resume", &thread_id));
        assert!(has_arg_pair(
            generation,
            "--permission-prompt-tool",
            "stdio"
        ));
    }
    if cfg!(windows) {
        assert!(argv[1].iter().any(|a| a == "--disallowedTools"));
    } else {
        let settings_index = argv[1].iter().position(|a| a == "--settings").unwrap();
        let settings: Value = serde_json::from_str(&argv[1][settings_index + 1]).unwrap();
        assert_eq!(settings["sandbox"]["enabled"], true);
        assert_eq!(settings["sandbox"]["failIfUnavailable"], true);
    }
    assert_eq!(
        std::fs::read_to_string(turn_log).unwrap(),
        "turn-0\nturn-1\nturn-2\nturn-3\nturn-4\n"
    );
    drop(writer);
    drop(reader);
    let _ = timeout(STEP_TIMEOUT, task).await;
}

#[tokio::test]
async fn concurrent_permission_selections_cannot_change_the_accepted_turn() {
    use alleycat_claude_bridge::handlers::{
        thread::handle_thread_start,
        turn::{TurnError, handle_turn_start},
    };
    use alleycat_claude_bridge::state::ConnectionState;
    let _guard = TEST_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;
    let fixture = TempDir::new().unwrap();
    let script = fixture.path().join("slow.jsonl");
    std::fs::write(&script, "{\"type\":\"sleep\",\"ms\":1000}\n{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}\n").unwrap();
    let _script = EnvRestore::set("FAKE_CLAUDE_SCRIPT", &script);
    let pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let index = ThreadIndex::open_and_hydrate(fixture.path()).await.unwrap();
    let (state, _rx) = ConnectionState::for_test(pool.clone(), index, Default::default());
    let started = handle_thread_start(
        &state,
        serde_json::from_value(json!({"cwd":fixture.path()})).unwrap(),
    )
    .await
    .unwrap();
    let thread_id = started.thread.id;
    let full = serde_json::from_value(json!({"threadId":thread_id,
        "input":[{"type":"text","text":"full"}], "approvalPolicy":"never",
        "sandboxPolicy":{"type":"dangerFullAccess"}}))
    .unwrap();
    let limited = serde_json::from_value(json!({"threadId":thread_id,
        "input":[{"type":"text","text":"limited"}], "approvalPolicy":"on-request",
        "sandboxPolicy":{"type":"readOnly"}}))
    .unwrap();
    let (full_result, limited_result) = tokio::join!(
        handle_turn_start(&state, full),
        handle_turn_start(&state, limited)
    );
    let expected_full = match (&full_result, &limited_result) {
        (Ok(_), Err(TurnError::AlreadyActive { .. })) => true,
        (Err(TurnError::AlreadyActive { .. }), Ok(_)) => false,
        _ => panic!("同一会话必须只有一轮胜出：{full_result:?}, {limited_result:?}"),
    };
    let handle = pool.get(&thread_id).await.unwrap();
    assert_eq!(handle.uses_full_access(), expected_full);
    let (_, _, mode) = handle.runtime_snapshot().await;
    assert_eq!(
        mode.as_deref(),
        Some(if expected_full {
            "bypassPermissions"
        } else {
            "plan"
        })
    );
    pool.release(&thread_id).await;
}

#[tokio::test]
async fn permission_switch_preserves_pending_wakeup_and_cron_processes() {
    use alleycat_claude_bridge::handlers::{
        thread::handle_thread_start,
        turn::{TurnError, handle_turn_start},
    };
    use alleycat_claude_bridge::state::ConnectionState;
    let _guard = TEST_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;
    for tool in ["ScheduleWakeup", "CronCreate"] {
        let fixture = TempDir::new().unwrap();
        let script = fixture.path().join("background.jsonl");
        let turn_log = fixture.path().join("turns.log");
        std::fs::write(
            &script,
            format!(
                "{}\n{}\n",
                json!({"type":"assistant", "session_id":"$SESSION", "uuid":"background-assistant", "message":{"content":[{"type":"tool_use",
                "id":"background-tool", "name":tool, "input":{}}]}}),
                json!({"type":"result", "subtype":"success", "is_error":false, "session_id":"$SESSION", "uuid":"background-result"})
            ),
        )
        .unwrap();
        let _script = EnvRestore::set("FAKE_CLAUDE_SCRIPT", &script);
        let _log = EnvRestore::set("FAKE_CLAUDE_TURN_LOG", &turn_log);
        let pool = Arc::new(ClaudePool::new(fake_claude_path()));
        let index = ThreadIndex::open_and_hydrate(fixture.path()).await.unwrap();
        let (state, _rx) = ConnectionState::for_test(pool.clone(), index, Default::default());
        let thread_id = handle_thread_start(
            &state,
            serde_json::from_value(json!({"cwd":fixture.path()})).unwrap(),
        )
        .await
        .unwrap()
        .thread
        .id;
        let first = handle_turn_start(
            &state,
            serde_json::from_value(json!({"threadId":thread_id,
            "input":[{"type":"text", "text":"schedule"}]}))
            .unwrap(),
        )
        .await
        .unwrap();
        timeout(STEP_TIMEOUT, async {
            loop {
                if state.thread_log(&thread_id).iter().any(|t| {
                    t.id == first.turn.id && t.status == alleycat_codex_proto::TurnStatus::Completed
                }) {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let original = pool.get(&thread_id).await.unwrap();
        let error = handle_turn_start(
            &state,
            serde_json::from_value(json!({"threadId":thread_id,
            "input":[{"type":"text", "text":"switch"}], "approvalPolicy":"never",
            "sandboxPolicy":{"type":"dangerFullAccess"}}))
            .unwrap(),
        )
        .await
        .unwrap_err();
        assert!(
            matches!(error, TurnError::BackgroundWorkPending { .. }),
            "{error:?}"
        );
        assert_eq!(error.rpc_data().unwrap()["accepted"], false);
        assert!(Arc::ptr_eq(&original, &pool.get(&thread_id).await.unwrap()));
        assert!(!original.has_exited());
        assert_eq!(std::fs::read_to_string(&turn_log).unwrap(), "schedule\n");
        pool.release(&thread_id).await;
    }
}

#[tokio::test]
async fn concurrent_prestart_resume_cannot_insert_ordinary_process_during_full_access_switch() {
    use alleycat_claude_bridge::handlers::{
        thread::{handle_thread_resume, handle_thread_start},
        turn::handle_turn_start,
    };
    use alleycat_claude_bridge::state::ConnectionState;
    let _guard = TEST_LOCK
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;
    let fixture = TempDir::new().unwrap();
    let _home = support::ClaudeHomeFixture::new();
    let argv_log = fixture.path().join("argv.jsonl");
    let _argv = EnvRestore::set("FAKE_CLAUDE_ARGV_LOG", &argv_log);
    let launcher = Arc::new(ShutdownBarrierLauncher::default());
    let pool = Arc::new(ClaudePool::with_launcher(
        fake_claude_path(),
        launcher.clone(),
        Default::default(),
    ));
    let index = ThreadIndex::open_and_hydrate(fixture.path()).await.unwrap();
    let (state, _rx) = ConnectionState::for_test(pool.clone(), index.clone(), Default::default());
    let thread_id = handle_thread_start(
        &state,
        serde_json::from_value(json!({
        "cwd":fixture.path(), "model":"sonnet"}))
        .unwrap(),
    )
    .await
    .unwrap()
    .thread
    .id;
    let transcript = index
        .lookup(&thread_id)
        .await
        .unwrap()
        .metadata
        .claude_session_path;
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, "").unwrap();
    let original = pool.get(&thread_id).await.unwrap();
    original.wait_for_init(STEP_TIMEOUT).await.unwrap();
    assert!(!original.uses_full_access());
    let switch_state = state.clone();
    let full = serde_json::from_value(json!({"threadId":thread_id,
        "input":[{"type":"text", "text":"full"}], "approvalPolicy":"never",
        "sandboxPolicy":{"type":"dangerFullAccess"}}))
    .unwrap();
    let switch = tokio::spawn(async move { handle_turn_start(&switch_state, full).await });
    // 精确停在 pool 已移除旧 generation、shutdown 尚未返回的窗口。
    timeout(STEP_TIMEOUT, launcher.entered.notified())
        .await
        .unwrap();
    assert!(pool.get(&thread_id).await.is_none());
    let resume_state = state.clone();
    let params = serde_json::from_value(json!({"threadId":thread_id, "model":"sonnet"})).unwrap();
    let mut resume = tokio::spawn(async move { handle_thread_resume(&resume_state, params).await });
    let premature = timeout(Duration::from_millis(100), &mut resume).await;
    launcher.release.notify_one();
    assert!(
        premature.is_err(),
        "resume 必须等待换代完成，不能在空隙插入普通进程"
    );
    timeout(STEP_TIMEOUT, switch)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    timeout(STEP_TIMEOUT, resume)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let current = pool.get(&thread_id).await.unwrap();
    assert!(current.uses_full_access());
    assert_ne!(current.generation(), original.generation());
    let argv = read_argv_log(&argv_log);
    assert_eq!(argv.len(), 2);
    assert!(has_arg_pair(
        &argv[1],
        "--permission-mode",
        "bypassPermissions"
    ));
    assert!(has_arg_pair(
        &argv[1],
        "--settings",
        r#"{"sandbox":{"enabled":false}}"#
    ));
    pool.release(&thread_id).await;
}

// 只延迟第一个进程的 shutdown，不改生产代码中的调度与进程池。
#[derive(Default)]
struct ShutdownBarrierLauncher {
    first: std::sync::atomic::AtomicBool,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
}

impl alleycat_bridge_core::ProcessLauncher for ShutdownBarrierLauncher {
    fn launch(
        &self,
        spec: alleycat_bridge_core::ProcessSpec,
    ) -> futures::future::BoxFuture<'_, std::io::Result<Box<dyn alleycat_bridge_core::ChildProcess>>>
    {
        Box::pin(async move {
            let child = alleycat_bridge_core::LocalLauncher.launch(spec).await?;
            if self.first.swap(true, std::sync::atomic::Ordering::SeqCst) {
                return Ok(child);
            }
            Ok(Box::new(ShutdownBarrierChild {
                child,
                entered: self.entered.clone(),
                release: self.release.clone(),
            })
                as Box<dyn alleycat_bridge_core::ChildProcess>)
        })
    }
}

struct ShutdownBarrierChild {
    child: Box<dyn alleycat_bridge_core::ChildProcess>,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
}

impl alleycat_bridge_core::ChildProcess for ShutdownBarrierChild {
    fn take_stdin(&mut self) -> Option<alleycat_bridge_core::ChildStdin> {
        self.child.take_stdin()
    }
    fn take_stdout(&mut self) -> Option<alleycat_bridge_core::ChildStdout> {
        self.child.take_stdout()
    }
    fn take_stderr(&mut self) -> Option<alleycat_bridge_core::ChildStderr> {
        self.child.take_stderr()
    }
    fn id(&self) -> Option<u32> {
        self.child.id()
    }
    fn wait(
        &mut self,
    ) -> futures::future::BoxFuture<'_, std::io::Result<std::process::ExitStatus>> {
        self.child.wait()
    }
    fn kill(&mut self) -> futures::future::BoxFuture<'_, std::io::Result<()>> {
        Box::pin(async move {
            self.entered.notify_one();
            self.release.notified().await;
            self.child.kill().await
        })
    }
}

async fn send<W: tokio::io::AsyncWrite + Unpin>(
    writer: &mut W,
    id: u64,
    method: &str,
    params: Value,
) {
    write_json_line(
        writer,
        &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
    )
    .await
    .expect("write request");
}

async fn collect_turn<R: AsyncBufRead + Unpin>(reader: &mut R, response_id: u64) -> Vec<Value> {
    let mut messages = Vec::new();
    let mut saw_response = false;
    let mut saw_completed = false;
    for _ in 0..200 {
        let message = next_message(reader).await;
        saw_response |= message["id"].as_u64() == Some(response_id);
        saw_completed |= message["method"] == "turn/completed";
        messages.push(message);
        if saw_response && saw_completed {
            return messages;
        }
    }
    panic!("turn {response_id} did not complete: {messages:#?}");
}

async fn await_response<R: AsyncBufRead + Unpin>(reader: &mut R, response_id: u64) -> Value {
    loop {
        let message = next_message(reader).await;
        if message["id"].as_u64() == Some(response_id) {
            return message;
        }
    }
}

async fn next_message<R: AsyncBufRead + Unpin>(reader: &mut R) -> Value {
    let mut line = String::new();
    let count = timeout(STEP_TIMEOUT, reader.read_line(&mut line))
        .await
        .expect("bridge response timeout")
        .expect("read bridge response");
    assert!(count > 0, "bridge closed before the expected frame");
    serde_json::from_str(line.trim()).expect("valid bridge JSON")
}

fn read_argv_log(path: &std::path::Path) -> Vec<Vec<String>> {
    std::fs::read_to_string(path)
        .expect("argv log")
        .lines()
        .map(|line| serde_json::from_str(line).expect("argv JSON"))
        .collect()
}

fn has_arg_pair(args: &[String], flag: &str, value: &str) -> bool {
    args.windows(2)
        .any(|pair| pair[0] == flag && pair[1] == value)
}

struct EnvRestore {
    key: &'static str,
    previous: Option<std::ffi::OsString>,
}

impl EnvRestore {
    fn set(key: &'static str, value: &std::path::Path) -> Self {
        let previous = std::env::var_os(key);
        unsafe {
            std::env::set_var(key, value);
        }
        Self { key, previous }
    }
}

impl Drop for EnvRestore {
    fn drop(&mut self) {
        unsafe {
            match self.previous.take() {
                Some(value) => std::env::set_var(self.key, value),
                None => std::env::remove_var(self.key),
            }
        }
    }
}
