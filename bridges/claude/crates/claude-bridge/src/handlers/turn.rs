//! `turn/*` and `review/*` request handlers + the per-thread event driver.
//!
//! Flow on `turn/start`:
//! 1. Look up the claude process for `thread_id`; a locally-created empty
//!    thread starts its process lazily on the first valid user input.
//! 2. Ensure the process has one event driver that outlives WebSocket
//!    connections and individual turns.
//! 3. Mint a fresh codex `turn_id`, hand it to the driver, and mark the pool
//!    entry active so the LRU reaper leaves it alone.
//! 4. Translate `UserInput[]` → claude stream-json user envelope and write
//!    it to stdin.
//! 5. The driver runs every event through [`EventTranslatorState::translate`],
//!    persists completed items, and emits `turn/completed` on `result`.
//!    Output that arrives without a client turn is wrapped in a synthetic turn.
//!
//! `turn/steer` writes another user envelope on stdin while a turn is in
//! flight; the existing driver folds the new events into the same `turn_id`.
//!
//! `turn/interrupt` sends SIGINT to the claude child (Unix) or
//! `child.start_kill()` (Windows) and waits for the driver to emit a Failed
//! `turn/completed`.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::Mutex as SyncMutex;
use std::sync::Weak;
use std::time::{Duration, SystemTime};

use thiserror::Error;
use tokio::sync::Mutex as AsyncMutex;
use tokio::sync::broadcast;
use tokio::sync::{mpsc, oneshot, watch};
use uuid::Uuid;

use alleycat_bridge_core::session::TurnGuard;
use alleycat_codex_proto as p;

use crate::approval;
use crate::handlers::model::{normalize_claude_model, normalize_claude_model_id};
use crate::handlers::thread::{cached_thread_turns, resume_cwd_or_fallback};
use crate::pool::ClaudeProcessHandle;
use crate::pool::claude_protocol::{ClaudeEvent, ClaudeOutbound, ControlRequestBody};
use crate::pool::process::ClaudeProcessError;
use crate::state::ConnectionState;
use crate::translate::events::{
    EventTranslatorState, is_claude_authentication_failure, turn_status_from_result,
};
use crate::translate::input::translate_user_input;

/// Time the bridge gives claude to acknowledge a `control_request{interrupt}`.
/// Empirically the SDK uses no timeout (it `await`s indefinitely), but we cap
/// at 5s so a stuck claude doesn't pin the connection. After timeout we fall
/// back to SIGINT/shutdown so the codex client gets `turn/completed{Failed}`.
const CONTROL_INTERRUPT_TIMEOUT: Duration = Duration::from_secs(5);

/// Time the bridge gives claude to acknowledge a runtime config setter
/// (`set_model`, `apply_flag_settings`, `set_permission_mode`). Setters
/// are usually fast (~tens of ms) — keep this tight so a wedged claude
/// surfaces as an error rather than hanging the turn handler.
const CONTROL_SET_TIMEOUT: Duration = Duration::from_secs(5);

/// 映射到 Claude Code 原生 effort。新版客户端只会发送最高四档；
/// 旧客户端残留的 none/minimal/low 统一提升到 medium，保证升级 bridge 后
/// 不会继续使用已经从产品里移除的低档。
fn native_effort_level(effort: p::ReasoningEffort) -> &'static str {
    match effort {
        p::ReasoningEffort::None
        | p::ReasoningEffort::Minimal
        | p::ReasoningEffort::Low
        | p::ReasoningEffort::Medium => "medium",
        p::ReasoningEffort::High => "high",
        p::ReasoningEffort::XHigh => "xhigh",
        p::ReasoningEffort::Max => "max",
    }
}

/// 将每个 turn 的协作/权限参数映射为 Claude Code 的运行时权限模式。
/// collaborationMode 明确为 plan 时只影响本 turn；下一次 default 会重新计算，
/// 不读取进程上一次的 sticky 状态。只读沙箱仍然必须落到 plan。
fn claude_permission_mode(params: &p::TurnStartParams) -> &'static str {
    if params
        .collaboration_mode
        .as_ref()
        .and_then(collaboration_mode_name)
        == Some("plan")
    {
        return "plan";
    }
    if params.sandbox_policy.as_ref().is_some_and(is_read_only) {
        return "plan";
    }
    // 新版客户端用 on-request + auto_review 表示自动审批；旧的 on-failure
    // 已从 Codex 协议移除，不能再作为 Claude 自动权限模式的触发条件。
    if matches!(params.approval_policy, Some(p::AskForApproval::OnRequest))
        && matches!(
            params.approvals_reviewer,
            Some(p::ApprovalsReviewer::AutoReview)
        )
    {
        return "auto";
    }
    "default"
}

fn collaboration_mode_name(value: &serde_json::Value) -> Option<&str> {
    match value {
        serde_json::Value::String(mode) => Some(mode.as_str()),
        serde_json::Value::Object(map) => map.get("mode").and_then(serde_json::Value::as_str),
        _ => None,
    }
}

fn is_read_only(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::String(mode) => matches!(mode.as_str(), "read-only" | "readOnly"),
        serde_json::Value::Object(map) => map
            .get("type")
            .or_else(|| map.get("mode"))
            .is_some_and(is_read_only),
        _ => false,
    }
}

/// Per-thread active-turn registry. Claude only allows one active turn per
/// process. Keyed by codex `thread_id`.
static ACTIVE_TURNS: LazyLock<SyncMutex<HashMap<String, ActiveTurn>>> =
    LazyLock::new(|| SyncMutex::new(HashMap::new()));

/// 每个 Claude 子进程只能有一个 stdout 消费者。事件驱动器按 thread 常驻，
/// 不随页面、WebSocket 或单个 turn 的结束而销毁。
static EVENT_DRIVERS: LazyLock<SyncMutex<HashMap<String, EventDriverRegistration>>> =
    LazyLock::new(|| SyncMutex::new(HashMap::new()));

#[derive(Clone)]
struct ActiveTurn {
    turn_id: String,
}

struct EventDriverRegistration {
    generation: String,
    process: Weak<ClaudeProcessHandle>,
    commands: mpsc::UnboundedSender<EventDriverCommand>,
}

enum EventDriverCommand {
    BeginTurn {
        state: Arc<ConnectionState>,
        turn_id: String,
        started_at: i64,
        turn_guard: TurnGuard,
        ready: oneshot::Sender<Result<(), BeginDriverTurnError>>,
    },
    AbortTurn {
        turn_id: String,
    },
}

#[derive(Debug)]
enum BeginDriverTurnError {
    AlreadyActive(String),
    Unavailable(String),
}

#[derive(Debug, Error)]
pub enum TurnError {
    #[error("invalid params: {0}")]
    InvalidParams(String),
    #[error("thread `{0}` is not loaded; call thread/start or thread/resume first")]
    ThreadNotLoaded(String),
    #[error("expected_turn_id `{expected}` does not match active turn `{actual}`")]
    TurnIdMismatch { expected: String, actual: String },
    #[error("no active turn for thread `{0}`")]
    NoActiveTurn(String),
    #[error("input translation failed: {0}")]
    InputTranslation(String),
    #[error("model `{model}` was rejected before turn creation: {message}")]
    ModelRejected { model: String, message: String },
    #[error("thread `{thread_id}` already has active turn `{active_turn_id}`")]
    AlreadyActive {
        thread_id: String,
        active_turn_id: String,
    },
    #[error("claude rpc error: {0}")]
    ClaudeRpc(String),
    #[error("review/start is not implemented in claude-bridge v1")]
    ReviewUnsupported,
}

