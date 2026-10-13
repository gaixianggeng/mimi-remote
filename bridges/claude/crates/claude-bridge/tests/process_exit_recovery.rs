//! 回归：Claude 在 tool_use 之后异常退出时，bridge 必须先关闭悬空工具卡片，
//! 回收对应进程实例，并让同一 thread 的下一轮通过冷启动恢复。

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
use tokio::time::{Instant, timeout};

use support::{fake_claude_path, write_script};

const STEP_TIMEOUT: Duration = Duration::from_secs(8);

#[tokio::test]
async fn process_exit_closes_tool_reaps_generation_and_cold_recovers() {
    let fixture = TempDir::new().expect("fixture");
    let cwd = TempDir::new().expect("cwd");
    let marker = fixture.path().join("first-generation-exited");
    let script = write_script(
        fixture.path(),
        &[
            json!({
                "type": "assistant",
                "session_id": "__SESSION__",
                "uuid": "assistant-tool",
                "message": {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": "toolu_xcodebuild",
                        "name": "Bash",
                        "input": {"command": "xcodebuild -list"}
                    }]
                }
            }),
            json!({
                "type": "exit_once",
                "marker": marker.to_string_lossy()
            }),
            json!({
                "type": "user",
                "session_id": "__SESSION__",
                "uuid": "tool-result",
                "message": {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "toolu_xcodebuild",
                        "content": "healthy retry"
                    }]
                },
                "tool_use_result": {
                    "stdout": "healthy retry",
                    "stderr": "",
                    "interrupted": false
                }
            }),
            json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "session_id": "__SESSION__",
                "uuid": "result",
                "result": "healthy retry",
                "stop_reason": "end_turn",
                "permission_denials": []
            }),
        ],
    );

    let previous_script = std::env::var_os("FAKE_CLAUDE_SCRIPT");
    unsafe {
        std::env::set_var("FAKE_CLAUDE_SCRIPT", &script);
    }
    let _restore_script = EnvRestore {
        key: "FAKE_CLAUDE_SCRIPT",
        previous: previous_script,
    };

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
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "exit-recovery", "version": "0.0.1"}}
        }),
    )
    .await
    .expect("initialize");
    let _ = await_response(&mut client_reader, 1).await;

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/start",
            "params": {"cwd": cwd.path().to_string_lossy()}
        }),
    )
    .await
    .expect("thread/start");
    let started = await_response(&mut client_reader, 2).await;
    let thread_id = started["result"]["thread"]["id"]
        .as_str()
        .expect("thread id")
        .to_string();

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"sandboxPolicy":{"type":"dangerFullAccess"},
                "threadId": thread_id,
                "input": [{"type": "text", "text": "first generation"}]
            }
        }),
    )
    .await
    .expect("first turn");
    let first = collect_turn(&mut client_reader, 3).await;
    let first_completed = first
        .iter()
        .find(|message| message["method"] == "turn/completed")
        .expect("first turn/completed");
    assert_eq!(first_completed["params"]["turn"]["status"], "failed");
    assert!(
        first.iter().any(|message| {
            message["method"] == "item/completed"
                && message["params"]["item"]["type"] == "commandExecution"
                && message["params"]["item"]["status"] == "failed"
                && message["params"]["item"]["aggregatedOutput"]
                    .as_str()
                    .is_some_and(|text| text.contains("process exited"))
        }),
        "unexpected exit must close the xcodebuild item as failed: {first:#?}"
    );

    wait_until_pool_empty(&claude_pool).await;

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 4,
            "method": "turn/start",
            "params": {"sandboxPolicy":{"type":"dangerFullAccess"},
                "threadId": thread_id,
                "input": [{"type": "text", "text": "cold recover"}]
            }
        }),
    )
    .await
    .expect("recovery turn");
    let recovered = collect_turn(&mut client_reader, 4).await;
    let recovered_completed = recovered
        .iter()
        .find(|message| message["method"] == "turn/completed")
        .expect("recovered turn/completed");
    assert_eq!(recovered_completed["params"]["turn"]["status"], "completed");
    assert_eq!(
        claude_pool.len().await,
        1,
        "recovery should install exactly one healthy generation"
    );

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
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
    assert!(count > 0, "bridge closed before sending the expected frame");
    serde_json::from_str(line.trim()).expect("valid bridge JSON")
}

async fn wait_until_pool_empty(pool: &ClaudePool) {
    let deadline = Instant::now() + STEP_TIMEOUT;
    while !pool.is_empty().await {
        assert!(
            Instant::now() < deadline,
            "dead Claude generation remained in the process pool"
        );
        tokio::task::yield_now().await;
    }
}

struct EnvRestore {
    key: &'static str,
    previous: Option<std::ffi::OsString>,
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
