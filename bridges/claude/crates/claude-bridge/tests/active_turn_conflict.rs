//! 回归：运行中的 Claude thread 不能被列表/恢复接口误报为 idle，也不能接受
//! 第二个 turn/start。这个测试走完整 JSON-RPC dispatcher 与 fake-claude stdin。

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
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::time::timeout;

use support::{fake_claude_path, write_script};

const STEP_TIMEOUT: Duration = Duration::from_secs(8);

#[tokio::test]
async fn active_thread_is_projected_and_second_turn_is_rejected_before_acceptance() {
    let cwd = TempDir::new().expect("cwd");
    let codex_home = TempDir::new().expect("codex home");
    let fixture = TempDir::new().expect("fixture");
    let turn_log = fixture.path().join("turns.log");
    let script = write_script(
        fixture.path(),
        &[
            // 后续会连续验证 read/list/resume 三个状态表面。给慢速 CI 足够窗口，
            // 避免 fake turn 在最后一个断言前自然完成而把 active 误报成 idle。
            json!({"type":"sleep","ms":5000}),
            json!({
                "type":"result",
                "subtype":"success",
                "is_error":false,
                "duration_ms":5000,
                "duration_api_ms":4990,
                "num_turns":1,
                "result":"done",
                "session_id":"__SESSION__",
                "uuid":"active-conflict-result",
                "total_cost_usd":0.0,
                "usage":{"input_tokens":1,"output_tokens":1}
            }),
        ],
    );
    // fake-claude 在独立测试进程中启动；环境只影响本测试生成的子进程。
    unsafe {
        std::env::set_var("FAKE_CLAUDE_SCRIPT", &script);
        std::env::set_var("FAKE_CLAUDE_TURN_LOG", &turn_log);
    }

    let pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let index: Arc<dyn ThreadIndexHandle> = ThreadIndex::open_and_hydrate(codex_home.path())
        .await
        .expect("thread index");
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);
    let pool_for_bridge = Arc::clone(&pool);
    let codex_home_path = codex_home.path().to_path_buf();
    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            pool_for_bridge,
            index,
            codex_home_path,
        )
        .await
    });
    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"active-conflict-test","version":"1"}}}),
    )
    .await;
    let _ = response(&mut client_reader, 1).await;

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":2,"method":"thread/start","params":{"cwd":cwd.path()}}),
    )
    .await;
    let started = response(&mut client_reader, 2).await;
    let thread_id = started["result"]["thread"]["id"]
        .as_str()
        .expect("thread id")
        .to_string();

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"threadId":thread_id,"input":[{"type":"text","text":"first"}]}}),
    )
    .await;
    let first = response(&mut client_reader, 3).await;
    let first_turn_id = first["result"]["turn"]["id"]
        .as_str()
        .expect("first turn id")
        .to_string();

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":4,"method":"thread/read","params":{"threadId":thread_id,"includeTurns":true}}),
    )
    .await;
    let read = response(&mut client_reader, 4).await;
    assert_eq!(
        read.pointer("/result/thread/status/type"),
        Some(&json!("active"))
    );
    assert_eq!(
        read.pointer("/result/thread/turns/0/status"),
        Some(&json!("inProgress"))
    );

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":5,"method":"turn/start","params":{"threadId":thread_id,"input":[{"type":"text","text":"second"}]}}),
    )
    .await;
    let conflict = response(&mut client_reader, 5).await;
    assert_eq!(conflict.pointer("/error/code"), Some(&json!(-32602)));
    assert_eq!(
        conflict.pointer("/error/data/accepted"),
        Some(&json!(false))
    );
    assert_eq!(
        conflict.pointer("/error/data/reason"),
        Some(&json!("active_turn"))
    );
    assert_eq!(
        conflict.pointer("/error/data/activeTurnId"),
        Some(&json!(first_turn_id))
    );

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":6,"method":"thread/list","params":{}}),
    )
    .await;
    let list = response(&mut client_reader, 6).await;
    let listed = list["result"]["data"]
        .as_array()
        .and_then(|items| items.iter().find(|item| item["id"] == thread_id))
        .expect("listed thread");
    assert_eq!(listed.pointer("/status/type"), Some(&json!("active")));

    send(
        &mut client_writer,
        json!({"jsonrpc":"2.0","id":7,"method":"thread/resume","params":{"threadId":thread_id}}),
    )
    .await;
    let resumed = response(&mut client_reader, 7).await;
    assert_eq!(
        resumed.pointer("/result/thread/status/type"),
        Some(&json!("active"))
    );

    let completed = timeout(STEP_TIMEOUT, async {
        loop {
            let message = next_message(&mut client_reader).await;
            if message["method"] == "turn/completed" {
                return message;
            }
        }
    })
    .await
    .expect("turn completion");
    assert_eq!(
        completed.pointer("/params/turn/id"),
        Some(&json!(first_turn_id))
    );
    assert_eq!(
        std::fs::read_to_string(&turn_log)
            .expect("turn log")
            .lines()
            .collect::<Vec<_>>(),
        vec!["first"],
        "冲突消息不能进入 Claude stdin"
    );

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
}

async fn send<W: tokio::io::AsyncWrite + Unpin>(writer: &mut W, value: Value) {
    write_json_line(writer, &value)
        .await
        .expect("write request");
}

async fn response<R: tokio::io::AsyncRead + Unpin>(reader: &mut BufReader<R>, id: u64) -> Value {
    timeout(STEP_TIMEOUT, async {
        loop {
            let message = next_message(reader).await;
            if message["id"].as_u64() == Some(id) {
                return message;
            }
        }
    })
    .await
    .expect("response timeout")
}

async fn next_message<R: tokio::io::AsyncRead + Unpin>(reader: &mut BufReader<R>) -> Value {
    let mut line = String::new();
    let bytes = timeout(STEP_TIMEOUT, reader.read_line(&mut line))
        .await
        .expect("read timeout")
        .expect("read");
    assert!(bytes > 0, "bridge EOF");
    serde_json::from_str(line.trim()).expect("json frame")
}
