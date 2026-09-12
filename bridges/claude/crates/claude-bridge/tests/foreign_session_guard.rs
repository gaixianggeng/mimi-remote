//! 会话被本机其他 Claude 进程持有时的守卫：不起第二个进程、会话只读、
//! `turn/start` 拒绝；持有方退出后恢复；legacy 策略和残留登记不影响旧行为。
//! 登记目录用临时目录代替 `~/.claude/sessions`。

mod support;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::framing::write_json_line;
use alleycat_bridge_core::{
    ATTACH_METHOD, SessionRegistry, SessionRegistryConfig, serve_stream_attached,
};
use alleycat_claude_bridge::ClaudeBridge;
use alleycat_claude_bridge::foreign_session::ForeignSessionPolicy;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};
use tokio::time::timeout;

use support::fake_claude_path;

const STEP_TIMEOUT: Duration = Duration::from_secs(8);
const CWD: &str = "/private/tmp/mimi-foreign-session-guard";
const SESSION_ID: &str = "held-session";

struct Fixture {
    _dir: TempDir,
    codex_home: PathBuf,
    encoded_cwd: PathBuf,
    sessions_dir: PathBuf,
}

fn fixture() -> Fixture {
    let dir = TempDir::new().expect("fixture");
    let codex_home = dir.path().join("codex-home");
    let encoded_cwd = dir
        .path()
        .join("claude-projects")
        .join("-private-tmp-mimi-foreign-session-guard");
    let sessions_dir = dir.path().join("claude-sessions");
    std::fs::create_dir_all(&encoded_cwd).expect("projects dir");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let record = json!({
        "type": "user",
        "cwd": CWD,
        "message": {"role": "user", "content": "held prompt"},
        "timestamp": "2026-09-12T08:00:00Z"
    });
    std::fs::write(
        encoded_cwd.join(format!("{SESSION_ID}.jsonl")),
        format!("{record}\n"),
    )
    .expect("write transcript");
    Fixture {
        _dir: dir,
        codex_home,
        encoded_cwd,
        sessions_dir,
    }
}

fn write_registry_record(sessions_dir: &Path, pid: u32, status: Option<&str>) -> PathBuf {
    let mut record = json!({
        "pid": pid,
        "sessionId": SESSION_ID,
        "cwd": CWD,
        "entrypoint": "cli",
        "kind": "interactive",
        "version": "2.1.269",
        "messagingSocketPath": "/tmp/cc-socks/ignored.sock"
    });
    if let Some(status) = status {
        record["status"] = json!(status);
    }
    let path = sessions_dir.join(format!("{pid}.json"));
    std::fs::write(&path, record.to_string()).expect("write registry record");
    path
}

/// 已退出的子进程 pid：`true` 立即返回，wait 之后一定不再存活。
fn dead_pid() -> u32 {
    let mut child = std::process::Command::new("true")
        .spawn()
        .expect("spawn true");
    let pid = child.id();
    child.wait().expect("wait true");
    pid
}

async fn build_bridge(fixture: &Fixture, policy: ForeignSessionPolicy) -> Arc<ClaudeBridge> {
    ClaudeBridge::builder()
        .agent_bin(fake_claude_path())
        .codex_home(fixture.codex_home.clone())
        .projects_dir_override(fixture.encoded_cwd.clone())
        .sessions_dir_override(fixture.sessions_dir.clone())
        .foreign_session_policy(policy)
        .history_refresh_interval(Duration::from_secs(60))
        .build()
        .await
        .expect("build bridge")
}

type Reader = BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>;
type Writer = tokio::io::WriteHalf<tokio::io::DuplexStream>;

async fn attach(bridge: &Arc<ClaudeBridge>, session_key: &str) -> (Writer, Reader) {
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let bridge_for_server = Arc::clone(bridge);
    tokio::spawn(async move {
        serve_stream_attached(bridge_for_server, bridge_io, &registry, "claude").await
    });
    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);
    write_json_line(
        &mut client_writer,
        &json!({"jsonrpc":"2.0","method":ATTACH_METHOD,"params":{"sessionKey":session_key}}),
    )
    .await
    .expect("attach");
    let _ = next_message(&mut client_reader).await;
    (client_writer, client_reader)
}

async fn request(
    writer: &mut Writer,
    reader: &mut Reader,
    id: i64,
    method: &str,
    params: Value,
) -> Value {
    write_json_line(
        writer,
        &json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
    )
    .await
    .expect("write request");
    loop {
        let frame = next_message(reader).await;
        if frame["id"] == id {
            return frame;
        }
    }
}

async fn next_message<R: AsyncBufRead + Unpin>(reader: &mut R) -> Value {
    timeout(STEP_TIMEOUT, async {
        let mut line = String::new();
        let count = reader.read_line(&mut line).await.expect("read frame");
        assert!(count > 0, "bridge closed before response");
        serde_json::from_str(line.trim_end()).expect("valid JSON frame")
    })
    .await
    .expect("frame timeout")
}

