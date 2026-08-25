//! Test-only stand-in for `claude -p --output-format stream-json`.
//!
//! Used by translator + pool unit tests and the smoke matrix so we can
//! exercise the bridge end-to-end without depending on a real `claude`
//! install. Mirrors the surface real claude offers in stream-json mode:
//!
//! 1. On startup, parses `--session-id <uuid>`, `--add-dir <path>`, and
//!    `--resume <uuid>` from `argv` (`-p`, `--input-format`, etc. are
//!    ignored — we don't care about them at the fake layer).
//! 2. Immediately emits a `{"type":"system","subtype":"init",...}` line on
//!    stdout so the bridge's `wait_for_init()` unblocks.
//! 3. Reads JSON-line `user` envelopes from stdin (the bridge's `turn/start`
//!    serializes one of these per turn). For each inbound envelope, replays
//!    a scripted sequence of stream-json events + a terminal `result`
//!    envelope on stdout, then waits for the next user message.
//! 4. Exits cleanly when stdin EOFs.
//!
//! ## Side channels (env vars)
//!
//! - `FAKE_CLAUDE_SCRIPT`: path to a JSONL script the fake replays per
//!   turn. Each non-empty / non-`#` line is one stream-json event written
//!   verbatim to stdout. `{"type":"sleep","ms":N}` directives delay the
//!   next emission. Missing / empty file falls back to a minimal default
//!   script (text-only assistant message + `result success`).
//! - `FAKE_CLAUDE_TURN_LOG`: optional file path; the fake appends the
//!   inbound envelope's first text block (or `<no-text>`) per turn so
//!   tests can assert "the bridge sent X to claude" without parsing
//!   stdin themselves.
//! - `FAKE_CLAUDE_INIT_DELAY_MS`: optional delay before emitting the
//!   `system/init`. Defaults to 0. Used by tests that need to exercise
//!   `wait_for_init` slow paths.
//! - `FAKE_CLAUDE_EXIT_ON_CONTROL_ONCE`: optional marker path. The first fake
//!   generation atomically creates the marker and exits after receiving a
//!   control request but before replying. Later generations reply normally.
//! - `FAKE_CLAUDE_EXIT_ON_CONTROL_ALWAYS`: when non-empty, every generation
//!   exits after receiving a control request. This verifies that recovery
//!   changes transport instead of repeating the same failed request.
//! - A script line `{"type":"exit_once","marker":"/tmp/path"}` atomically
//!   creates `marker` and exits the first fake process that reaches it.
//!   Later processes skip the directive. This models one crashed Claude
//!   generation followed by a healthy cold resume.
//!
//! Stays intentionally minimal — extend on demand. Nothing here needs to
//! match claude's wire byte-for-byte; only the fields the bridge actually
//! deserializes (`SystemInit`, `StreamEventEnvelope`, `ResultEnvelope`,
//! plus their nested shapes).

use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use serde_json::{Value, json};

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let session_id = arg_value(&args, "--session-id").unwrap_or_else(|| "fake-session".to_string());
    let cwd = arg_value(&args, "--add-dir")
        .or_else(|| {
            std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string())
        })
        .unwrap_or_else(|| ".".to_string());
    let model = arg_value(&args, "--model").unwrap_or_else(|| "fake-claude-model".to_string());
    let resumed = arg_value(&args, "--resume").is_some();

    let stdout = io::stdout();
    let mut out = stdout.lock();

    if let Ok(ms) = env::var("FAKE_CLAUDE_INIT_DELAY_MS") {
        if let Ok(ms) = ms.parse::<u64>() {
            if ms > 0 {
                thread::sleep(Duration::from_millis(ms));
            }
        }
    }

    emit(
        &mut out,
        &json!({
            "type": "system",
            "subtype": "init",
            "session_id": session_id,
            "cwd": cwd,
            "model": model,
            "tools": ["Bash", "Edit", "Read"],
            "mcp_servers": [],
            "slash_commands": ["compact"],
            "agents": [],
            "skills": [],
            "permissionMode": "default",
            "apiKeySource": "env",
            "claude_code_version": "fake-1.0.0",
            "uuid": format!("init-{session_id}"),
            "_resumed": resumed,
        }),
    );

    let script = load_script();
    let mut turn_counter: u64 = 0;

    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    while let Some(Ok(line)) = lines.next() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let inbound: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(err) => {
                emit(
                    &mut out,
                    &json!({
                        "type": "result",
                        "subtype": "error_during_execution",
                        "is_error": true,
                        "session_id": session_id,
                        "uuid": format!("err-{turn_counter}"),
                        "result": format!("fake-claude parse error: {err}"),
                        "stop_reason": "error",
                    }),
                );
                continue;
            }
        };

        if inbound.get("type").and_then(Value::as_str) == Some("control_request") {
            if exit_on_control() {
                return ExitCode::from(24);
            }
            let request_id = inbound
                .get("request_id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            emit(
                &mut out,
                &json!({
                    "type": "control_response",
                    "response": {
                        "request_id": request_id,
                        "subtype": "success"
                    }
                }),
            );
            continue;
        }

        if let Ok(log_path) = env::var("FAKE_CLAUDE_TURN_LOG") {
            if !log_path.is_empty() {
                let user_text = first_user_text(&inbound).unwrap_or_else(|| "<no-text>".into());
                if let Ok(mut f) = fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                {
                    let _ = writeln!(f, "{user_text}");
                }
            }
        }

        turn_counter += 1;
        if run_script(&mut out, &script, &session_id, turn_counter) {
            return ExitCode::from(23);
        }
    }

    ExitCode::SUCCESS
}

