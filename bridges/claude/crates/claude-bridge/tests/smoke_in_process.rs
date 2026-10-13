//! In-process smoke: drives `run_connection` directly against a duplex
//! pipe with a `ClaudePool` that spawns the `fake-claude` test binary.
//!
//! Mirrors `crates/pi-bridge/tests/v1_codex_smoke.rs` in spirit but goes
//! through the full JSON-RPC dispatcher (not just hand-called handlers),
//! so this exercises the whole `initialize → thread/start → turn/start`
//! happy-path including the dispatch table claude-stubs landed in #4.
//!
//! The transport is a `tokio::io::duplex` pair: the bridge reads from one
//! end, the test writes JSON-RPC frames to the other and reads
//! notifications + responses back. The backend `claude` is the
//! `fake-claude` binary — no real claude install required.

mod support;

use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::framing::write_json_line;
use alleycat_claude_bridge::index::ThreadIndex;
use alleycat_claude_bridge::pool::ClaudePool;
use alleycat_claude_bridge::run_connection;
use alleycat_claude_bridge::state::ThreadIndexHandle;
use serde_json::{Value, json};
use std::time::Instant;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::time::timeout;

use support::fake_claude_path;

/// Cap on each individual request/notification wait. Generous enough that a
/// loaded CI box doesn't false-positive but small enough that a real
/// regression surfaces fast.
const STEP_TIMEOUT: Duration = Duration::from_secs(8);

#[tokio::test]
async fn initialize_thread_start_turn_start_against_fake_claude() {
    let cwd = TempDir::new().expect("cwd tempdir");

    // Build the bridge state. Lazy first-turn startup resolves the cwd from
    // the index, so this smoke test uses the same temp-backed index as prod.
    let claude_pool = Arc::new(ClaudePool::new(fake_claude_path()));

    // codex_home for the bridge's lifecycle handler — irrelevant for the
    // happy path but the API needs a writable directory.
    let codex_home_dir = TempDir::new().expect("codex_home tempdir");
    let codex_home = codex_home_dir.path().to_path_buf();
    let thread_index: Arc<dyn ThreadIndexHandle> = ThreadIndex::open_and_hydrate(&codex_home)
        .await
        .expect("open thread index");

    // Duplex pair: `client_*` is the test driver's view; the bridge owns
    // the other half.
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);

    // Spawn the bridge connection driver in the background.
    let pool_for_bridge = Arc::clone(&claude_pool);
    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            pool_for_bridge,
            thread_index,
            codex_home,
        )
        .await
    });

    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);

    // --- initialize -------------------------------------------------------
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "smoke-in-process",
                    "version": "0.0.1"
                }
            }
        }),
    )
    .await
    .expect("write initialize");

    let init = await_response(&mut client_reader, 1).await;
    let result = init.get("result").expect("initialize result");
    assert!(
        result
            .get("userAgent")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .is_some(),
        "initialize must report a non-empty userAgent: {init}"
    );

    // --- thread/start -----------------------------------------------------
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/start",
            "params": {
                "cwd": cwd.path().to_string_lossy()
            }
        }),
    )
    .await
    .expect("write thread/start");

    let thread_resp = await_response(&mut client_reader, 2).await;
    let thread = thread_resp
        .get("result")
        .and_then(|r| r.get("thread"))
        .expect("thread/start should return thread");
    let thread_id = thread
        .get("id")
        .and_then(|v| v.as_str())
        .expect("thread.id")
        .to_string();
    assert!(!thread_id.is_empty(), "thread/start must mint a thread id");
    assert!(
        claude_pool.is_empty().await,
        "empty local thread/start must not spawn claude"
    );

    // --- turn/start -------------------------------------------------------
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"sandboxPolicy":{"type":"dangerFullAccess"},
                "threadId": thread_id,
                "input": [{"type": "text", "text": "say hi"}]
            }
        }),
    )
    .await
    .expect("write turn/start");

    // The pump streams notifications back AND a final response to id=3.
    // Drain until we see `turn/completed` (or the bridge sends an error).
    let mut saw_turn_completed = false;
    let mut saw_turn_response = false;
    for _ in 0..200 {
        let msg = next_msg(&mut client_reader).await;
        if msg.get("id").and_then(|v| v.as_u64()) == Some(3) {
            saw_turn_response = true;
            assert!(
                msg.get("error").is_none(),
                "turn/start response should not error: {msg}"
            );
        }
        if msg.get("method").and_then(|v| v.as_str()) == Some("turn/completed") {
            saw_turn_completed = true;
        }
        if saw_turn_completed && saw_turn_response {
            break;
        }
    }
    assert!(
        saw_turn_response,
        "turn/start response (id=3) must come back"
    );
    assert!(
        saw_turn_completed,
        "expected a turn/completed notification before timing out"
    );
    assert_eq!(
        claude_pool.len().await,
        1,
        "first turn must lazily start exactly one claude process"
    );

    // Drop the client end → bridge reader sees EOF → run_connection exits.
    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
}

