//! `thread/takeover`：只对登记了该 session、pid 存活且启动时间吻合的持有方发信号；
//! SIGINT 无效时退到 SIGTERM；两者都无效时报可重试的超时；持有方退出后若有新进程
//! 认领同一 session 则停手；无持有方 / 别的 session / legacy 策略下等价于普通 resume。
//! 假持有方用 `sleep` 子进程冒充终端里的 `claude`，登记目录用临时目录。

#![cfg(unix)]

mod support;

use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use alleycat_bridge_core::framing::write_json_line;
use alleycat_bridge_core::{
    ATTACH_METHOD, SessionRegistry, SessionRegistryConfig, serve_stream_attached,
};
use alleycat_claude_bridge::ClaudeBridge;
use alleycat_claude_bridge::foreign_session::ForeignSessionPolicy;
use alleycat_claude_bridge::takeover::TakeoverTimeouts;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};
use tokio::time::timeout;

use support::fake_claude_path;

const STEP_TIMEOUT: Duration = Duration::from_secs(8);
const CWD: &str = "/private/tmp/mimi-foreign-session-takeover";
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
        .join("-private-tmp-mimi-foreign-session-takeover");
    let sessions_dir = dir.path().join("claude-sessions");
    std::fs::create_dir_all(&encoded_cwd).expect("projects dir");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let record = json!({
        "type": "user",
        "cwd": CWD,
        "message": {"role": "user", "content": "held prompt"},
        "timestamp": "2026-09-13T08:00:00Z"
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

fn now_ms() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_millis(),
    )
    .expect("fits u64")
}

fn write_registry_record(
    sessions_dir: &Path,
    pid: u32,
    session_id: &str,
    started_at_ms: Option<u64>,
) -> PathBuf {
    let mut record = json!({
        "pid": pid,
        "sessionId": session_id,
        "cwd": CWD,
        "entrypoint": "cli",
        "kind": "interactive",
        "status": "busy",
        "version": "2.1.270",
        "messagingSocketPath": "/tmp/cc-socks/ignored.sock"
    });
    if let Some(started_at_ms) = started_at_ms {
        record["startedAt"] = json!(started_at_ms);
    }
    let path = sessions_dir.join(format!("{pid}.json"));
    std::fs::write(&path, record.to_string()).expect("write registry record");
    path
}

/// 冒充终端 `claude` 的长驻子进程。终端会立刻回收退出的子进程，这里用一个线程
/// 代替：否则僵尸进程对 `kill(pid, 0)` 仍然"活着"，bridge 会一直等下去。
struct Holder {
    pid: u32,
    exit: mpsc::Receiver<ExitStatus>,
    _marker_dir: TempDir,
}