impl TurnError {
    pub fn rpc_code(&self) -> i64 {
        match self {
            TurnError::InvalidParams(_)
            | TurnError::TurnIdMismatch { .. }
            | TurnError::ThreadNotLoaded(_)
            | TurnError::NoActiveTurn(_)
            | TurnError::InputTranslation(_)
            | TurnError::ModelRejected { .. }
            | TurnError::AlreadyActive { .. } => p::error_codes::INVALID_PARAMS,
            TurnError::ReviewUnsupported => p::error_codes::METHOD_NOT_FOUND,
            TurnError::ClaudeRpc(_) => p::error_codes::INTERNAL_ERROR,
        }
    }

    pub fn rpc_data(&self) -> Option<serde_json::Value> {
        match self {
            TurnError::ModelRejected { model, message } => Some(serde_json::json!({
                "accepted": false,
                "field": "model",
                "model": model,
                "phase": "runtime_overrides",
                "reason": message,
                "retryable": false,
            })),
            TurnError::AlreadyActive {
                thread_id,
                active_turn_id,
            } => Some(serde_json::json!({
                "accepted": false,
                "reason": "active_turn",
                "threadId": thread_id,
                "activeTurnId": active_turn_id,
                "retryable": false,
            })),
            _ => None,
        }
    }
}

// ============================================================================
// turn/start
// ============================================================================

pub async fn handle_turn_start(
    state: &Arc<ConnectionState>,
    params: p::TurnStartParams,
) -> Result<p::TurnStartResponse, TurnError> {
    let envelope = translate_user_input(&params.input)
        .map_err(|e| TurnError::InputTranslation(e.to_string()))?;

    let mut handle = acquire_turn_process(state, &params).await?;

    // 必须在 runtime overrides 之前拒绝重复 turn/start。否则一次陈旧的客户端
    // 发送会先改掉正在执行轮次的模型/权限，再以内部错误退出。
    if let Some(active) = active_turn(&params.thread_id) {
        return Err(TurnError::AlreadyActive {
            thread_id: params.thread_id.clone(),
            active_turn_id: active.turn_id,
        });
    }

    // App 可以绕过显式 thread/resume 直接开始 turn。此时也要先把 JSONL
    // 历史播种进共享内存日志，保证后续 thread/read 返回完整会话而非仅本轮。
    if state.thread_log(&params.thread_id).is_empty()
        && let Some(entry) = state.thread_index().lookup(&params.thread_id).await
    {
        let _ = cached_thread_turns(state, &entry).await;
    }

    // Apply per-turn runtime overrides via in-band control_requests BEFORE
    // writing the user envelope. The handle diffs against its cached state so
    // a turn that doesn't change the model/effort is a no-op (zero RTT).
    let normalized_model_override = params.model.as_deref().map(normalize_claude_model_id);
    let model_override = normalized_model_override.as_deref();
    let effort_override = params.effort.map(native_effort_level);
    let permission_mode = claude_permission_mode(&params);
    // Start lifecycle observation before the first control write. A process
    // can lose stdin during runtime overrides, before a turn exists.
    let mut driver = ensure_event_driver(state, &params.thread_id, &handle);
    let mut recovery_attempted = false;
    loop {
        let result = handle
            .apply_runtime_overrides(
                model_override,
                effort_override,
                Some(permission_mode),
                CONTROL_SET_TIMEOUT,
            )
            .await;
        let Err(err) = result else {
            break;
        };

        if err.is_process_transport_failure() {
            let will_retry = !recovery_attempted;
            let generation = handle.generation().to_string();
            let pid = handle.pid();
            let failure_kind = err.failure_kind();
            let runtime_field = err.runtime_field().unwrap_or("unknown");
            let terminal = handle.has_exited();
            let released = state
                .claude_pool()
                .release_if_same(&params.thread_id, &handle)
                .await;
            tracing::warn!(
                thread_id = %params.thread_id,
                %generation,
                ?pid,
                failure_kind,
                runtime_field,
                terminal,
                released,
                will_retry,
                error = %err,
                "claude runtime override transport failure"
            );

            if will_retry {
                recovery_attempted = true;
                handle = acquire_turn_process(state, &params).await?;
                driver = ensure_event_driver(state, &params.thread_id, &handle);
                continue;
            }
        }

        if let Some((model, message)) = explicit_model_rejection(&err) {
            tracing::warn!(
                thread_id = %params.thread_id,
                model = %model,
                reason = %message,
                accepted = false,
                "claude rejected model before turn creation"
            );
            return Err(TurnError::ModelRejected { model, message });
        }
        return Err(TurnError::ClaudeRpc(format!(
            "applying runtime overrides: {err}"
        )));
    }

    let turn_id = Uuid::now_v7().to_string();
    state.claude_pool().mark_active(&params.thread_id).await;

    let started_at = now_unix_secs();
    let turn_guard = state.session().begin_turn();
    if let Err(error) =
        begin_driver_turn(&driver, Arc::clone(state), &turn_id, started_at, turn_guard).await
    {
        return match error {
            BeginDriverTurnError::AlreadyActive(active_turn_id) => {
                // 竞态中的失败属于现有轮次，不能把进程池错误标成 idle。
                Err(TurnError::AlreadyActive {
                    thread_id: params.thread_id.clone(),
                    active_turn_id,
                })
            }
            BeginDriverTurnError::Unavailable(message) => {
                state.claude_pool().mark_idle(&params.thread_id).await;
                Err(TurnError::ClaudeRpc(message))
            }
        };
    }

    // Codex emits `startedAt: null` on the turn/start response but
    // populates it on the turn/started notification.
    let turn_for_notif = p::Turn {
        id: turn_id.clone(),
        items: Vec::new(),
        items_view: p::default_items_view(),
        status: p::TurnStatus::InProgress,
        error: None,
        started_at: Some(started_at),
        completed_at: None,
        duration_ms: None,
    };
    let mut turn = turn_for_notif.clone();
    turn.started_at = None;

    // 先落 live cache，再发布通知。客户端收到通知后可能立刻 thread/read；
    // 记录顺序反过来会让这次读取短暂看不到刚开始的 turn。
    state.record_turn_started(&params.thread_id, turn_id.clone(), started_at);
    if state.should_emit("turn/started") {
        let frame = notification_frame(p::ServerNotification::TurnStarted(
            p::TurnStartedNotification {
                thread_id: params.thread_id.clone(),
                turn: turn_for_notif,
            },
        ));
        let _ = state.send(frame);
    }

    // Echo the user input back as a userMessage item lifecycle (codex
    // does this; see codex-rs app-server-protocol/src/protocol/v2.rs:5330).
    // Clients reconstruct history from these events.
    let user_message_item = p::ThreadItem::UserMessage {
        id: Uuid::now_v7().to_string(),
        content: params.input.clone(),
        client_id: params.client_user_message_id.clone(),
    };
    state.record_item(&params.thread_id, &turn_id, user_message_item.clone());
    if state.should_emit("item/started") {
        let frame = notification_frame(p::ServerNotification::ItemStarted(
            p::ItemStartedNotification {
                item: user_message_item.clone(),
                thread_id: params.thread_id.clone(),
                turn_id: turn_id.clone(),
                parent_item_id: None,
            },
        ));
        let _ = state.send(frame);
    }
    if state.should_emit("item/completed") {
        let frame = notification_frame(p::ServerNotification::ItemCompleted(
            p::ItemCompletedNotification {
                item: user_message_item.clone(),
                thread_id: params.thread_id.clone(),
                turn_id: turn_id.clone(),
                parent_item_id: None,
            },
        ));
        let _ = state.send(frame);
    }

    if let Err(e) = handle.send_serialized(&envelope) {
        let _ = driver.send(EventDriverCommand::AbortTurn {
            turn_id: turn_id.clone(),
        });
        clear_active_turn(&params.thread_id);
        state.claude_pool().mark_idle(&params.thread_id).await;
        return Err(TurnError::ClaudeRpc(e.to_string()));
    }

    // 标题回填只是列表体验，不能阻塞 turn/start ACK。Claude 已经收到输入后可能
    // 立即产出甚至完成；若这里等待索引落盘，通知就会先于 ACK 很久到达，客户端
    // 在 actor 重入窗口里容易被迟到 ACK 重新写回旧 active turn。
    spawn_preview_backfill(state, &params.thread_id, &params.input);

    Ok(p::TurnStartResponse { turn })
}