#[tokio::test]
async fn thread_list_returns_empty_with_fresh_index() {
    let codex_home_dir = TempDir::new().expect("codex_home tempdir");
    let codex_home = codex_home_dir.path().to_path_buf();
    // Point CLAUDE_PROJECTS_DIR at an empty tempdir so the on-disk
    // hydration walk doesn't pull in the real `~/.claude/projects/`
    // sessions a developer machine has. Restored on test exit so other
    // tests in the same binary aren't affected (this test holds the
    // env mutation for its full lifetime).
    let claude_projects = TempDir::new().expect("claude_projects tempdir");
    let prev_claude_projects = std::env::var("CLAUDE_PROJECTS_DIR").ok();
    // Safety: tests in this file run serially via `--test-threads=1`
    // recommended for env-mutating cases. cargo also serializes within a
    // single binary by default for `#[tokio::test]` because each spawns
    // its own runtime; the failure mode if interleaved is a stale read,
    // which the per-test fresh tempdir guards against.
    unsafe {
        std::env::set_var("CLAUDE_PROJECTS_DIR", claude_projects.path());
    }
    let _restore = scopeguard_restore("CLAUDE_PROJECTS_DIR", prev_claude_projects);

    let claude_pool = Arc::new(ClaudePool::new(fake_claude_path()));
    let thread_index: Arc<dyn ThreadIndexHandle> = ThreadIndex::open_and_hydrate(&codex_home)
        .await
        .expect("open thread index");

    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);

    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            claude_pool,
            thread_index,
            codex_home,
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
            "method": "thread/list",
            "params": {}
        }),
    )
    .await
    .expect("write thread/list");

    let resp = await_response(&mut client_reader, 1).await;
    let result = resp.get("result").expect("thread/list result");
    let data = result
        .get("data")
        .and_then(|v| v.as_array())
        .expect("thread/list data array");
    assert!(
        data.is_empty(),
        "fresh index must list no threads, got {data:?}"
    );

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
}

/// End-to-end exercise of the resume-across-eviction path: do a turn,
/// force the pool to reap, then call thread/resume on the same id and
/// expect a fresh turn to complete normally.
#[tokio::test]
async fn turn_after_eviction_resumes_cleanly() {
    let cwd = TempDir::new().expect("cwd tempdir");

    // Isolate the on-disk session scan from the developer's real
    // ~/.claude/projects/ so hydration starts empty.
    let claude_projects = TempDir::new().expect("claude_projects tempdir");
    let prev_projects = std::env::var("CLAUDE_PROJECTS_DIR").ok();
    unsafe {
        std::env::set_var("CLAUDE_PROJECTS_DIR", claude_projects.path());
    }
    let _restore_projects = scopeguard_restore("CLAUDE_PROJECTS_DIR", prev_projects);

    // 100ms idle TTL so we can reap deterministically without sleeping
    // for the prod 10-minute default.
    let claude_pool = Arc::new(ClaudePool::with_limits(
        fake_claude_path(),
        4,
        Duration::from_millis(100),
    ));
    let codex_home_dir = TempDir::new().expect("codex_home tempdir");
    let codex_home = codex_home_dir.path().to_path_buf();
    let thread_index: Arc<dyn ThreadIndexHandle> = ThreadIndex::open_and_hydrate(&codex_home)
        .await
        .expect("open thread index");
    let thread_index_for_test = Arc::clone(&thread_index);

    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge_io);
    let pool_for_bridge = Arc::clone(&claude_pool);
    let bridge_task = tokio::spawn(async move {
        run_connection(
            bridge_reader,
            bridge_writer,
            pool_for_bridge,
            thread_index,
            codex_home,
        )
        .await
    });
    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);

    write_json_line(
        &mut client_writer,
        &json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"resume-smoke","version":"0.0.1"}}}),
    )
    .await
    .expect("init");
    let _ = await_response(&mut client_reader, 1).await;

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0","id":2,"method":"thread/start",
            "params":{"cwd": cwd.path().to_string_lossy()}
        }),
    )
    .await
    .expect("thread/start");
    let start = await_response(&mut client_reader, 2).await;
    let thread_id = start
        .get("result")
        .and_then(|r| r.get("thread"))
        .and_then(|t| t.get("id"))
        .and_then(|v| v.as_str())
        .expect("thread.id")
        .to_string();
    assert!(
        claude_pool.is_empty().await,
        "thread/start should only create the indexed thread"
    );

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0","id":3,"method":"turn/start",
            "params":{"sandboxPolicy":{"type":"dangerFullAccess"},"threadId":thread_id,"input":[{"type":"text","text":"first"}]}
        }),
    )
    .await
    .expect("turn/start #1");
    drain_until_completed(&mut client_reader, 3).await;
    assert_eq!(claude_pool.len().await, 1);

    // fake-claude does not persist JSONL itself. Create the empty transcript
    // that real Claude leaves behind so the next lazy spawn selects --resume.
    let entry = thread_index_for_test
        .lookup(&thread_id)
        .await
        .expect("thread should remain indexed");
    let transcript = &entry.metadata.claude_session_path;
    std::fs::create_dir_all(transcript.parent().expect("transcript parent"))
        .expect("create transcript parent");
    std::fs::write(transcript, b"").expect("create transcript");

    // Wait past the test TTL + explicit reap. mark_idle happens
    // automatically when the event pump sees the terminal `result`.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let reaped = claude_pool.reap_idle().await;
    assert!(
        reaped.contains(&thread_id),
        "reap_idle should have reaped {thread_id}, got {reaped:?}"
    );
    assert!(
        claude_pool.is_empty().await,
        "pool should be empty after reap"
    );

    // thread/resume hydrates metadata/history only. The next turn performs
    // the cold --resume spawn so merely opening an old session stays fast.
    let pre = Instant::now();
    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0","id":4,"method":"thread/resume",
            "params":{"threadId":thread_id}
        }),
    )
    .await
    .expect("thread/resume");
    let _ = await_response(&mut client_reader, 4).await;
    assert!(
        claude_pool.is_empty().await,
        "thread/resume must not eagerly respawn local claude"
    );

    write_json_line(
        &mut client_writer,
        &json!({
            "jsonrpc":"2.0","id":5,"method":"turn/start",
            "params":{"sandboxPolicy":{"type":"dangerFullAccess"},"threadId":thread_id,"input":[{"type":"text","text":"second"}]}
        }),
    )
    .await
    .expect("turn/start #2");
    drain_until_completed(&mut client_reader, 5).await;
    assert_eq!(claude_pool.len().await, 1);
    assert!(
        Instant::now().duration_since(pre) < STEP_TIMEOUT,
        "second turn should resume + complete within step timeout"
    );

    drop(client_writer);
    drop(client_reader);
    let _ = timeout(STEP_TIMEOUT, bridge_task).await;
}