fn listed_thread<'a>(response: &'a Value, id: &str) -> &'a Value {
    response["result"]["data"]
        .as_array()
        .expect("thread/list data")
        .iter()
        .find(|thread| thread["id"] == id)
        .unwrap_or_else(|| panic!("thread {id} missing from {response}"))
}

#[cfg(unix)]
#[tokio::test]
async fn held_session_is_read_only_and_turn_start_is_refused_until_owner_exits() {
    let fixture = fixture();
    // 用测试进程自己的 pid 冒充终端里的 `claude`：它一定活着，也不在进程池里。
    let owner_pid = std::process::id();
    let record = write_registry_record(&fixture.sessions_dir, owner_pid, Some("busy"));
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard).await;
    let (mut writer, mut reader) = attach(&bridge, "guard").await;

    let listed = request(
        &mut writer,
        &mut reader,
        1,
        "thread/list",
        json!({"cwd": CWD, "refreshHistory": true}),
    )
    .await;
    let entry = listed_thread(&listed, SESSION_ID);
    assert_eq!(entry["canAcceptDirectInput"], json!(false), "{listed}");
    assert_eq!(entry["claudeOwner"]["entrypoint"], json!("cli"));
    assert_eq!(entry["claudeOwner"]["status"], json!("busy"));
    assert_eq!(entry["claudeOwner"]["pid"], json!(owner_pid));
    assert!(
        entry["claudeOwner"].get("cwd").is_none(),
        "持有方摘要不得带 cwd"
    );

    let resumed = request(
        &mut writer,
        &mut reader,
        2,
        "thread/resume",
        json!({"threadId": SESSION_ID}),
    )
    .await;
    assert!(resumed.get("error").is_none(), "{resumed}");
    assert_eq!(
        resumed["result"]["thread"]["canAcceptDirectInput"],
        json!(false)
    );
    assert_eq!(
        resumed["result"]["thread"]["claudeOwner"]["pid"],
        json!(owner_pid)
    );
    assert!(
        bridge.pool().is_empty().await,
        "别处持有时 thread/resume 不得起第二个 claude 进程"
    );

    let refused = request(
        &mut writer,
        &mut reader,
        3,
        "turn/start",
        json!({"threadId": SESSION_ID, "input": [{"type": "text", "text": "hi"}]}),
    )
    .await;
    let error = refused
        .get("error")
        .unwrap_or_else(|| panic!("turn/start must fail: {refused}"));
    assert_eq!(
        error["data"]["reason"],
        json!("owned_elsewhere"),
        "{refused}"
    );
    assert_eq!(error["data"]["retryable"], json!(true));
    assert_eq!(error["data"]["claudeOwner"]["entrypoint"], json!("cli"));
    assert!(
        bridge.pool().is_empty().await,
        "被拒绝的 turn/start 不得起 claude 进程"
    );

    // 持有方退出：Claude 会删掉自己的登记文件，会话立刻恢复可写。
    std::fs::remove_file(&record).expect("remove registry record");
    let read = request(
        &mut writer,
        &mut reader,
        4,
        "thread/read",
        json!({"threadId": SESSION_ID, "includeTurns": false}),
    )
    .await;
    assert!(
        read["result"]["thread"]
            .get("canAcceptDirectInput")
            .is_none(),
        "{read}"
    );
    assert!(read["result"]["thread"].get("claudeOwner").is_none());
    let listed = request(
        &mut writer,
        &mut reader,
        5,
        "thread/list",
        json!({"cwd": CWD}),
    )
    .await;
    assert!(
        listed_thread(&listed, SESSION_ID)
            .get("claudeOwner")
            .is_none()
    );
}

#[cfg(unix)]
#[tokio::test]
async fn legacy_policy_and_stale_registry_records_keep_sessions_writable() {
    let legacy_fixture = fixture();
    write_registry_record(
        &legacy_fixture.sessions_dir,
        std::process::id(),
        Some("busy"),
    );
    let legacy = build_bridge(&legacy_fixture, ForeignSessionPolicy::Legacy).await;
    let (mut writer, mut reader) = attach(&legacy, "legacy").await;
    let read = request(
        &mut writer,
        &mut reader,
        1,
        "thread/read",
        json!({"threadId": SESSION_ID, "includeTurns": false}),
    )
    .await;
    assert!(
        read["result"]["thread"]
            .get("canAcceptDirectInput")
            .is_none(),
        "legacy 策略必须无视登记：{read}"
    );

    // 残留登记（进程已退出）不能把会话锁死。
    let stale = fixture();
    write_registry_record(&stale.sessions_dir, dead_pid(), None);
    let guarded = build_bridge(&stale, ForeignSessionPolicy::Guard).await;
    let (mut writer, mut reader) = attach(&guarded, "stale").await;
    let read = request(
        &mut writer,
        &mut reader,
        1,
        "thread/read",
        json!({"threadId": SESSION_ID, "includeTurns": false}),
    )
    .await;
    assert!(
        read["result"]["thread"].get("claudeOwner").is_none(),
        "已退出进程的残留登记不得算作持有方：{read}"
    );
}