async fn acquire_turn_process(
    state: &Arc<ConnectionState>,
    params: &p::TurnStartParams,
) -> Result<Arc<ClaudeProcessHandle>, TurnError> {
    if let Some(handle) = state.claude_pool().get(&params.thread_id).await {
        return Ok(handle);
    }

    let entry = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| TurnError::ThreadNotLoaded(params.thread_id.clone()))?;
    let cwd = resume_cwd_or_fallback(&entry.cwd, &params.thread_id, state.trust_persisted_cwd());
    let defaults = state.defaults();
    let model = normalize_claude_model(params.model.clone().or_else(|| defaults.model.clone()));
    // 本地可直接以 transcript 是否存在区分新线程和恢复线程。远程线程仍会在
    // thread/start/resume 预启动；这里的 preview 判断只负责进程意外退出后的兜底。
    let resume = if state.trust_persisted_cwd() {
        !entry.preview.trim().is_empty() || !state.thread_log(&params.thread_id).is_empty()
    } else {
        entry.metadata.claude_session_path.is_file()
    };
    state
        .claude_pool()
        .acquire_for_thread(
            params.thread_id.clone(),
            &cwd,
            resume,
            model,
            defaults.system_prompt.clone(),
        )
        .await
        .map_err(|err| TurnError::ClaudeRpc(format!("starting claude process: {err:#}")))
}

fn explicit_model_rejection(err: &ClaudeProcessError) -> Option<(String, String)> {
    match err {
        ClaudeProcessError::RuntimeOverride {
            field: "model",
            value,
            source,
        } => match source.as_ref() {
            ClaudeProcessError::ControlError { message, .. }
                if is_explicit_invalid_model_message(message) =>
            {
                Some((value.clone(), message.clone()))
            }
            _ => None,
        },
        _ => None,
    }
}

fn is_explicit_invalid_model_message(message: &str) -> bool {
    let normalized = message.to_ascii_lowercase();
    [
        "not a recognized model",
        "unrecognized model",
        "invalid model",
        "unknown model",
        "no such model",
        "model not found",
        "no rollout found",
    ]
    .iter()
    .any(|marker| normalized.contains(marker))
}

/// Schedule preview persistence outside the `turn/start` response path.
fn spawn_preview_backfill(state: &Arc<ConnectionState>, thread_id: &str, input: &[p::UserInput]) {
    let Some(preview) = preview_from_input(input) else {
        return;
    };
    let state = Arc::clone(state);
    let thread_id = thread_id.to_string();
    tokio::spawn(async move {
        maybe_backfill_preview(&state, &thread_id, preview).await;
    });
}

/// If the thread's preview is still empty, backfill it from the first line of
/// the user's message. Any lookup/persist failure is ignored since a missing
/// preview only degrades the title, never the turn.
async fn maybe_backfill_preview(state: &Arc<ConnectionState>, thread_id: &str, preview: String) {
    let Some(entry) = state.thread_index().lookup(thread_id).await else {
        return;
    };
    if !entry.preview.trim().is_empty() {
        return;
    }
    let _ = state
        .thread_index()
        .update_preview_and_updated_at(thread_id, preview, chrono::Utc::now())
        .await;
}

/// Derive a one-line preview from the user input, matching the on-disk
/// hydrator: the first non-empty line of the concatenated text chunks.
fn preview_from_input(input: &[p::UserInput]) -> Option<String> {
    let mut text = String::new();
    for item in input {
        match item {
            p::UserInput::Text { text: t, .. } => text.push_str(t),
            p::UserInput::Skill { name, .. } => text.push_str(&format!("/{name}")),
            p::UserInput::Mention { name, .. } => {
                text.push('@');
                text.push_str(name);
            }
            _ => {}
        }
    }
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_string)
}

// ============================================================================
// turn/steer
// ============================================================================

pub async fn handle_turn_steer(
    state: &Arc<ConnectionState>,
    params: p::TurnSteerParams,
) -> Result<p::TurnSteerResponse, TurnError> {
    let handle = state
        .claude_pool()
        .get(&params.thread_id)
        .await
        .ok_or_else(|| TurnError::ThreadNotLoaded(params.thread_id.clone()))?;

    let active = active_turn(&params.thread_id)
        .ok_or_else(|| TurnError::NoActiveTurn(params.thread_id.clone()))?;
    if active.turn_id != params.expected_turn_id {
        return Err(TurnError::TurnIdMismatch {
            expected: params.expected_turn_id,
            actual: active.turn_id,
        });
    }

    let envelope = translate_user_input(&params.input)
        .map_err(|e| TurnError::InputTranslation(e.to_string()))?;
    handle
        .send_serialized(&envelope)
        .map_err(|e| TurnError::ClaudeRpc(e.to_string()))?;
    Ok(p::TurnSteerResponse {
        turn_id: active.turn_id,
    })
}

// ============================================================================
// turn/interrupt
// ============================================================================

pub async fn handle_turn_interrupt(
    state: &Arc<ConnectionState>,
    params: p::TurnInterruptParams,
) -> Result<p::TurnInterruptResponse, TurnError> {
    let handle = state
        .claude_pool()
        .get(&params.thread_id)
        .await
        .ok_or_else(|| TurnError::ThreadNotLoaded(params.thread_id.clone()))?;
    if let Some(active) = active_turn(&params.thread_id) {
        if active.turn_id != params.turn_id {
            return Err(TurnError::TurnIdMismatch {
                expected: params.turn_id,
                actual: active.turn_id,
            });
        }
    }
    interrupt_handle(&handle).await;
    Ok(p::TurnInterruptResponse::default())
}

/// Aborts the in-flight turn the SDK way: `control_request{subtype:"interrupt"}`
/// over stdin, awaits the matching success response. On any failure (timeout,
/// claude reports error, transport down) falls back to a hard process kill so
/// the codex client still sees `turn/completed{Failed}`. Cross-platform —
/// works on Unix and Windows without the `nix` SIGINT path.
async fn interrupt_handle(handle: &Arc<ClaudeProcessHandle>) {
    match handle
        .request_control(ControlRequestBody::Interrupt, CONTROL_INTERRUPT_TIMEOUT)
        .await
    {
        Ok(_) => tracing::debug!(thread_id = %handle.thread_id(), "interrupt acked"),
        Err(ClaudeProcessError::ControlError { message, .. }) => {
            tracing::warn!(
                thread_id = %handle.thread_id(),
                %message,
                "claude rejected interrupt control_request; killing process",
            );
            handle.shutdown().await;
        }
        Err(err) => {
            tracing::warn!(
                thread_id = %handle.thread_id(),
                ?err,
                "interrupt control_request failed; killing process",
            );
            handle.shutdown().await;
        }
    }
}

// ============================================================================
// review/start
// ============================================================================

pub async fn handle_review_start(
    _state: &Arc<ConnectionState>,
    _params: p::ReviewStartParams,
) -> Result<p::ReviewStartResponse, TurnError> {
    Err(TurnError::ReviewUnsupported)
}

// ============================================================================
// helpers + event pump
// ============================================================================

fn now_unix_secs() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn register_active_turn(thread_id: &str, turn_id: &str) {
    ACTIVE_TURNS.lock().unwrap().insert(
        thread_id.to_string(),
        ActiveTurn {
            turn_id: turn_id.to_string(),
        },
    );
}

