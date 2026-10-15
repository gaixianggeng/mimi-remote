//! 回归测试：客户端 turn 已完成、App 断开后，Claude 自主唤醒产生的新消息
//! 仍进入同一 resident session；重新 attach 后既能回放事件，也能从
//! `thread/read` 读到完整历史。

mod support;

use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::framing::write_json_line;
use alleycat_bridge_core::{
    ATTACH_METHOD, SessionRegistry, SessionRegistryConfig, serve_stream_attached,
};
use alleycat_claude_bridge::ClaudeBridge;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};
use tokio::time::timeout;

use support::{fake_claude_path, write_script};

const STEP_TIMEOUT: Duration = Duration::from_secs(8);

#[tokio::test]
async fn autonomous_reply_survives_disconnect_and_rehydrates_complete_history() {
    let fixture = TempDir::new().expect("fixture");
    let script = write_script(
        fixture.path(),
        &[
            message_start("initial-start", "msg-initial"),
            text_start("initial-block"),
            text_delta("initial-delta", "首轮回复"),
            text_stop("initial-stop"),
            message_stop("initial-message-stop"),
            result("initial-result", "首轮回复"),
            json!({"type":"sleep","ms":1000}),
            // Claude 2.1.215+ 实际会在定时命令边界输出这两种漂移形状。
            json!({"type":"command_lifecycle","command_id":"scheduled-1","phase":"started"}),
            json!({"type":"system","subtype":"status","status":null,"uuid":"idle-status"}),
            message_start("autonomous-start", "msg-autonomous"),
            text_start("autonomous-block"),
            text_delta("autonomous-delta", "五分钟到了，这是完整的延迟回复"),
            text_stop("autonomous-stop"),
            message_stop("autonomous-message-stop"),
            result("autonomous-result", "五分钟到了，这是完整的延迟回复"),
        ],
    );

    let previous_script = std::env::var_os("FAKE_CLAUDE_SCRIPT");
    unsafe {
        std::env::set_var("FAKE_CLAUDE_SCRIPT", &script);
    }
    let _restore = EnvRestore {
        key: "FAKE_CLAUDE_SCRIPT",
        previous: previous_script,
    };

    let codex_home = fixture.path().join("codex-home");
    let projects = fixture.path().join("claude-projects");
    let cwd = fixture.path().join("workspace");
    std::fs::create_dir_all(&cwd).expect("workspace");
    let bridge = ClaudeBridge::builder()
        .agent_bin(fake_claude_path())
        .codex_home(codex_home)
        .projects_dir_override(projects)
        .build()
        .await
        .expect("build bridge");
    let registry = SessionRegistry::new(SessionRegistryConfig {
        idle_ttl: Duration::from_secs(60),
        ..Default::default()
    });
    let session_key = "ios-autonomous-reconnect";

    // 第一次连接：完成用户发起的 turn 后立即离开 App。
    let (client_io, bridge_io) = tokio::io::duplex(128 * 1024);
    let bridge_for_server = Arc::clone(&bridge);
    let registry_for_server = Arc::clone(&registry);
    let server = tokio::spawn(async move {
        serve_stream_attached(bridge_for_server, bridge_io, &registry_for_server, "claude").await
    });
    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0",
            "method":ATTACH_METHOD,
            "params":{"sessionKey":session_key}
        }),
    )
    .await
    .expect("attach");
    let attached = next_message(&mut client_reader).await;
    assert_eq!(attached["params"]["kind"], "fresh");

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0",
            "id":1,
            "method":"initialize",
            "params":{"clientInfo":{"name":"ios-test","version":"1"}}
        }),
    )
    .await
    .expect("initialize");
    let _ = await_response(&mut client_reader, 1).await;

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0",
            "id":2,
            "method":"thread/start",
            "params":{"cwd":cwd}
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
            "jsonrpc":"2.0",
            "id":3,
            "method":"turn/start",
            "params":{"sandboxPolicy":{"type":"dangerFullAccess"},
                "threadId":thread_id,
                "input":[{"type":"text","text":"稍后回复我"}]
            }
        }),
    )
    .await
    .expect("turn/start");

    let mut saw_response = false;
    let mut first_cursor = None;
    while !saw_response || first_cursor.is_none() {
        let frame = next_message(&mut client_reader).await;
        if frame["id"] == 3 {
            saw_response = true;
        }
        if frame["method"] == "turn/completed" {
            first_cursor = Some(
                frame["_alleycat_seq"]
                    .as_u64()
                    .expect("completed notification has replay cursor"),
            );
        }
    }
    let first_cursor = first_cursor.unwrap();

    drop(client_writer);
    drop(client_reader);
    timeout(STEP_TIMEOUT, server)
        .await
        .expect("first connection closes")
        .expect("server task joins")
        .expect("first connection succeeds");

    // App 不在线时 fake Claude 继续输出第二段自主 turn。
    tokio::time::sleep(Duration::from_millis(1_250)).await;

    // 第二次连接：同一个稳定 session key + 客户端已处理 cursor。
    let (client_io, bridge_io) = tokio::io::duplex(128 * 1024);
    let bridge_for_server = Arc::clone(&bridge);
    let registry_for_server = Arc::clone(&registry);
    let server = tokio::spawn(async move {
        serve_stream_attached(bridge_for_server, bridge_io, &registry_for_server, "claude").await
    });
    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0",
            "method":ATTACH_METHOD,
            "params":{"sessionKey":session_key,"lastSeen":first_cursor}
        }),
    )
    .await
    .expect("reattach");
    let attached = next_message(&mut client_reader).await;
    assert_eq!(attached["params"]["kind"], "resumed");

    let mut saw_autonomous_started = false;
    let mut replayed_text = String::new();
    loop {
        let frame = next_message(&mut client_reader).await;
        match frame["method"].as_str() {
            Some("turn/started") => saw_autonomous_started = true,
            Some("item/completed") => {
                if let Some(text) = frame["params"]["item"]["text"].as_str() {
                    replayed_text.push_str(text);
                }
            }
            Some("turn/completed") => break,
            _ => {}
        }
    }
    assert!(
        saw_autonomous_started,
        "replay should contain synthetic turn"
    );
    assert!(
        replayed_text.contains("完整的延迟回复"),
        "replay should contain the complete assistant message: {replayed_text}"
    );

    // 事件回放是快速路径；thread/read 是页面随时打开时的权威恢复路径。
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0",
            "id":4,
            "method":"thread/read",
            "params":{"threadId":thread_id,"includeTurns":true}
        }),
    )
    .await
    .expect("thread/read");
    let history = await_response(&mut client_reader, 4).await;
    let turns = history["result"]["thread"]["turns"]
        .as_array()
        .expect("turn history");
    assert_eq!(
        turns.len(),
        2,
        "client turn + autonomous turn must both remain"
    );
    let history_json = serde_json::to_string(turns).unwrap();
    assert!(history_json.contains("首轮回复"));
    assert!(history_json.contains("完整的延迟回复"));

    drop(client_writer);
    drop(client_reader);
    timeout(STEP_TIMEOUT, server)
        .await
        .expect("second connection closes")
        .expect("server task joins")
        .expect("second connection succeeds");
}

