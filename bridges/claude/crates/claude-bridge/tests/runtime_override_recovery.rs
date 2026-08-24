//! 回归：turn/start 在发送用户输入前遇到 runtime control 进程退出时，
//! bridge 只冷启动重试一次，并且用户输入只能发送给健康 generation 一次。

mod support;

use std::sync::Arc;
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

#[tokio::test]
async fn pre_turn_control_exit_cold_recovers_without_duplicate_user_envelope() {
    let fixture = TempDir::new().expect("fixture");
    let cwd = TempDir::new().expect("cwd");
    let marker = fixture.path().join("first-control-exited");
    let turn_log = fixture.path().join("turns.log");
    let _restore_marker = EnvRestore::set("FAKE_CLAUDE_EXIT_ON_CONTROL_ONCE", &marker);
    let _restore_turn_log = EnvRestore::set("FAKE_CLAUDE_TURN_LOG", &turn_log);

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
            "input": [{"type": "text", "text": "recover exactly once"}],
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
    assert!(
        marker.is_file(),
        "first generation must fail during control"
    );
    assert_eq!(
        std::fs::read_to_string(&turn_log).expect("turn log"),
        "recover exactly once\n",
        "the user envelope must not be replayed"
    );
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