fn active_turn(thread_id: &str) -> Option<ActiveTurn> {
    ACTIVE_TURNS.lock().unwrap().get(thread_id).cloned()
}

pub(super) fn active_turn_id(thread_id: &str) -> Option<String> {
    active_turn(thread_id).map(|turn| turn.turn_id)
}

fn clear_active_turn(thread_id: &str) {
    ACTIVE_TURNS.lock().unwrap().remove(thread_id);
}

fn clear_active_turn_if(thread_id: &str, turn_id: &str) {
    let mut turns = ACTIVE_TURNS.lock().unwrap();
    if turns
        .get(thread_id)
        .is_some_and(|active| active.turn_id == turn_id)
    {
        turns.remove(thread_id);
    }
}

fn notification_frame(notif: p::ServerNotification) -> p::JsonRpcMessage {
    let value = serde_json::to_value(&notif).expect("ServerNotification serializes");
    let method = value
        .get("method")
        .and_then(|m| m.as_str())
        .unwrap_or_default()
        .to_string();
    let params = value.get("params").cloned();
    p::JsonRpcMessage::Notification(p::JsonRpcNotification {
        jsonrpc: p::JsonRpcVersion,
        method,
        params,
    })
}

struct EventDriverArgs {
    state: Arc<ConnectionState>,
    thread_id: String,
    /// 进程池是 Claude 子进程唯一的生命周期所有者。driver 只保留弱引用，
    /// 这样空闲回收/显式关闭进程后 broadcast sender 能真正释放，driver
    /// 随之收到 Closed 并退出，不会为每个历史 thread 残留一个任务。
    handle: Weak<ClaudeProcessHandle>,
    events_rx: broadcast::Receiver<ClaudeEvent>,
    exit_rx: watch::Receiver<bool>,
    commands_rx: mpsc::UnboundedReceiver<EventDriverCommand>,
    generation: String,
}

struct DrivenTurn {
    turn_id: String,
    started_at: i64,
    translator: EventTranslatorState,
    error_message: Option<String>,
    interaction_gate: Arc<AsyncMutex<()>>,
    /// Claude control request id → mobile interaction task. A typed
    /// `control_cancel_request` can abort only the waiter it invalidates.
    interaction_tasks: HashMap<String, tokio::task::JoinHandle<()>>,
    turn_guard: TurnGuard,
    autonomous: bool,
}

impl DrivenTurn {
    fn new(
        thread_id: &str,
        turn_id: String,
        started_at: i64,
        turn_guard: TurnGuard,
        autonomous: bool,
    ) -> Self {
        Self {
            translator: EventTranslatorState::new(thread_id.to_string(), turn_id.clone()),
            turn_id,
            started_at,
            error_message: None,
            interaction_gate: Arc::new(AsyncMutex::new(())),
            interaction_tasks: HashMap::new(),
            turn_guard,
            autonomous,
        }
    }
}

#[derive(Default)]
struct BackgroundWork {
    seen_tool_uses: HashSet<String>,
    pending_wakeups: usize,
    persistent_crons: usize,
    session_guard: Option<TurnGuard>,
}

impl BackgroundWork {
    fn observe(&mut self, payload: &ClaudeOutbound) {
        for (id, name) in background_tool_uses(payload) {
            if !self.seen_tool_uses.insert(id) {
                continue;
            }
            match name.as_str() {
                // ScheduleWakeup 是一次性唤醒；下一段自主输出开始时消费一个。
                "ScheduleWakeup" => self.pending_wakeups += 1,
                // CronCreate 可能是重复任务，只有显式 CronDelete 才释放常驻。
                "CronCreate" => self.persistent_crons += 1,
                "CronDelete" => {
                    self.persistent_crons = self.persistent_crons.saturating_sub(1);
                }
                _ => {}
            }
        }
    }

    fn consume_autonomous_wakeup(&mut self) {
        self.pending_wakeups = self.pending_wakeups.saturating_sub(1);
    }

    fn has_pending(&self) -> bool {
        self.pending_wakeups > 0 || self.persistent_crons > 0
    }
}