impl Holder {
    /// `setup` 是 exec 到 `sleep` 之前要跑的 shell 语句（比如 `trap '' INT`）。
    /// 必须等 setup 真正执行完再返回：并行测试下信号可能抢在 trap 之前送达，
    /// 那样被结束的是还没设好 trap 的 sh，测试就会假失败。
    fn spawn(setup: &str) -> Self {
        let marker_dir = TempDir::new().expect("marker dir");
        let marker = marker_dir.path().join("ready");
        let prefix = if setup.is_empty() {
            String::new()
        } else {
            format!("{setup}; ")
        };
        let script = format!("{prefix}: > '{}'; exec sleep 60", marker.display());
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg(script)
            .spawn()
            .expect("spawn holder");
        let pid = child.id();
        let (tx, exit) = mpsc::channel();
        std::thread::spawn(move || {
            let status = child.wait().expect("wait holder");
            let _ = tx.send(status);
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !marker.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "holder did not finish its setup in time"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        Self {
            pid,
            exit,
            _marker_dir: marker_dir,
        }
    }

    fn exit_signal(&self, wait: Duration) -> Option<i32> {
        self.exit
            .recv_timeout(wait)
            .ok()
            .and_then(|status| status.signal())
    }

    fn still_running(&self, observe: Duration) -> bool {
        self.exit.recv_timeout(observe).is_err()
    }

    fn force_kill(&self) {
        let _ = std::process::Command::new("kill")
            .args(["-9", &self.pid.to_string()])
            .status();
        let _ = self.exit.recv_timeout(Duration::from_secs(5));
    }
}

fn fast_timeouts() -> TakeoverTimeouts {
    TakeoverTimeouts {
        interrupt_grace: Duration::from_millis(400),
        terminate_grace: Duration::from_millis(400),
        respawn_grace: Duration::from_millis(200),
    }
}

async fn build_bridge(
    fixture: &Fixture,
    policy: ForeignSessionPolicy,
    timeouts: TakeoverTimeouts,
) -> Arc<ClaudeBridge> {
    ClaudeBridge::builder()
        .agent_bin(fake_claude_path())
        .codex_home(fixture.codex_home.clone())
        .projects_dir_override(fixture.encoded_cwd.clone())
        .sessions_dir_override(fixture.sessions_dir.clone())
        .foreign_session_policy(policy)
        .takeover_timeouts(timeouts)
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

async fn takeover(writer: &mut Writer, reader: &mut Reader, id: i64) -> Value {
    request(
        writer,
        reader,
        id,
        "thread/takeover",
        json!({"threadId": SESSION_ID, "cwd": CWD, "excludeTurns": true}),
    )
    .await
}

#[tokio::test]
async fn takeover_interrupts_registered_holder_and_resumes_writable() {
    let fixture = fixture();
    let holder = Holder::spawn("");
    // sleep 不会像 claude 那样删掉自己的登记；bridge 必须按 pid 已退出放行。
    let record = write_registry_record(
        &fixture.sessions_dir,
        holder.pid,
        SESSION_ID,
        Some(now_ms()),
    );
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard, fast_timeouts()).await;
    let (mut writer, mut reader) = attach(&bridge, "takeover").await;

    let held = request(
        &mut writer,
        &mut reader,
        1,
        "thread/read",
        json!({"threadId": SESSION_ID, "includeTurns": false}),
    )
    .await;
    assert_eq!(
        held["result"]["thread"]["canAcceptDirectInput"],
        json!(false),
        "{held}"
    );

    let taken = takeover(&mut writer, &mut reader, 2).await;
    assert!(taken.get("error").is_none(), "{taken}");
    assert_eq!(
        taken["result"]["takeover"]["released"],
        json!(true),
        "{taken}"
    );
    assert_eq!(taken["result"]["takeover"]["signal"], json!("SIGINT"));
    assert_eq!(
        taken["result"]["takeover"]["holder"]["pid"],
        json!(holder.pid)
    );
    assert_eq!(
        taken["result"]["thread"]["canAcceptDirectInput"],
        json!(true),
        "{taken}"
    );
    assert!(taken["result"]["thread"].get("claudeOwner").is_none());
    assert_eq!(taken["result"]["thread"]["id"], json!(SESSION_ID));
    assert_eq!(
        holder.exit_signal(Duration::from_secs(2)),
        Some(libc_sigint()),
        "持有方应被 SIGINT 结束"
    );
    assert!(record.exists(), "残留登记不影响接管结果");
    assert!(
        !bridge.pool().is_empty().await,
        "接管后应立刻由 bridge 持有该会话"
    );

    let read = request(
        &mut writer,
        &mut reader,
        3,
        "thread/read",
        json!({"threadId": SESSION_ID, "includeTurns": false}),
    )
    .await;
    assert_eq!(
        read["result"]["thread"]["canAcceptDirectInput"],
        json!(true),
        "{read}"
    );
}

#[tokio::test]
async fn takeover_leaves_processes_registered_for_other_sessions_alone() {
    let fixture = fixture();
    let bystander = Holder::spawn("");
    write_registry_record(
        &fixture.sessions_dir,
        bystander.pid,
        "some-other-session",
        Some(now_ms()),
    );
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard, fast_timeouts()).await;
    let (mut writer, mut reader) = attach(&bridge, "bystander").await;

    let taken = takeover(&mut writer, &mut reader, 1).await;
    assert!(taken.get("error").is_none(), "{taken}");
    assert_eq!(
        taken["result"]["takeover"]["released"],
        json!(false),
        "{taken}"
    );
    assert_eq!(
        taken["result"]["thread"]["canAcceptDirectInput"],
        json!(true)
    );
    assert!(
        bystander.still_running(Duration::from_millis(300)),
        "未登记该 session 的进程一个信号都不能收到"
    );
    bystander.force_kill();
}

#[tokio::test]
async fn legacy_policy_makes_takeover_a_plain_resume() {
    let fixture = fixture();
    let holder = Holder::spawn("");
    write_registry_record(
        &fixture.sessions_dir,
        holder.pid,
        SESSION_ID,
        Some(now_ms()),
    );
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Legacy, fast_timeouts()).await;
    let (mut writer, mut reader) = attach(&bridge, "legacy").await;

    let taken = takeover(&mut writer, &mut reader, 1).await;
    assert!(taken.get("error").is_none(), "{taken}");
    assert_eq!(
        taken["result"]["takeover"]["released"],
        json!(false),
        "{taken}"
    );
    assert!(
        holder.still_running(Duration::from_millis(300)),
        "kill switch 打开时不得给任何进程发信号"
    );
    holder.force_kill();
}