async fn drain_until_completed<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    response_id: u64,
) {
    let mut saw_response = false;
    let mut saw_completed = false;
    let mut seen_methods: Vec<String> = Vec::new();
    for _ in 0..200 {
        let msg = next_msg(reader).await;
        if msg.get("id").and_then(|v| v.as_u64()) == Some(response_id) {
            saw_response = true;
        }
        if let Some(method) = msg.get("method").and_then(|v| v.as_str()) {
            seen_methods.push(method.to_string());
            if method == "turn/completed" {
                saw_completed = true;
            }
        }
        if saw_response && saw_completed {
            return;
        }
    }
    panic!(
        "timed out waiting for response id={response_id} + turn/completed; saw_response={saw_response} saw_completed={saw_completed}; seen_methods={seen_methods:?}"
    );
}

// === helpers ================================================================

/// Read the next JSON line from the bridge with a per-message timeout.
async fn next_msg<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> Value {
    let mut line = String::new();
    let n = timeout(STEP_TIMEOUT, reader.read_line(&mut line))
        .await
        .expect("bridge produced a message before timeout")
        .expect("bridge read");
    assert!(n > 0, "bridge closed reader half before sending a message");
    serde_json::from_str(line.trim()).unwrap_or_else(|err| {
        panic!("bridge frame was not valid JSON: {err}; raw=`{line}`");
    })
}

/// Drain bridge frames until the response with `id` arrives, swallowing
/// any notifications in between.
async fn await_response<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    expected_id: u64,
) -> Value {
    for _ in 0..200 {
        let msg = next_msg(reader).await;
        if msg.get("id").and_then(|v| v.as_u64()) == Some(expected_id) {
            return msg;
        }
    }
    panic!("never saw response for id={expected_id}");
}

/// Drop guard that restores an env var to its prior value when dropped.
struct EnvRestore {
    key: &'static str,
    prev: Option<String>,
}

impl Drop for EnvRestore {
    fn drop(&mut self) {
        unsafe {
            match self.prev.take() {
                Some(v) => std::env::set_var(self.key, v),
                None => std::env::remove_var(self.key),
            }
        }
    }
}

fn scopeguard_restore(key: &'static str, prev: Option<String>) -> EnvRestore {
    EnvRestore { key, prev }
}