fn background_tool_uses(payload: &ClaudeOutbound) -> Vec<(String, String)> {
    use crate::pool::claude_protocol::{ContentBlock, RawAnthropicEvent};

    match payload {
        ClaudeOutbound::Assistant(env) => env
            .message
            .get("content")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|block| {
                if block.get("type").and_then(serde_json::Value::as_str) != Some("tool_use") {
                    return None;
                }
                Some((
                    block
                        .get("id")
                        .and_then(serde_json::Value::as_str)?
                        .to_string(),
                    block
                        .get("name")
                        .and_then(serde_json::Value::as_str)?
                        .to_string(),
                ))
            })
            .collect(),
        ClaudeOutbound::StreamEvent(env) => match &env.event {
            RawAnthropicEvent::ContentBlockStart {
                content_block: ContentBlock::ToolUse { id, name, .. },
                ..
            } => vec![(id.clone(), name.clone())],
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

fn ensure_event_driver(
    state: &Arc<ConnectionState>,
    thread_id: &str,
    handle: &Arc<ClaudeProcessHandle>,
) -> mpsc::UnboundedSender<EventDriverCommand> {
    let mut drivers = EVENT_DRIVERS.lock().unwrap();
    if let Some(existing) = drivers.get(thread_id)
        && !existing.commands.is_closed()
        && existing
            .process
            .upgrade()
            .is_some_and(|process| Arc::ptr_eq(&process, handle))
    {
        return existing.commands.clone();
    }

    let generation = Uuid::now_v7().to_string();
    let (commands_tx, commands_rx) = mpsc::unbounded_channel();
    let args = EventDriverArgs {
        state: Arc::clone(state),
        thread_id: thread_id.to_string(),
        handle: Arc::downgrade(handle),
        events_rx: handle.subscribe_events(),
        exit_rx: handle.subscribe_exit(),
        commands_rx,
        generation: generation.clone(),
    };
    drivers.insert(
        thread_id.to_string(),
        EventDriverRegistration {
            generation,
            process: Arc::downgrade(handle),
            commands: commands_tx.clone(),
        },
    );
    drop(drivers);

    tokio::spawn(run_event_driver(args));
    commands_tx
}

async fn begin_driver_turn(
    driver: &mpsc::UnboundedSender<EventDriverCommand>,
    state: Arc<ConnectionState>,
    turn_id: &str,
    started_at: i64,
    turn_guard: TurnGuard,
) -> Result<(), BeginDriverTurnError> {
    let (ready_tx, ready_rx) = oneshot::channel();
    driver
        .send(EventDriverCommand::BeginTurn {
            state,
            turn_id: turn_id.to_string(),
            started_at,
            turn_guard,
            ready: ready_tx,
        })
        .map_err(|_| {
            BeginDriverTurnError::Unavailable(
                "claude thread event driver is not running".to_string(),
            )
        })?;
    ready_rx.await.map_err(|_| {
        BeginDriverTurnError::Unavailable(
            "claude thread event driver stopped before accepting turn".to_string(),
        )
    })?
}

async fn run_event_driver(mut args: EventDriverArgs) {
    let mut current: Option<DrivenTurn> = None;
    let mut background = BackgroundWork::default();
    let mut process_unhealthy = false;

    loop {
        if *args.exit_rx.borrow() {
            process_unhealthy = true;
            if let Some(turn) = current.as_mut() {
                turn.error_message = Some("claude process exited unexpectedly".into());
            }
            break;
        }
        let received = tokio::select! {
            biased;
            command = args.commands_rx.recv() => {
                match command {
                    Some(EventDriverCommand::BeginTurn {
                        state,
                        turn_id,
                        started_at,
                        turn_guard,
                        ready,
                    }) => {
                        if let Some(active) = current.as_ref() {
                            let _ = ready.send(Err(BeginDriverTurnError::AlreadyActive(
                                active.turn_id.clone(),
                            )));
                            continue;
                        }
                        // driver 跨页面和连接常驻，但每个被接受的 turn 必须归属
                        // 发起它的 ConnectionState。只在确认当前空闲后 rebind，
                        // 避免被 AlreadyActive 拒绝的请求偷走正在运行 turn 的事件。
                        args.state = state;
                        // 当前 turn 的 guard 已覆盖 session；后台等待 guard 暂时
                        // 释放，结束时如果仍有 cron/wakeup 会重新建立。
                        background.session_guard.take();
                        register_active_turn(&args.thread_id, &turn_id);
                        current = Some(DrivenTurn::new(
                            &args.thread_id,
                            turn_id,
                            started_at,
                            turn_guard,
                            false,
                        ));
                        let _ = ready.send(Ok(()));
                    }
                    Some(EventDriverCommand::AbortTurn { turn_id }) => {
                        if current.as_ref().is_some_and(|turn| turn.turn_id == turn_id) {
                            let mut turn = current.take().unwrap();
                            for (_, task) in turn.interaction_tasks.drain() {
                                task.abort();
                            }
                            clear_active_turn_if(&args.thread_id, &turn_id);
                            drop(turn.turn_guard);
                        }
                        continue;
                    }
                    None => break,
                }
                continue;
            }
            // stdout reader 先广播完最后一批 assistant/result，再设置退出信号。
            // event 分支排在 exit 前面，保证两个 future 同时 ready 时先排空消息。
            received = args.events_rx.recv() => received,
            exited = args.exit_rx.changed() => {
                if exited.is_err() || *args.exit_rx.borrow() {
                    process_unhealthy = true;
                    if let Some(turn) = current.as_mut() {
                        turn.error_message = Some("claude process exited unexpectedly".into());
                    }
                    break;
                }
                continue;
            }
        };
        let event = match received {
            Ok(ev) => ev,
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!(
                    thread_id = %args.thread_id,
                    "thread event driver lagged by {n} events; some notifications dropped"
                );
                continue;
            }
            Err(broadcast::error::RecvError::Closed) => {
                process_unhealthy = true;
                if let Some(turn) = current.as_mut() {
                    turn.error_message = Some("claude process exited unexpectedly".into());
                }
                break;
            }
        };

        let payload = event.payload;
        background.observe(&payload);

        // 与 turn 无关的 runtime 事件始终处理；页面不在场也要更新权威缓存。
        let mut account_notifications = Vec::new();
        match &payload {
            ClaudeOutbound::System(crate::pool::claude_protocol::SystemEvent::Init(init)) => {
                args.state.refresh_init_cache(init.as_ref().clone());
            }
            ClaudeOutbound::RateLimitEvent(env) => {
                let infos = args
                    .state
                    .refresh_rate_limit_cache(env.rate_limit_info.clone());
                account_notifications
                    .push(super::lifecycle::rate_limit_updated_notification(&infos));
            }
            _ => {}
        }
        for notif in account_notifications {
            if state_should_emit(&args.state, &notif) {
                let _ = args.state.send(notification_frame(notif));
            }
        }

        if current.is_none() && is_turn_scoped_event(&payload) {
            current = Some(begin_autonomous_turn(&args, &mut background).await);
        }
        let Some(turn) = current.as_mut() else {
            continue;
        };

        // Side-effect routes: bridge HITL prompts while this logical turn lives.
        match &payload {
            ClaudeOutbound::ControlRequest(value) => {
                // Spawn the HITL handler off the pump so the codex round-trip
                // (which can sit on a phone for minutes) doesn't block
                // subsequent stream events.
                if let Some(req) = approval::parse_can_use_tool(value) {
                    let Some(handle) = args.handle.upgrade() else {
                        turn.error_message =
                            Some("claude process exited while requesting approval".into());
                        continue;
                    };
                    let state = Arc::clone(&args.state);
                    let thread_id = args.thread_id.clone();
                    let turn_id = turn.turn_id.clone();
                    let request_id = req.request_id.clone();
                    let request_id_for_task = request_id.clone();
                    let interaction_gate = Arc::clone(&turn.interaction_gate);
                    let interaction = tokio::spawn(async move {
                        let _guard = interaction_gate.lock().await;
                        match approval::handle_can_use_tool(
                            &state, &handle, &thread_id, &turn_id, req,
                        )
                        .await
                        {
                            Ok(outcome) => tracing::debug!(?outcome, "HITL bridged"),
                            Err(err) => {
                                tracing::warn!(?err, "HITL bridging failed");
                                // Best-effort: tell claude to abort by
                                // replying with an error so it doesn't
                                // hang waiting for our response.
                                approval::reply_control_error(
                                    &handle,
                                    &request_id_for_task,
                                    format!("bridge HITL failed: {err}"),
                                );
                            }
                        }
                    });
                    turn.interaction_tasks.insert(request_id, interaction);
                } else if let Some(request_id) =
                    value.get("request_id").and_then(serde_json::Value::as_str)
                {
                    // Unknown subtype (hook_callback / mcp_message / future).
                    // Reply with error so claude doesn't hang.
                    if let Some(handle) = args.handle.upgrade() {
                        approval::reply_control_error(
                            &handle,
                            request_id,
                            "bridge does not handle this control_request subtype yet",
                        );
                    } else {
                        turn.error_message =
                            Some("claude process exited during control request".into());
                    }
                }
            }
            ClaudeOutbound::ControlCancelRequest(cancel) => {
                if let Some(task) = turn.interaction_tasks.remove(&cancel.request_id) {
                    task.abort();
                    tracing::debug!(
                        request_id = %cancel.request_id,
                        "cancelled claude mobile interaction"
                    );
                } else {
                    tracing::debug!(
                        request_id = %cancel.request_id,
                        "control_cancel_request had no active mobile interaction"
                    );
                }
            }
            _ => {}
        }
        let is_terminal = matches!(payload, ClaudeOutbound::Result(_));
        let authentication_failed = matches!(
            &payload,
            ClaudeOutbound::Result(result)
                if (result.is_error || result.subtype != "success")
                    && result.result.as_deref().is_some_and(is_claude_authentication_failure)
        );
        if let ClaudeOutbound::Result(ref r) = payload {
            if r.is_error || r.subtype != "success" {
                turn.error_message = Some(
                    r.result
                        .clone()
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| {
                            format!(
                                "claude turn ended with subtype {} (terminal_reason={:?})",
                                r.subtype, r.terminal_reason
                            )
                        }),
                );
            }
        }

        let notifications = turn.translator.translate(payload);
        for notif in notifications {
            // Record completed items in the per-thread log so `thread/read`
            // can answer from memory immediately after `turn/completed`,
            // without waiting for claude's process to flush its on-disk
            // JSONL. Recording is independent from notification opt-out:
            // disabling an event must not delete it from authoritative reads.
            if let p::ServerNotification::ItemCompleted(ref n) = notif {
                args.state
                    .record_item(&args.thread_id, &turn.turn_id, n.item.clone());
            }
            if !state_should_emit(&args.state, &notif) {
                continue;
            }
            let frame = notification_frame(notif);
            let _ = args.state.send(frame);
        }

        if is_terminal {
            let completed = current.take().unwrap();
            finish_driven_turn(&args, completed, &mut background).await;
            if authentication_failed {
                // Claude 进程可能缓存了启动时的旧 access token。先完整发布失败边界，
                // 再淘汰这一代进程；用户在 Mac 重新登录后显式重试会通过 --resume
                // 拉起新进程并读取最新凭据，不会继续命中旧认证状态。
                process_unhealthy = true;
                break;
            }
        }
    }

    if let Some(mut turn) = current.take() {
        if turn.error_message.is_none() {
            turn.error_message = Some("claude process event stream closed".into());
        }
        finish_driven_turn(&args, turn, &mut background).await;
    }

    {
        let mut drivers = EVENT_DRIVERS.lock().unwrap();
        if drivers
            .get(&args.thread_id)
            .is_some_and(|driver| driver.generation == args.generation)
        {
            drivers.remove(&args.thread_id);
        }
    }

    if process_unhealthy {
        if let Some(handle) = args.handle.upgrade() {
            let released = args
                .state
                .claude_pool()
                .release_if_same(&args.thread_id, &handle)
                .await;
            tracing::debug!(
                thread_id = %args.thread_id,
                released,
                "reaped unhealthy claude process generation"
            );
        }
    }
}