#[tokio::test]
async fn takeover_refuses_holder_whose_start_time_does_not_match_registration() {
    let fixture = fixture();
    let holder = Holder::spawn("");
    // 登记说进程一小时前就启动了，而 sleep 刚起：pid 很可能被复用，不能杀。
    write_registry_record(
        &fixture.sessions_dir,
        holder.pid,
        SESSION_ID,
        Some(now_ms() - 3_600_000),
    );
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard, fast_timeouts()).await;
    let (mut writer, mut reader) = attach(&bridge, "stale").await;

    let refused = takeover(&mut writer, &mut reader, 1).await;
    let error = refused
        .get("error")
        .unwrap_or_else(|| panic!("takeover must fail: {refused}"));
    assert_eq!(
        error["data"]["reason"],
        json!("holder_unverified"),
        "{refused}"
    );
    assert_eq!(error["data"]["retryable"], json!(false));
    assert_eq!(error["data"]["claudeOwner"]["pid"], json!(holder.pid));
    assert!(holder.still_running(Duration::from_millis(300)));
    assert!(bridge.pool().is_empty().await, "拒绝后不得起进程");

    // 没有 startedAt 的登记同样无法核实。
    write_registry_record(&fixture.sessions_dir, holder.pid, SESSION_ID, None);
    let refused = takeover(&mut writer, &mut reader, 2).await;
    assert_eq!(
        refused["error"]["data"]["reason"],
        json!("holder_unverified"),
        "{refused}"
    );
    assert!(holder.still_running(Duration::from_millis(300)));
    holder.force_kill();
}

#[tokio::test]
async fn takeover_falls_back_to_sigterm_when_holder_ignores_sigint() {
    let fixture = fixture();
    // SIG_IGN 会跨 exec 继承：sleep 忽略 SIGINT，只有 SIGTERM 能结束它。
    let holder = Holder::spawn("trap '' INT");
    write_registry_record(
        &fixture.sessions_dir,
        holder.pid,
        SESSION_ID,
        Some(now_ms()),
    );
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard, fast_timeouts()).await;
    let (mut writer, mut reader) = attach(&bridge, "sigterm").await;

    let taken = takeover(&mut writer, &mut reader, 1).await;
    assert!(taken.get("error").is_none(), "{taken}");
    assert_eq!(
        taken["result"]["takeover"]["released"],
        json!(true),
        "{taken}"
    );
    assert_eq!(taken["result"]["takeover"]["signal"], json!("SIGTERM"));
    assert_eq!(
        holder.exit_signal(Duration::from_secs(2)),
        Some(libc_sigterm())
    );
}

#[tokio::test]
async fn takeover_reports_retryable_timeout_when_holder_ignores_both_signals() {
    let fixture = fixture();
    let holder = Holder::spawn("trap '' INT TERM");
    write_registry_record(
        &fixture.sessions_dir,
        holder.pid,
        SESSION_ID,
        Some(now_ms()),
    );
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard, fast_timeouts()).await;
    let (mut writer, mut reader) = attach(&bridge, "timeout").await;

    let refused = takeover(&mut writer, &mut reader, 1).await;
    let error = refused
        .get("error")
        .unwrap_or_else(|| panic!("takeover must time out: {refused}"));
    assert_eq!(
        error["data"]["reason"],
        json!("takeover_timeout"),
        "{refused}"
    );
    assert_eq!(error["data"]["retryable"], json!(true));
    assert!(holder.still_running(Duration::from_millis(100)));
    assert!(bridge.pool().is_empty().await, "超时后不得起进程");
    holder.force_kill();
}

#[tokio::test]
async fn takeover_stops_when_a_new_process_claims_the_session_after_the_holder_exits() {
    let fixture = fixture();
    let holder = Holder::spawn("");
    let respawned = Holder::spawn("");
    write_registry_record(
        &fixture.sessions_dir,
        holder.pid,
        SESSION_ID,
        Some(now_ms()),
    );
    // 模拟宿主自动重启：原持有方一退出就有新 pid 登记同一个 session。
    let sessions_dir = fixture.sessions_dir.clone();
    let respawned_pid = respawned.pid;
    let holder_exit = holder.exit;
    std::thread::spawn(move || {
        let _ = holder_exit.recv_timeout(Duration::from_secs(5));
        write_registry_record(&sessions_dir, respawned_pid, SESSION_ID, Some(now_ms()));
    });
    let mut timeouts = fast_timeouts();
    timeouts.respawn_grace = Duration::from_millis(800);
    let bridge = build_bridge(&fixture, ForeignSessionPolicy::Guard, timeouts).await;
    let (mut writer, mut reader) = attach(&bridge, "respawn").await;

    let refused = takeover(&mut writer, &mut reader, 1).await;
    let error = refused
        .get("error")
        .unwrap_or_else(|| panic!("takeover must stop: {refused}"));
    assert_eq!(
        error["data"]["reason"],
        json!("holder_respawned"),
        "{refused}"
    );
    assert_eq!(error["data"]["retryable"], json!(false));
    assert_eq!(error["data"]["claudeOwner"]["pid"], json!(respawned_pid));
    assert!(
        respawned.still_running(Duration::from_millis(300)),
        "新认领者不得再被发信号"
    );
    assert!(bridge.pool().is_empty().await);
    respawned.force_kill();
}

fn libc_sigint() -> i32 {
    2
}

fn libc_sigterm() -> i32 {
    15
}
