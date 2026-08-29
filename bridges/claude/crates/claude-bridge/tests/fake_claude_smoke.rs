//! Self-test for the `fake-claude` test harness binary.
//!
//! Confirms the fake satisfies claude's stream-json wire contract well
//! enough for `ClaudeProcessHandle` to drive it. Failures here mean the
//! fake drifted from the bridge's expected protocol shape, not that the
//! bridge is broken.

mod support;

use std::time::Duration;

use alleycat_claude_bridge::pool::claude_protocol::{ClaudeOutbound, SystemEvent};
use alleycat_claude_bridge::pool::process::{ClaudeProcessHandle, ClaudeSpawnConfig};
use serde_json::json;
use tempfile::TempDir;
use tokio::time::timeout;

use support::{fake_claude_path, write_script};

#[tokio::test]
async fn fake_claude_emits_system_init_then_replies_to_user_envelope() {
    let cwd = TempDir::new().unwrap();
    let script_dir = TempDir::new().unwrap();
    let script_path = write_script(
        script_dir.path(),
        &[
            json!({
                "type": "stream_event",
                "session_id": "__SESSION__",
                "uuid": "evt-cb-start",
                "event": {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""}
                }
            }),
            json!({
                "type": "stream_event",
                "session_id": "__SESSION__",
                "uuid": "evt-cb-delta",
                "event": {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": "ok"}
                }
            }),
            json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "session_id": "__SESSION__",
                "uuid": "evt-result",
                "stop_reason": "end_turn",
                "permission_denials": []
            }),
        ],
    );

    // Safety: this test is the only one in the file, so cargo's per-binary
    // serialization keeps the env mutation race-free.
    unsafe {
        std::env::set_var("FAKE_CLAUDE_SCRIPT", &script_path);
    }
    let handle = ClaudeProcessHandle::spawn(ClaudeSpawnConfig {
        thread_id: "01976d40-f1f8-7a4f-b8d7-fakeclaude".to_string(),
        cwd: cwd.path().to_path_buf(),
        claude_bin: fake_claude_path(),
        model: None,
        effort_level: None,
        permission_mode: None,
        append_system_prompt: None,
        resume: false,
        bypass_permissions: true,
    })
    .await
    .expect("spawn fake-claude");
    unsafe {
        std::env::remove_var("FAKE_CLAUDE_SCRIPT");
    }

    // wait_for_init must unblock once the fake's `system/init` line lands.
    let init = handle
        .wait_for_init(Duration::from_secs(3))
        .await
        .expect("wait_for_init");
    assert_eq!(init.session_id, "01976d40-f1f8-7a4f-b8d7-fakeclaude");
    assert!(!init.cwd.is_empty(), "init must carry a cwd");

    let mut events = handle.subscribe_events();

    // Send a user envelope. The fake replays the script + result.
    handle
        .send_serialized(&json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": "hello"}]
            }
        }))
        .expect("send user envelope");

    // Drain until we see the terminal Result. Bound by per-event timeout
    // so a regression in the fake shows up as a timeout, not a hang.
    let mut saw_init = false;
    let mut saw_text_delta = false;
    let mut saw_result = false;
    for _ in 0..40 {
        let evt = timeout(Duration::from_secs(2), events.recv())
            .await
            .expect("event before timeout")
            .expect("broadcast not closed");
        match evt.payload {
            ClaudeOutbound::System(SystemEvent::Init(_)) => saw_init = true,
            ClaudeOutbound::StreamEvent(_) => saw_text_delta = true,
            ClaudeOutbound::Result(_) => {
                saw_result = true;
                break;
            }
            _ => {}
        }
    }
    // `wait_for_init` consumed the init slot, but the broadcast also
    // surfaces it for any subscriber that joined afterward — depending on
    // ordering, `events` may or may not see the original; that's fine,
    // we don't assert `saw_init`.
    let _ = saw_init;
    assert!(saw_text_delta, "should see at least one stream_event");
    assert!(saw_result, "should see a terminal `result`");

    handle.shutdown().await;
}