fn emit<W: Write>(out: &mut W, v: &Value) {
    let _ = serde_json::to_writer(&mut *out, v);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

enum ScriptStep {
    Event(Value),
    Sleep(Duration),
    ExitOnce(std::path::PathBuf),
}

fn load_script() -> Vec<ScriptStep> {
    let path = match env::var("FAKE_CLAUDE_SCRIPT") {
        Ok(p) if !p.is_empty() => p,
        _ => return default_script(),
    };
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return default_script(),
    };
    let mut steps = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let value: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match value.get("type").and_then(Value::as_str) {
            Some("sleep") => {
                let ms = value.get("ms").and_then(Value::as_u64).unwrap_or(0);
                steps.push(ScriptStep::Sleep(Duration::from_millis(ms)));
            }
            Some("exit_once") => {
                if let Some(marker) = value.get("marker").and_then(Value::as_str) {
                    steps.push(ScriptStep::ExitOnce(marker.into()));
                }
            }
            _ => steps.push(ScriptStep::Event(value)),
        }
    }
    if steps.is_empty() {
        default_script()
    } else {
        steps
    }
}

/// Minimal default per-turn script: one text-only assistant content block
/// streamed as a single delta, then a `result success`. Shape is the bare
/// minimum the bridge translator needs to emit a `turn/completed`.
fn default_script() -> Vec<ScriptStep> {
    vec![
        ScriptStep::Event(json!({
            "type": "stream_event",
            "session_id": "__SESSION__",
            "uuid": "evt-message-start",
            "event": {
                "type": "message_start",
                "message": {
                    "id": "msg_fake_1",
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": "fake-claude-model",
                    "stop_reason": null,
                    "stop_sequence": null,
                    "usage": {"input_tokens": 1, "output_tokens": 0}
                }
            }
        })),
        ScriptStep::Event(json!({
            "type": "stream_event",
            "session_id": "__SESSION__",
            "uuid": "evt-cb-start",
            "event": {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""}
            }
        })),
        ScriptStep::Event(json!({
            "type": "stream_event",
            "session_id": "__SESSION__",
            "uuid": "evt-cb-delta",
            "event": {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "hi"}
            }
        })),
        ScriptStep::Event(json!({
            "type": "stream_event",
            "session_id": "__SESSION__",
            "uuid": "evt-cb-stop",
            "event": {"type": "content_block_stop", "index": 0}
        })),
        ScriptStep::Event(json!({
            "type": "stream_event",
            "session_id": "__SESSION__",
            "uuid": "evt-msg-stop",
            "event": {"type": "message_stop"}
        })),
        ScriptStep::Event(json!({
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "session_id": "__SESSION__",
            "uuid": "evt-result",
            "duration_ms": 5,
            "duration_api_ms": 5,
            "num_turns": 1,
            "result": "hi",
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 1, "output_tokens": 1},
            "permission_denials": []
        })),
    ]
}

/// Returns true when the fake should terminate immediately.
fn run_script<W: Write>(out: &mut W, steps: &[ScriptStep], session_id: &str, turn: u64) -> bool {
    for step in steps {
        match step {
            ScriptStep::Event(template) => {
                let mut event = template.clone();
                substitute_session(&mut event, session_id);
                stamp_turn_on_uuid(&mut event, turn);
                emit(out, &event);
            }
            ScriptStep::Sleep(d) => thread::sleep(*d),
            ScriptStep::ExitOnce(marker) => {
                if create_marker_once(marker) {
                    return true;
                }
            }
        }
    }
    false
}

fn exit_on_control() -> bool {
    if env::var_os("FAKE_CLAUDE_EXIT_ON_CONTROL_ALWAYS")
        .filter(|value| !value.is_empty())
        .is_some()
    {
        return true;
    }
    env::var_os("FAKE_CLAUDE_EXIT_ON_CONTROL_ONCE")
        .filter(|path| !path.is_empty())
        .is_some_and(|path| create_marker_once(std::path::Path::new(&path)))
}

fn create_marker_once(path: &std::path::Path) -> bool {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .is_ok()
}

fn substitute_session(value: &mut Value, session_id: &str) {
    match value {
        Value::String(s) if s == "__SESSION__" => *s = session_id.to_string(),
        Value::Array(arr) => arr
            .iter_mut()
            .for_each(|v| substitute_session(v, session_id)),
        Value::Object(obj) => obj
            .values_mut()
            .for_each(|v| substitute_session(v, session_id)),
        _ => {}
    }
}

fn stamp_turn_on_uuid(value: &mut Value, turn: u64) {
    if let Some(obj) = value.as_object_mut() {
        if let Some(Value::String(uuid)) = obj.get_mut("uuid") {
            uuid.push_str(&format!("-t{turn}"));
        }
    }
}

fn first_user_text(envelope: &Value) -> Option<String> {
    let content = envelope.get("message")?.get("content")?;
    if let Some(text) = content.as_str() {
        return Some(text.to_string());
    }
    content
        .as_array()?
        .iter()
        .find_map(|block| block.get("text").and_then(|t| t.as_str()))
        .map(|s| s.to_string())
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    let pos = args.iter().position(|a| a == flag)?;
    args.get(pos + 1).cloned()
}