fn is_turn_scoped_event(payload: &ClaudeOutbound) -> bool {
    matches!(
        payload,
        ClaudeOutbound::StreamEvent(_)
            | ClaudeOutbound::Assistant(_)
            | ClaudeOutbound::User(_)
            | ClaudeOutbound::Result(_)
            | ClaudeOutbound::ControlRequest(_)
    )
}

async fn begin_autonomous_turn(
    args: &EventDriverArgs,
    background: &mut BackgroundWork,
) -> DrivenTurn {
    background.consume_autonomous_wakeup();
    let turn_id = Uuid::now_v7().to_string();
    let started_at = now_unix_secs();
    let turn_guard = args.state.session().begin_turn();
    background.session_guard.take();
    args.state.claude_pool().mark_active(&args.thread_id).await;
    register_active_turn(&args.thread_id, &turn_id);

    let turn = p::Turn {
        id: turn_id.clone(),
        items: Vec::new(),
        items_view: p::default_items_view(),
        status: p::TurnStatus::InProgress,
        error: None,
        started_at: Some(started_at),
        completed_at: None,
        duration_ms: None,
    };
    args.state
        .record_turn_started(&args.thread_id, turn_id.clone(), started_at);
    if args.state.should_emit("turn/started") {
        let _ = args
            .state
            .send(notification_frame(p::ServerNotification::TurnStarted(
                p::TurnStartedNotification {
                    thread_id: args.thread_id.clone(),
                    turn,
                },
            )));
    }
    tracing::info!(
        thread_id = %args.thread_id,
        turn_id = %turn_id,
        "claude produced output outside a client turn; started autonomous turn"
    );

    DrivenTurn::new(&args.thread_id, turn_id, started_at, turn_guard, true)
}

async fn finish_driven_turn(
    args: &EventDriverArgs,
    mut driven: DrivenTurn,
    background: &mut BackgroundWork,
) {
    // turn 结束或进程断开时取消所有等待中的移动端交互；
    // approval::PendingRequestGuard 会同步回收 pending request 槽位。
    for (_, task) in driven.interaction_tasks.drain() {
        task.abort();
    }

    let dangling_reason = driven
        .error_message
        .as_deref()
        .unwrap_or("claude turn ended before the item completed");
    for notif in driven.translator.abort_open_items(dangling_reason) {
        if let p::ServerNotification::ItemCompleted(ref n) = notif {
            args.state
                .record_item(&args.thread_id, &driven.turn_id, n.item.clone());
        }
        if state_should_emit(&args.state, &notif) {
            let _ = args.state.send(notification_frame(notif));
        }
    }

    let (status, error) = turn_status_from_result(driven.error_message.as_deref());
    let completed_at = now_unix_secs();
    let duration_ms = ((completed_at - driven.started_at) * 1000).max(0);
    let turn = p::Turn {
        id: driven.turn_id.clone(),
        items: Vec::new(),
        items_view: p::default_items_view(),
        status,
        error: error.clone(),
        started_at: Some(driven.started_at),
        completed_at: Some(completed_at),
        duration_ms: Some(duration_ms),
    };
    // Terminal 状态先进入 live cache，保证通知一旦可见，随后所有历史读取
    // 都能看到同一个完成边界。
    args.state.record_turn_completed(
        &args.thread_id,
        &driven.turn_id,
        completed_at,
        status,
        error.clone(),
    );
    if args.state.should_emit("turn/completed") {
        let frame = notification_frame(p::ServerNotification::TurnCompleted(
            p::TurnCompletedNotification {
                thread_id: args.thread_id.clone(),
                turn,
            },
        ));
        let _ = args.state.send(frame);
    }
    clear_active_turn_if(&args.thread_id, &driven.turn_id);

    // 列表的 updatedAt 也要由后台回复推进，否则用户重新打开 App 时，
    // 有新结果的会话仍会沉在旧位置。
    if let Some(entry) = args.state.thread_index().lookup(&args.thread_id).await {
        let _ = args
            .state
            .thread_index()
            .update_preview_and_updated_at(&args.thread_id, entry.preview, chrono::Utc::now())
            .await;
    }

    // 在释放当前 turn guard 之前接续后台 guard，避免 session reaper 在两者
    // 之间看到一个错误的空闲窗口。
    if background.has_pending() && background.session_guard.is_none() {
        background.session_guard = Some(args.state.session().begin_turn());
    }
    drop(driven.turn_guard);

    if background.has_pending() {
        args.state.claude_pool().mark_active(&args.thread_id).await;
    } else {
        args.state.claude_pool().mark_idle(&args.thread_id).await;
    }

    tracing::debug!(
        thread_id = %args.thread_id,
        turn_id = %driven.turn_id,
        autonomous = driven.autonomous,
        pending_wakeups = background.pending_wakeups,
        persistent_crons = background.persistent_crons,
        "claude logical turn completed"
    );
}