fn message_start(uuid: &str, message_id: &str) -> Value {
    json!({
        "type":"stream_event",
        "session_id":"__SESSION__",
        "uuid":uuid,
        "event":{
            "type":"message_start",
            "message":{
                "id":message_id,
                "type":"message",
                "role":"assistant",
                "content":[],
                "model":"fake-claude-model",
                "stop_reason":null,
                "stop_sequence":null,
                "usage":{"input_tokens":1,"output_tokens":0}
            }
        }
    })
}

fn text_start(uuid: &str) -> Value {
    json!({
        "type":"stream_event",
        "session_id":"__SESSION__",
        "uuid":uuid,
        "event":{
            "type":"content_block_start",
            "index":0,
            "content_block":{"type":"text","text":""}
        }
    })
}

fn text_delta(uuid: &str, text: &str) -> Value {
    json!({
        "type":"stream_event",
        "session_id":"__SESSION__",
        "uuid":uuid,
        "event":{
            "type":"content_block_delta",
            "index":0,
            "delta":{"type":"text_delta","text":text}
        }
    })
}

fn text_stop(uuid: &str) -> Value {
    json!({
        "type":"stream_event",
        "session_id":"__SESSION__",
        "uuid":uuid,
        "event":{"type":"content_block_stop","index":0}
    })
}

fn message_stop(uuid: &str) -> Value {
    json!({
        "type":"stream_event",
        "session_id":"__SESSION__",
        "uuid":uuid,
        "event":{"type":"message_stop"}
    })
}

fn result(uuid: &str, text: &str) -> Value {
    json!({
        "type":"result",
        "subtype":"success",
        "is_error":false,
        "session_id":"__SESSION__",
        "uuid":uuid,
        "duration_ms":5,
        "duration_api_ms":5,
        "num_turns":1,
        "result":text,
        "stop_reason":"end_turn",
        "usage":{"input_tokens":1,"output_tokens":1},
        "permission_denials":[]
    })
}

async fn next_message<R: AsyncBufRead + Unpin>(reader: &mut R) -> Value {
    let mut line = String::new();
    let read = timeout(STEP_TIMEOUT, reader.read_line(&mut line))
        .await
        .expect("message timeout")
        .expect("read frame");
    assert!(read > 0, "connection closed before next frame");
    serde_json::from_str(line.trim()).expect("valid JSON-RPC frame")
}

async fn await_response<R: AsyncBufRead + Unpin>(reader: &mut R, id: u64) -> Value {
    loop {
        let frame = next_message(reader).await;
        if frame["id"] == id {
            return frame;
        }
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
