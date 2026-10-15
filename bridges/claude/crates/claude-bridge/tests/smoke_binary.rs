//! Subprocess smoke: spawn the `alleycat-claude-bridge` binary in stdio
//! mode with `CLAUDE_BRIDGE_CLAUDE_BIN` pointed at `fake-claude`, then
//! drive it over stdin/stdout with hand-rolled JSON-RPC frames.
//!
//! This exercises the full binary boundary — exactly what the iroh-host
//! and the operator-supplied stdio harness use in production. Pairs with
//! `smoke_in_process.rs` (which exercises the in-process boundary) so
//! both call sites have coverage.

mod support;

use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

use support::{alleycat_claude_bridge_path, fake_claude_path};

const STEP_TIMEOUT: Duration = Duration::from_secs(10);

#[tokio::test]
async fn binary_stdio_initialize_thread_start_turn_start() {
    let cwd = TempDir::new().unwrap();
    let codex_home = TempDir::new().unwrap();
    let claude_projects = TempDir::new().unwrap();

    let mut child = Command::new(alleycat_claude_bridge_path())
        // Force the bridge to spawn `fake-claude` instead of real claude.
        .env("CLAUDE_BRIDGE_CLAUDE_BIN", fake_claude_path())
        // Isolate the on-disk thread index AND the projects-scan source
        // from the developer machine.
        .env("CODEX_HOME", codex_home.path())
        .env("CLAUDE_PROJECTS_DIR", claude_projects.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn alleycat-claude-bridge");

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stdout = BufReader::new(stdout);

    // initialize
    write_frame(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "smoke-binary", "version": "0.0.1"}}
        }),
    )
    .await;
    let init = await_response(&mut stdout, 1).await;
    assert!(
        init.get("result")
            .and_then(|r| r.get("userAgent"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .is_some(),
        "initialize should report a non-empty userAgent: {init}"
    );

    // thread/start
    write_frame(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/start",
            "params": {"cwd": cwd.path().to_string_lossy()}
        }),
    )
    .await;
    let start = await_response(&mut stdout, 2).await;
    let thread_id = start
        .get("result")
        .and_then(|r| r.get("thread"))
        .and_then(|t| t.get("id"))
        .and_then(|v| v.as_str())
        .expect("thread/start must mint an id")
        .to_string();
    assert!(!thread_id.is_empty());

    // turn/start
    write_frame(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"sandboxPolicy":{"type":"dangerFullAccess"},
                "threadId": thread_id,
                "input": [{"type": "text", "text": "say hi"}],
                "clientUserMessageId": "client-smoke-binary"
            }
        }),
    )
    .await;

    let mut saw_completed = false;
    let mut saw_response = false;
    let mut saw_client_message_id = false;
    for _ in 0..200 {
        let frame = next_frame(&mut stdout).await;
        if frame.get("id").and_then(|v| v.as_u64()) == Some(3) {
            saw_response = true;
            assert!(
                frame.get("error").is_none(),
                "turn/start response should not error: {frame}"
            );
        }
        if frame.get("method").and_then(|v| v.as_str()) == Some("turn/completed") {
            saw_completed = true;
        }
        if frame.get("method").and_then(|v| v.as_str()) == Some("item/completed")
            && frame.pointer("/params/item/type").and_then(Value::as_str) == Some("userMessage")
        {
            assert_eq!(
                frame
                    .pointer("/params/item/clientId")
                    .and_then(Value::as_str),
                Some("client-smoke-binary"),
                "userMessage lifecycle must preserve clientUserMessageId: {frame}"
            );
            saw_client_message_id = true;
        }
        if saw_completed && saw_response && saw_client_message_id {
            break;
        }
    }
    assert!(saw_response, "turn/start response (id=3) must come back");
    assert!(
        saw_completed,
        "expected a turn/completed notification before timeout"
    );
    assert!(
        saw_client_message_id,
        "expected userMessage.clientId to survive the binary JSON-RPC boundary"
    );

    // thread/read 必须继续返回同一个 clientId；这正是 iOS 刷新历史时
    // 将本地气泡与服务端快照合并为同一条消息的稳定键。
    write_frame(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 4,
            "method": "thread/read",
            "params": {"threadId": thread_id, "includeTurns": true}
        }),
    )
    .await;
    let read = await_response(&mut stdout, 4).await;
    let history_user_message = read
        .pointer("/result/thread/turns")
        .and_then(Value::as_array)
        .and_then(|turns| {
            turns
                .iter()
                .filter_map(|turn| turn.get("items").and_then(Value::as_array))
                .flatten()
                .find(|item| item.get("type").and_then(Value::as_str) == Some("userMessage"))
        })
        .expect("thread/read should contain the userMessage");
    assert_eq!(
        history_user_message.get("clientId").and_then(Value::as_str),
        Some("client-smoke-binary"),
        "thread/read must preserve the client ID used by iOS history rebase: {read}"
    );

    // Clean exit: drop stdin → bridge sees EOF → child exits.
    drop(stdin);
    let _ = timeout(STEP_TIMEOUT, child.wait()).await;
}

async fn write_frame(stdin: &mut tokio::process::ChildStdin, value: &Value) {
    let mut line = serde_json::to_string(value).expect("serialize frame");
    line.push('\n');
    stdin
        .write_all(line.as_bytes())
        .await
        .expect("write to bridge stdin");
    stdin.flush().await.expect("flush bridge stdin");
}

async fn next_frame<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> Value {
    let mut line = String::new();
    let n = timeout(STEP_TIMEOUT, reader.read_line(&mut line))
        .await
        .expect("bridge produced a frame before timeout")
        .expect("bridge stdout read");
    assert!(n > 0, "bridge closed stdout before sending a frame");
    serde_json::from_str(line.trim()).unwrap_or_else(|err| {
        panic!("bridge frame was not valid JSON: {err}; raw=`{line}`");
    })
}

async fn await_response<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R, id: u64) -> Value {
    for _ in 0..200 {
        let frame = next_frame(reader).await;
        if frame.get("id").and_then(|v| v.as_u64()) == Some(id) {
            return frame;
        }
    }
    panic!("never saw response for id={id}");
}