/// Map a `ServerNotification` to its `method` string and consult the
/// connection's opt-out list.
fn state_should_emit(state: &Arc<ConnectionState>, notif: &p::ServerNotification) -> bool {
    let method = match notif {
        p::ServerNotification::Error(_) => "error",
        p::ServerNotification::ThreadStarted(_) => "thread/started",
        p::ServerNotification::ThreadStatusChanged(_) => "thread/status/changed",
        p::ServerNotification::ThreadArchived(_) => "thread/archived",
        p::ServerNotification::ThreadUnarchived(_) => "thread/unarchived",
        p::ServerNotification::ThreadClosed(_) => "thread/closed",
        p::ServerNotification::SkillsChanged(_) => "skills/changed",
        p::ServerNotification::ThreadNameUpdated(_) => "thread/name/updated",
        p::ServerNotification::ThreadGoalCleared(_) => "thread/goal/cleared",
        p::ServerNotification::ThreadTokenUsageUpdated(_) => "thread/tokenUsage/updated",
        p::ServerNotification::TurnStarted(_) => "turn/started",
        p::ServerNotification::TurnCompleted(_) => "turn/completed",
        p::ServerNotification::TurnDiffUpdated(_) => "turn/diff/updated",
        p::ServerNotification::TurnPlanUpdated(_) => "turn/plan/updated",
        p::ServerNotification::HookStarted(_) => "hook/started",
        p::ServerNotification::HookCompleted(_) => "hook/completed",
        p::ServerNotification::ItemStarted(_) => "item/started",
        p::ServerNotification::ItemCompleted(_) => "item/completed",
        p::ServerNotification::AgentMessageDelta(_) => "item/agentMessage/delta",
        p::ServerNotification::ReasoningTextDelta(_) => "item/reasoning/textDelta",
        p::ServerNotification::ReasoningSummaryTextDelta(_) => "item/reasoning/summaryTextDelta",
        p::ServerNotification::ReasoningSummaryPartAdded(_) => "item/reasoning/summaryPartAdded",
        p::ServerNotification::CommandExecutionOutputDelta(_) => {
            "item/commandExecution/outputDelta"
        }
        p::ServerNotification::CommandExecOutputDelta(_) => "command/exec/outputDelta",
        p::ServerNotification::FileChangeOutputDelta(_) => "item/fileChange/outputDelta",
        p::ServerNotification::FileChangePatchUpdated(_) => "item/fileChange/patchUpdated",
        p::ServerNotification::McpToolCallProgress(_) => "item/mcpToolCall/progress",
        p::ServerNotification::DynamicToolCallArgumentsDelta(_) => {
            "item/dynamicToolCall/argumentsDelta"
        }
        p::ServerNotification::ContextCompacted(_) => "thread/compacted",
        p::ServerNotification::ModelRerouted(_) => "model/rerouted",
        p::ServerNotification::Warning(_) => "warning",
        p::ServerNotification::ConfigWarning(_) => "configWarning",
        p::ServerNotification::DeprecationNotice(_) => "deprecationNotice",
        p::ServerNotification::ServerRequestResolved(_) => "serverRequest/resolved",
        p::ServerNotification::McpServerStatusUpdated(_) => "mcpServer/startupStatus/updated",
        p::ServerNotification::AccountRateLimitsUpdated(_) => "account/rateLimits/updated",
        p::ServerNotification::RemoteControlStatusChanged(_) => "remoteControl/status/changed",
    };
    state.should_emit(method)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use serde_json::json;

    async fn dummy_state() -> Arc<ConnectionState> {
        let dir = tempfile::tempdir().unwrap();
        let index = alleycat_bridge_core::ThreadIndex::<crate::index::ClaudeSessionRef>::open_at(
            dir.path().join("t.json"),
        )
        .await
        .unwrap();
        std::mem::forget(dir);
        let (state, _rx) = ConnectionState::for_test(
            Arc::new(crate::pool::ClaudePool::new("/dev/null")),
            index,
            Default::default(),
        );
        state
    }

    async fn paired_states() -> (
        Arc<ConnectionState>,
        tokio::sync::mpsc::UnboundedReceiver<alleycat_bridge_core::session::Sequenced>,
        Arc<ConnectionState>,
        tokio::sync::mpsc::UnboundedReceiver<alleycat_bridge_core::session::Sequenced>,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let index = alleycat_bridge_core::ThreadIndex::<crate::index::ClaudeSessionRef>::open_at(
            dir.path().join("t.json"),
        )
        .await
        .unwrap();
        std::mem::forget(dir);

        let pool = Arc::new(crate::pool::ClaudePool::new("/dev/null"));
        let (first, first_rx) =
            ConnectionState::for_test(Arc::clone(&pool), index.clone(), Default::default());
        let (second, second_rx) = ConnectionState::for_test(pool, index, Default::default());
        (first, first_rx, second, second_rx)
    }

    fn emit_successful_text_turn(
        events: &broadcast::Sender<ClaudeEvent>,
        text: &str,
        event_id: &str,
    ) {
        let outbound = |value| serde_json::from_value(value).expect("valid claude event");
        for payload in [
            outbound(json!({
                "type": "stream_event",
                "event": {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""}
                },
                "session_id": "test-session",
                "uuid": format!("{event_id}-start")
            })),
            outbound(json!({
                "type": "stream_event",
                "event": {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": text}
                },
                "session_id": "test-session",
                "uuid": format!("{event_id}-delta")
            })),
            outbound(json!({
                "type": "stream_event",
                "event": {"type": "content_block_stop", "index": 0},
                "session_id": "test-session",
                "uuid": format!("{event_id}-stop")
            })),
            outbound(json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "result": text,
                "session_id": "test-session",
                "uuid": format!("{event_id}-result"),
                "permission_denials": []
            })),
        ] {
            events
                .send(ClaudeEvent::new(payload))
                .expect("event driver subscribed");
        }
    }

    async fn wait_for_completed_turn(state: &ConnectionState, thread_id: &str, turn_id: &str) {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if state
                    .thread_log(thread_id)
                    .iter()
                    .any(|turn| turn.id == turn_id && turn.status == p::TurnStatus::Completed)
                {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("turn should complete");
    }

    fn drain_turn_methods(
        rx: &mut tokio::sync::mpsc::UnboundedReceiver<alleycat_bridge_core::session::Sequenced>,
        turn_id: &str,
    ) -> Vec<String> {
        let mut methods = Vec::new();
        while let Ok(frame) = rx.try_recv() {
            if frame.payload.to_string().contains(turn_id)
                && let Some(method) = frame
                    .payload
                    .get("method")
                    .and_then(serde_json::Value::as_str)
            {
                methods.push(method.to_string());
            }
        }
        methods
    }

    #[tokio::test]
    async fn turn_start_returns_thread_not_loaded_when_pool_empty() {
        let state = dummy_state().await;
        let err = handle_turn_start(
            &state,
            p::TurnStartParams {
                thread_id: "missing".into(),
                input: vec![p::UserInput::Text {
                    text: "hi".into(),
                    text_elements: Vec::new(),
                }],
                ..Default::default()
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ThreadNotLoaded(_)));
    }

    fn text_input(s: &str) -> p::UserInput {
        p::UserInput::Text {
            text: s.into(),
            text_elements: Vec::new(),
        }
    }

    #[test]
    fn preview_uses_first_non_empty_line() {
        let input = vec![text_input("\n  \n第一行标题\n第二行\n")];
        assert_eq!(preview_from_input(&input).as_deref(), Some("第一行标题"));
    }

    #[test]
    fn preview_none_when_no_text() {
        let input = vec![p::UserInput::Image { url: "x".into() }];
        assert_eq!(preview_from_input(&input), None);
    }

    #[tokio::test]
    async fn backfill_sets_empty_preview_and_leaves_existing() {
        let state = dummy_state().await;
        let entry = |id: &str, preview: &str| crate::index::IndexEntry {
            thread_id: id.into(),
            cwd: "/tmp".into(),
            name: None,
            preview: preview.into(),
            created_at: 0,
            updated_at: 0,
            archived: false,
            forked_from_id: None,
            model_provider: "anthropic".into(),
            source: p::ThreadSourceKind::AppServer,
            metadata: crate::index::ClaudeSessionRef {
                claude_session_path: "/tmp/a.jsonl".into(),
                claude_session_id: id.into(),
            },
        };
        state
            .thread_index()
            .insert(entry("empty", ""))
            .await
            .unwrap();
        state
            .thread_index()
            .insert(entry("named", "已有预览"))
            .await
            .unwrap();

        let input = vec![text_input("你好世界\n更多内容")];
        let preview = preview_from_input(&input).unwrap();
        maybe_backfill_preview(&state, "empty", preview.clone()).await;
        maybe_backfill_preview(&state, "named", preview).await;

        assert_eq!(
            state.thread_index().lookup("empty").await.unwrap().preview,
            "你好世界"
        );
        assert_eq!(
            state.thread_index().lookup("named").await.unwrap().preview,
            "已有预览"
        );
    }

    #[test]
    fn permission_modes_follow_the_three_safe_presets() {
        let mut params = p::TurnStartParams::default();
        assert_eq!(claude_permission_mode(&params), "default");

        params.collaboration_mode = Some(serde_json::json!({"mode": "plan", "settings": {}}));
        assert_eq!(claude_permission_mode(&params), "plan");

        params.collaboration_mode = Some(serde_json::json!({"mode": "default", "settings": {}}));
        params.sandbox_policy = Some(serde_json::json!({"type": "readOnly"}));
        assert_eq!(claude_permission_mode(&params), "plan");

        params.sandbox_policy = Some(serde_json::json!({"type": "workspaceWrite"}));
        params.approval_policy = Some(p::AskForApproval::OnRequest);
        params.approvals_reviewer = Some(p::ApprovalsReviewer::AutoReview);
        assert_eq!(claude_permission_mode(&params), "auto");

        params.approval_policy = Some(p::AskForApproval::OnFailure);
        assert_eq!(claude_permission_mode(&params), "default");

        params.approval_policy = Some(p::AskForApproval::Never);
        assert_eq!(claude_permission_mode(&params), "default");
    }

    #[test]
    fn only_explicit_invalid_model_control_errors_are_permanent_rejections() {
        let invalid = ClaudeProcessError::RuntimeOverride {
            field: "model",
            value: "019f9e54-bad2".into(),
            source: Box::new(ClaudeProcessError::ControlError {
                request_id: "set-model".into(),
                message: "Model is not a recognized model id".into(),
            }),
        };
        assert_eq!(
            explicit_model_rejection(&invalid),
            Some((
                "019f9e54-bad2".into(),
                "Model is not a recognized model id".into()
            ))
        );

        let transient = ClaudeProcessError::RuntimeOverride {
            field: "model",
            value: "sonnet".into(),
            source: Box::new(ClaudeProcessError::ControlError {
                request_id: "set-model".into(),
                message: "service temporarily unavailable".into(),
            }),
        };
        assert_eq!(explicit_model_rejection(&transient), None);
    }

    #[test]
    fn native_effort_keeps_the_top_four_levels_and_clamps_legacy_low_values() {
        assert_eq!(native_effort_level(p::ReasoningEffort::Medium), "medium");
        assert_eq!(native_effort_level(p::ReasoningEffort::High), "high");
        assert_eq!(native_effort_level(p::ReasoningEffort::XHigh), "xhigh");
        assert_eq!(native_effort_level(p::ReasoningEffort::Max), "max");
        assert_eq!(native_effort_level(p::ReasoningEffort::Minimal), "medium");
        assert_eq!(native_effort_level(p::ReasoningEffort::Low), "medium");
    }

    #[tokio::test]
    async fn turn_steer_rejects_unknown_thread() {
        let state = dummy_state().await;
        let err = handle_turn_steer(
            &state,
            p::TurnSteerParams {
                thread_id: "missing".into(),
                input: vec![p::UserInput::Text {
                    text: "x".into(),
                    text_elements: Vec::new(),
                }],
                expected_turn_id: "any".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ThreadNotLoaded(_)));
    }

    #[tokio::test]
    async fn turn_interrupt_returns_thread_not_loaded_when_pool_empty() {
        let state = dummy_state().await;
        let err = handle_turn_interrupt(
            &state,
            p::TurnInterruptParams {
                thread_id: "missing".into(),
                turn_id: "tu".into(),
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ThreadNotLoaded(_)));
    }

    #[tokio::test]
    async fn review_start_is_unsupported() {
        let state = dummy_state().await;
        let err = handle_review_start(
            &state,
            p::ReviewStartParams {
                thread_id: "t".into(),
                target: p::ReviewTarget::UncommittedChanges,
                delivery: None,
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ReviewUnsupported));
        assert_eq!(err.rpc_code(), p::error_codes::METHOD_NOT_FOUND);
    }

    #[test]
    fn active_turn_table_round_trip() {
        let thread_id = format!("test-{}", Uuid::now_v7());
        register_active_turn(&thread_id, "tu1");
        let active = active_turn(&thread_id).unwrap();
        assert_eq!(active.turn_id, "tu1");
        clear_active_turn(&thread_id);
        assert!(active_turn(&thread_id).is_none());
    }

    #[tokio::test]
    async fn reused_event_driver_rebinds_each_turn_to_its_connection_state() {
        let thread_id = format!("test-{}", Uuid::now_v7());
        let (first, mut first_rx, second, mut second_rx) = paired_states().await;
        let (writer_tx, _writer_rx) = mpsc::unbounded_channel();
        let (events_tx, _events_rx) = broadcast::channel(16);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx.clone(),
            PathBuf::from("/tmp"),
        ));

        let first_driver = ensure_event_driver(&first, &thread_id, &handle);
        begin_driver_turn(
            &first_driver,
            Arc::clone(&first),
            "turn-first",
            1,
            first.session().begin_turn(),
        )
        .await
        .expect("first turn accepted");
        first.record_turn_started(&thread_id, "turn-first".into(), 1);
        emit_successful_text_turn(&events_tx, "first reply", "first");
        wait_for_completed_turn(&first, &thread_id, "turn-first").await;

        assert!(second.thread_log(&thread_id).is_empty());
        assert!(
            drain_turn_methods(&mut first_rx, "turn-first")
                .iter()
                .any(|method| method == "turn/completed")
        );
        assert!(drain_turn_methods(&mut second_rx, "turn-first").is_empty());

        // 第二个页面复用同一个进程和 driver；事件、live cache 和完成通知都应
        // 跟随新 turn 的 ConnectionState，不能继续写回首次建 driver 的连接。
        let second_driver = ensure_event_driver(&second, &thread_id, &handle);
        begin_driver_turn(
            &second_driver,
            Arc::clone(&second),
            "turn-second",
            2,
            second.session().begin_turn(),
        )
        .await
        .expect("second turn accepted");
        second.record_turn_started(&thread_id, "turn-second".into(), 2);
        emit_successful_text_turn(&events_tx, "second reply", "second");
        wait_for_completed_turn(&second, &thread_id, "turn-second").await;

        assert!(
            first
                .thread_log(&thread_id)
                .iter()
                .all(|turn| turn.id != "turn-second")
        );
        let second_turn = second
            .thread_log(&thread_id)
            .into_iter()
            .find(|turn| turn.id == "turn-second")
            .expect("second state owns second turn");
        assert!(second_turn.items.iter().any(|item| {
            matches!(item, p::ThreadItem::AgentMessage { text, .. } if text == "second reply")
        }));
        assert!(drain_turn_methods(&mut first_rx, "turn-second").is_empty());
        let second_methods = drain_turn_methods(&mut second_rx, "turn-second");
        assert!(
            second_methods
                .iter()
                .any(|method| method == "item/completed")
        );
        assert!(
            second_methods
                .iter()
                .any(|method| method == "turn/completed")
        );

        drop(first_driver);
        drop(second_driver);
        drop(handle);
        drop(events_tx);
    }

    #[test]
    fn turn_error_rpc_codes() {
        assert_eq!(
            TurnError::InvalidParams("x".into()).rpc_code(),
            p::error_codes::INVALID_PARAMS
        );
        assert_eq!(
            TurnError::ReviewUnsupported.rpc_code(),
            p::error_codes::METHOD_NOT_FOUND
        );
        assert_eq!(
            TurnError::ClaudeRpc("oops".into()).rpc_code(),
            p::error_codes::INTERNAL_ERROR
        );
        let rejected = TurnError::ModelRejected {
            model: "unknown-model".into(),
            message: "not recognized".into(),
        };
        assert_eq!(rejected.rpc_code(), p::error_codes::INVALID_PARAMS);
        assert_eq!(
            rejected.rpc_data(),
            Some(serde_json::json!({
                "accepted": false,
                "field": "model",
                "model": "unknown-model",
                "phase": "runtime_overrides",
                "reason": "not recognized",
                "retryable": false,
            }))
        );

        let active = TurnError::AlreadyActive {
            thread_id: "thread-1".into(),
            active_turn_id: "turn-live".into(),
        };
        assert_eq!(active.rpc_code(), p::error_codes::INVALID_PARAMS);
        assert_eq!(
            active.rpc_data(),
            Some(serde_json::json!({
                "accepted": false,
                "reason": "active_turn",
                "threadId": "thread-1",
                "activeTurnId": "turn-live",
                "retryable": false,
            }))
        );
    }
}
