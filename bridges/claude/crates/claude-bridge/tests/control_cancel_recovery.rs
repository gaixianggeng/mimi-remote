//! 回归：Claude 发出 `control_cancel_request` 后，bridge 要取消准确的
//! 移动端审批 waiter，并发送 `serverRequest/resolved` 关闭 App 卡片。

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

use support::{fake_claude_path, write_script};

const STEP_TIMEOUT: Duration = Duration::from_secs(8);

#[tokio::test]
async fn control_cancel_request_resolves_mobile_approval_without_reply() {
    let fixture = TempDir::new().expect("fixture");
    let cwd = TempDir::new().expect("cwd");
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
                        "id": "toolu_approval",
                        "name": "Bash",
                        "input": {"command": "xcodebuild -list"}
                    }]
                }
            }),
            json!({
                "type": "control_request",
                "request_id": "claude-approval-1",
                "request": {
                    "subtype": "can_use_tool",
                    "tool_name": "Bash",
                    "tool_use_id": "toolu_approval",
                    "input": {"command": "xcodebuild -list"},
                    "decision_reason": "test approval cancellation"
                }
            }),
            json!({"type": "sleep", "ms": 100}),
            json!({
                "type": "control_cancel_request",
                "request_id": "claude-approval-1"
            }),
            json!({
                "type": "user",
                "session_id": "__SESSION__",
                "uuid": "rejected-tool-result",
                "message": {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "toolu_approval",
                        "content": "User rejected tool use",
                        "is_error": true
                    }]
                },
                "tool_use_result": "User rejected tool use"
            }),
            json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "session_id": "__SESSION__",
                "uuid": "result",
                "result": "cancelled stale approval",
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

    let pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let codex_home = TempDir::new().expect("codex home");
    let index: Arc<dyn ThreadIndexHandle> = ThreadIndex::open_and_hydrate(codex_home.path())
        .await
        .expect("thread index");
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);
    let bridge_pool = Arc::clone(&pool);
    let codex_home_path = codex_home.path().to_path_buf();
    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            bridge_pool,
            index,
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
            "params": {"clientInfo": {"name": "cancel-recovery", "version": "0.0.1"}}
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
        .expect("thread id");

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"sandboxPolicy":{"type":"dangerFullAccess"},
                "threadId": thread_id,
                "input": [{"type": "text", "text": "request then cancel approval"}]
            }
        }),
    )
    .await
    .expect("turn/start");

    let mut approval_id = None;
    let mut resolved_id = None;
    let mut saw_response = false;
    let mut saw_completed = false;
    let mut saw_failed_tool = false;
    for _ in 0..200 {
        let message = next_message(&mut client_reader).await;
        saw_response |= message["id"].as_u64() == Some(3);
        saw_completed |= message["method"] == "turn/completed";
        saw_failed_tool |= message["method"] == "item/completed"
            && message["params"]["item"]["type"] == "commandExecution"
            && message["params"]["item"]["status"] == "failed";
        if message["method"] == "item/commandExecution/requestApproval" {
            approval_id = Some(message["id"].clone());
        }
        if message["method"] == "serverRequest/resolved" {
            resolved_id = Some(message["params"]["requestId"].clone());
        }
        if saw_response
            && saw_completed
            && saw_failed_tool
            && approval_id.is_some()
            && resolved_id.is_some()
        {
            break;
        }
    }
    assert!(saw_response, "turn/start response missing");
    assert!(saw_completed, "turn/completed missing");
    assert!(
        saw_failed_tool,
        "the rejected tool_result must close the existing Bash item"
    );
    assert_eq!(
        resolved_id, approval_id,
        "cancel must resolve the exact approval card without a client reply"
    );

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
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
