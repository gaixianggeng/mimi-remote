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
