//! `thread/*` request handlers.
//!
//! Mapped to the bridge plan's "Thread management" surface. The handlers
//! coordinate three resources:
//!
//! - [`crate::pool::ClaudePool`] — the live `claude -p` subprocesses.
//! - [`crate::state::ThreadIndexHandle`] — the disk-backed `threads.json`
//!   metadata (cwd, name, archive flag, preview, fork chain).
//! - [`crate::state::ConnectionState::defaults`] — the connection-scoped
//!   defaults applied when the request omits them (model, etc.).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use alleycat_bridge_core::{ProcessRole, ProcessSpec, StdioMode};
use thiserror::Error;
use tokio::io::AsyncReadExt;
use uuid::Uuid;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

use alleycat_codex_proto as p;

use crate::handlers::model::{normalize_claude_model, normalize_claude_model_id};
use crate::index::IndexEntry;
use crate::pool::PoolError;
use crate::pool::claude_protocol::ControlRequestBody;
use crate::pool::process::ClaudeProcessError;
use crate::state::ConnectionState;
use crate::translate::items::{
    last_assistant_model, last_assistant_model_from_text, list_user_message_ids,
    list_user_message_ids_from_text, messages_text_to_turns, messages_to_turns,
};

#[derive(Debug, Error)]
pub enum ThreadError {
    #[error("invalid params: {0}")]
    InvalidParams(String),
    #[error("thread `{0}` not found in index")]
    NotFound(String),
    #[error("pool error: {0}")]
    Pool(String),
    #[error("claude rpc error: {0}")]
    ClaudeRpc(String),
    #[error("method `{0}` is not implemented in claude-bridge v1")]
    Unsupported(String),
    #[error(transparent)]
    Index(#[from] anyhow::Error),
}

impl ThreadError {
    pub fn rpc_code(&self) -> i64 {
        match self {
            ThreadError::InvalidParams(_) | ThreadError::NotFound(_) => {
                p::error_codes::INVALID_PARAMS
            }
            ThreadError::Unsupported(_) => p::error_codes::METHOD_NOT_FOUND,
            ThreadError::Pool(_) | ThreadError::ClaudeRpc(_) | ThreadError::Index(_) => {
                p::error_codes::INTERNAL_ERROR
            }
        }
    }

    fn pool(err: PoolError) -> Self {
        Self::Pool(format!("{err:#}"))
    }
}

// ============================================================================
// thread/start
// ============================================================================

pub async fn handle_thread_start(
    state: &Arc<ConnectionState>,
    params: p::ThreadStartParams,
) -> Result<p::ThreadStartResponse, ThreadError> {
    let cwd = resolve_cwd(params.cwd.as_deref())?;
    let defaults = state.defaults();

    let model = normalize_claude_model(params.model.clone().or_else(|| defaults.model.clone()));
    let system_prompt = defaults.system_prompt.clone();

    let thread_id = if should_defer_process_start(state, &model, &system_prompt) {
        Uuid::now_v7().to_string()
    } else {
        let (thread_id, _handle) = state
            .claude_pool()
            .acquire_for_new_thread(&cwd, model.clone(), system_prompt.clone())
            .await
            .map_err(ThreadError::pool)?;
        thread_id
    };

    // Real claude does not emit `system/init` until the first user message
    // arrives on stdin (verified empirically and against the Anthropic SDK).
    // Awaiting init here would deadlock — we'd wait 30s, claude would exit,
    // and the bridge would error. The pump in `turn::handle_turn_start`
    // refreshes the init cache as a normal first-event side effect once the
    // user envelope is written.

    let now_ms = now_unix_millis();
    let model_provider = params
        .model_provider
        .clone()
        .or_else(|| defaults.model_provider.clone())
        .unwrap_or_else(|| "anthropic".to_string());
    let entry = IndexEntry {
        thread_id: thread_id.clone(),
        cwd: cwd.to_string_lossy().into_owned(),
        name: params.service_name.clone(),
        preview: String::new(),
        created_at: now_ms,
        updated_at: now_ms,
        archived: false,
        forked_from_id: None,
        model_provider: model_provider.clone(),
        source: p::ThreadSourceKind::AppServer,
        metadata: crate::index::ClaudeSessionRef {
            claude_session_path: claude_session_path_for(&cwd, &thread_id),
            claude_session_id: thread_id.clone(),
        },
    };
    state
        .thread_index()
        .insert(entry.clone())
        .await
        .map_err(ThreadError::from)?;

    // Emit `thread/started` so codex clients pick up the new thread.
    if state.should_emit("thread/started") {
        let frame = notification_frame(p::ServerNotification::ThreadStarted(
            p::ThreadStartedNotification {
                thread: thread_from_entry(&entry),
            },
        ));
        let _ = state.send(frame);
    }

    // Without a captured init, fall back to the cached model (set by the
    // pump on a previous turn against any thread) or the empty string.
    let response_model = model
        .or_else(|| state.caches().last_init.as_ref().map(|i| i.model.clone()))
        .map(|model| normalize_claude_model_id(&model))
        .unwrap_or_default();
    let approval_policy = params
        .approval_policy
        .clone()
        .or(defaults.approval_policy)
        .unwrap_or(p::AskForApproval::OnRequest);
    let approvals_reviewer = params
        .approvals_reviewer
        .or(defaults.approvals_reviewer)
        .unwrap_or(p::ApprovalsReviewer::User);
    let sandbox = sandbox_value(params.sandbox.or(defaults.sandbox));
    let reasoning_effort = effort_from_params(&params.additional)
        .or(defaults.reasoning_effort)
        .or(Some(p::ReasoningEffort::High));

    Ok(p::ThreadStartResponse {
        thread: thread_from_entry(&entry),
        model: response_model,
        model_provider,
        service_tier: Some(default_service_tier()),
        cwd: cwd.to_string_lossy().into_owned(),
        instruction_sources: Vec::new(),
        approval_policy,
        approvals_reviewer,
        sandbox,
        permission_profile: params
            .permission_profile
            .clone()
            .or_else(|| Some(default_permission_profile())),
        active_permission_profile: None,
        reasoning_effort,
    })
}

// ============================================================================
// thread/resume
// ============================================================================

pub async fn handle_thread_resume(
    state: &Arc<ConnectionState>,
    params: p::ThreadResumeParams,
) -> Result<p::ThreadResumeResponse, ThreadError> {
    let entry = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;

    let cwd = resume_cwd_or_fallback(&entry.cwd, &params.thread_id, state.trust_persisted_cwd());
    let defaults = state.defaults();
    let model = normalize_claude_model(params.model.clone().or_else(|| defaults.model.clone()));
    let system_prompt = defaults.system_prompt.clone();

    if !should_defer_process_start(state, &model, &system_prompt) {
        let _handle = state
            .claude_pool()
            .acquire_for_resume(params.thread_id.clone(), &cwd, model.clone(), system_prompt)
            .await
            .map_err(ThreadError::pool)?;
    }
    // Init is deferred to the first `turn/start` — see handle_thread_start
    // for the rationale (claude only emits init after the first user
    // envelope arrives on stdin).

    let mut thread = thread_from_entry(&entry);
    if !params.exclude_turns {
        thread.turns = cached_thread_turns(state, &entry).await?;
    }
    let is_loaded = state
        .claude_pool()
        .loaded_thread_ids()
        .await
        .iter()
        .any(|id| id == &params.thread_id);
    apply_live_thread_status(&mut thread, is_loaded);

    let response_model = match model {
        Some(m) => normalize_claude_model_id(&m),
        None => {
            // Prefer this thread's transcript (specific) over the connection-
            // wide `last_init` cache (whichever thread last ran a turn).
            let from_transcript =
                transcript_model(state, &entry.metadata.claude_session_path).await;
            from_transcript
                .or_else(|| state.caches().last_init.as_ref().map(|i| i.model.clone()))
                .map(|m| normalize_claude_model_id(&m))
                .unwrap_or_default()
        }
    };
    let model_provider = params
        .model_provider
        .clone()
        .unwrap_or_else(|| entry.model_provider.clone());
    let approval_policy = params
        .approval_policy
        .clone()
        .or(defaults.approval_policy)
        .unwrap_or(p::AskForApproval::OnRequest);
    let approvals_reviewer = params
        .approvals_reviewer
        .or(defaults.approvals_reviewer)
        .unwrap_or(p::ApprovalsReviewer::User);
    let sandbox = sandbox_value(params.sandbox.or(defaults.sandbox));

    Ok(p::ThreadResumeResponse {
        thread,
        model: response_model,
        model_provider,
        service_tier: Some(default_service_tier()),
        cwd: entry.cwd.clone(),
        instruction_sources: Vec::new(),
        approval_policy,
        approvals_reviewer,
        sandbox,
        permission_profile: params
            .permission_profile
            .clone()
            .or_else(|| Some(default_permission_profile())),
        active_permission_profile: None,
        reasoning_effort: effort_from_params(&params.additional)
            .or(defaults.reasoning_effort)
            .or(Some(p::ReasoningEffort::High)),
    })
}

// ============================================================================
// thread/fork
// ============================================================================

pub async fn handle_thread_fork(
    state: &Arc<ConnectionState>,
    params: p::ThreadForkParams,
) -> Result<p::ThreadForkResponse, ThreadError> {
    let source = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;
    let cwd = PathBuf::from(&source.cwd);
    let defaults = state.defaults();
    let model = normalize_claude_model(params.model.clone().or_else(|| defaults.model.clone()));
    let system_prompt = defaults.system_prompt.clone();

    // Mint a new UUID and resume a fresh session id. Local daemon mode keeps
    // the older "copy the parent's transcript into the new id's slot"
    // approximation. Remote launcher mode must not copy transcript files into
    // the bridge process filesystem; it records the remote target path and
    // relies on the spawned remote agent for subsequent history.
    let new_thread_id = Uuid::now_v7().to_string();
    let new_session_path = claude_session_path_for(&cwd, &new_thread_id);
    if !state.trust_persisted_cwd() {
        if let Some(parent) = new_session_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| ThreadError::ClaudeRpc(format!("create fork dir: {e}")))?;
        }
        if source.metadata.claude_session_path.exists() {
            tokio::fs::copy(&source.metadata.claude_session_path, &new_session_path)
                .await
                .map_err(|e| ThreadError::ClaudeRpc(format!("copy fork transcript: {e}")))?;
        }
    }

    let _handle = state
        .claude_pool()
        .acquire_for_resume(new_thread_id.clone(), &cwd, model.clone(), system_prompt)
        .await
        .map_err(ThreadError::pool)?;
    // Init deferred to first turn — see handle_thread_start.

    let now_ms = now_unix_millis();
    let entry = IndexEntry {
        thread_id: new_thread_id.clone(),
        cwd: source.cwd.clone(),
        name: source.name.clone(),
        preview: source.preview.clone(),
        created_at: now_ms,
        updated_at: now_ms,
        archived: false,
        forked_from_id: Some(source.thread_id.clone()),
        model_provider: source.model_provider.clone(),
        source: p::ThreadSourceKind::AppServer,
        metadata: crate::index::ClaudeSessionRef {
            claude_session_path: new_session_path,
            claude_session_id: new_thread_id.clone(),
        },
    };
    state
        .thread_index()
        .insert(entry.clone())
        .await
        .map_err(ThreadError::from)?;

    let mut thread = thread_from_entry(&entry);
    if !params.exclude_turns {
        thread.turns = transcript_turns(state, &entry.metadata.claude_session_path).await?;
    }

    let response_model = match model {
        Some(m) => normalize_claude_model_id(&m),
        None => {
            let from_transcript =
                transcript_model(state, &entry.metadata.claude_session_path).await;
            from_transcript
                .or_else(|| state.caches().last_init.as_ref().map(|i| i.model.clone()))
                .map(|m| normalize_claude_model_id(&m))
                .unwrap_or_default()
        }
    };
    Ok(p::ThreadForkResponse {
        thread,
        model: response_model,
        model_provider: params
            .model_provider
            .clone()
            .unwrap_or_else(|| source.model_provider.clone()),
        service_tier: Some(default_service_tier()),
        cwd: source.cwd.clone(),
        instruction_sources: Vec::new(),
        approval_policy: params
            .approval_policy
            .clone()
            .or(defaults.approval_policy)
            .unwrap_or(p::AskForApproval::OnRequest),
        approvals_reviewer: params
            .approvals_reviewer
            .or(defaults.approvals_reviewer)
            .unwrap_or(p::ApprovalsReviewer::User),
        sandbox: sandbox_value(params.sandbox.or(defaults.sandbox)),
        permission_profile: params
            .permission_profile
            .clone()
            .or_else(|| Some(default_permission_profile())),
        active_permission_profile: None,
        reasoning_effort: effort_from_params(&params.additional)
            .or(defaults.reasoning_effort)
            .or(Some(p::ReasoningEffort::High)),
    })
}

// ============================================================================
// thread/archive / unarchive
// ============================================================================

pub async fn handle_thread_archive(
    state: &Arc<ConnectionState>,
    params: p::ThreadArchiveParams,
) -> Result<p::ThreadArchiveResponse, ThreadError> {
    let changed = state
        .thread_index()
        .set_archived(&params.thread_id, true)
        .await
        .map_err(ThreadError::from)?;
    if !changed {
        return Err(ThreadError::NotFound(params.thread_id));
    }
    if state.should_emit("thread/archived") {
        let frame = notification_frame(p::ServerNotification::ThreadArchived(p::ThreadIdOnly {
            thread_id: params.thread_id.clone(),
        }));
        let _ = state.send(frame);
    }
    Ok(p::ThreadArchiveResponse::default())
}

pub async fn handle_thread_unarchive(
    state: &Arc<ConnectionState>,
    params: p::ThreadUnarchiveParams,
) -> Result<p::ThreadUnarchiveResponse, ThreadError> {
    let changed = state
        .thread_index()
        .set_archived(&params.thread_id, false)
        .await
        .map_err(ThreadError::from)?;
    if !changed {
        return Err(ThreadError::NotFound(params.thread_id));
    }
    let entry = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;
    if state.should_emit("thread/unarchived") {
        let frame = notification_frame(p::ServerNotification::ThreadUnarchived(p::ThreadIdOnly {
            thread_id: params.thread_id.clone(),
        }));
        let _ = state.send(frame);
    }
    Ok(p::ThreadUnarchiveResponse {
        thread: thread_from_entry(&entry),
    })
}

// ============================================================================
// thread/name/set
// ============================================================================

pub async fn handle_thread_set_name(
    state: &Arc<ConnectionState>,
    params: p::ThreadSetNameParams,
) -> Result<p::ThreadSetNameResponse, ThreadError> {
    let trimmed = params.name.trim().to_string();
    let stored = if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.clone())
    };
    let changed = state
        .thread_index()
        .set_name(&params.thread_id, stored.clone())
        .await
        .map_err(ThreadError::from)?;
    if !changed {
        return Err(ThreadError::NotFound(params.thread_id.clone()));
    }
    if state.should_emit("thread/name/updated") {
        let frame = notification_frame(p::ServerNotification::ThreadNameUpdated(
            p::ThreadNameUpdatedNotification {
                thread_id: params.thread_id.clone(),
                thread_name: stored,
            },
        ));
        let _ = state.send(frame);
    }
    Ok(p::ThreadSetNameResponse::default())
}

// ============================================================================
// thread/compact/start
// ============================================================================

pub async fn handle_thread_compact_start(
    state: &Arc<ConnectionState>,
    params: p::ThreadCompactStartParams,
) -> Result<p::ThreadCompactStartResponse, ThreadError> {
    // `send_serialized` 本身虽然不 await，但 Tokio 使用多线程 runtime；进程池锁
    // 释放后，其他 worker 仍可并发执行 LRU 淘汰并关闭这个 inactive 进程。
    // reservation 必须覆盖到命令完成入队，避免返回成功但 `/compact` 实际未发送。
    let (handle, _admission) = state
        .claude_pool()
        .get_with_admission(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;

    // claude treats `/compact` as an inline slash command in the user
    // envelope. Fire-and-forget; the matching `thread/compacted` notification
    // arrives via the event pump on the next `result`.
    let envelope = crate::pool::claude_protocol::ClaudeInbound::User(
        crate::pool::claude_protocol::ClaudeUserMessageEnvelope {
            message: crate::pool::claude_protocol::ClaudeUserMessage {
                role: crate::pool::claude_protocol::ClaudeUserRole::User,
                content: crate::pool::claude_protocol::ClaudeUserContent::Text(
                    "/compact".to_string(),
                ),
            },
            parent_tool_use_id: None,
        },
    );
    handle
        .send_serialized(&envelope)
        .map_err(|e| ThreadError::ClaudeRpc(e.to_string()))?;
    Ok(p::ThreadCompactStartResponse::default())
}

// ============================================================================
// thread/rollback
// ============================================================================

pub async fn handle_thread_rollback(
    state: &Arc<ConnectionState>,
    params: p::ThreadRollbackParams,
) -> Result<p::ThreadRollbackResponse, ThreadError> {
    if params.num_turns == 0 {
        return Err(ThreadError::InvalidParams(
            "numTurns must be >= 1".to_string(),
        ));
    }
    let entry = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;

    // Walk the on-disk transcript and pick the user message we want to rewind
    // *to* — i.e. the most recent message we want to keep. Codex's semantic
    // is "drop the last numTurns user-anchored turns"; rewind_files's semantic
    // (per the SDK signature) is "rewind to (i.e. immediately after) this
    // user message". So with N user messages and numTurns=K we keep the
    // first (N - K) and target the (N - K - 1)-th id.
    let path = std::path::PathBuf::from(&entry.metadata.claude_session_path);
    let user_ids = transcript_user_message_ids(state, &path).await?;
    let n = user_ids.len();
    let target_index = n
        .checked_sub(params.num_turns as usize)
        .and_then(|i| i.checked_sub(1))
        .ok_or_else(|| {
            ThreadError::InvalidParams(format!(
                "thread has {n} user turns; cannot rollback {} (would leave nothing)",
                params.num_turns
            ))
        })?;
    let target_id = user_ids[target_index].clone();

    // Need a live process to send the control_request. Resume into the pool
    // if not already loaded — same pattern as `thread/resume`.
    //
    // 与 turn/start 同理：rewind 的 control request 最长要等 30 秒，期间进程
    // 仍是 active=false，池满时的 LRU 淘汰会把它关掉。用 reservation 覆盖到
    // 请求返回为止。
    let (handle, admission) = match state
        .claude_pool()
        .get_with_admission(&params.thread_id)
        .await
    {
        Some(reserved) => reserved,
        None => {
            let cwd = std::path::PathBuf::from(&entry.cwd);
            state
                .claude_pool()
                .acquire_for_resume_with_admission(params.thread_id.clone(), &cwd, None, None)
                .await
                .map_err(ThreadError::pool)?
        }
    };

    let rewind = handle
        .request_control(
            ControlRequestBody::RewindFiles {
                user_message_id: target_id,
                dry_run: None,
            },
            std::time::Duration::from_secs(30),
        )
        .await;
    drop(admission);
    rewind.map_err(|e: ClaudeProcessError| match e {
        ClaudeProcessError::ControlError { message, .. } => ThreadError::ClaudeRpc(message),
        other => ThreadError::ClaudeRpc(other.to_string()),
    })?;

    // Rebuild the Thread snapshot from the (now-rewound) transcript so the
    // codex client sees the new state.
    let turns = transcript_turns(state, &path).await?;
    let mut thread = thread_from_entry(&entry);
    thread.turns = turns;
    Ok(p::ThreadRollbackResponse { thread })
}

// ============================================================================
// thread/list
// ============================================================================

pub async fn handle_thread_list(
    state: &Arc<ConnectionState>,
    params: p::ThreadListParams,
) -> Result<p::ThreadListResponse, ThreadError> {
    if params.refresh_history {
        if params.cursor.is_some() {
            return Err(ThreadError::InvalidParams(
                "refreshHistory is only valid on the first page".to_string(),
            ));
        }
        if params.use_state_db_only {
            return Err(ThreadError::InvalidParams(
                "refreshHistory cannot be combined with useStateDbOnly".to_string(),
            ));
        }
        if let Some(refresher) = state.history_refresher() {
            match refresher
                .refresh_if_due()
                .await
                .map_err(ThreadError::from)?
            {
                crate::index::HistoryRefreshResult::Refreshed { inserted } => {
                    tracing::info!(inserted, "refreshed Claude history index");
                }
                crate::index::HistoryRefreshResult::RateLimited => {
                    tracing::debug!("skipped rate-limited Claude history refresh");
                }
            }
        }
    }

    // Match codex-rs semantics: omitted `archived` means "non-archived only"
    // (`unwrap_or(false)`), not "all".
    let archived = Some(params.archived.unwrap_or(false));
    let filter = crate::index::ListFilter {
        archived,
        cwds: parse_cwd_filter(&params.cwd),
        search_term: params.search_term.clone(),
        model_providers: params.model_providers.clone(),
        source_kinds: params.source_kinds.clone(),
    };
    // Default sort is `created_at` per the codex schema.
    let sort = crate::index::ListSort {
        key: params.sort_key.unwrap_or(p::ThreadSortKey::CreatedAt),
        direction: params.sort_direction.unwrap_or(p::SortDirection::Desc),
    };
    let limit = alleycat_bridge_core::resolve_list_limit(params.limit);
    // 普通请求始终只读 threads.json；只有上面的显式 refreshHistory 首屏会触发受限扫描。

    let page = state
        .thread_index()
        .list(&filter, sort, params.cursor.as_deref(), Some(limit))
        .await
        .map_err(ThreadError::from)?;

    let backwards_cursor = page
        .data
        .first()
        .map(|e| alleycat_bridge_core::encode_backwards_cursor(e, sort));

    let loaded: std::collections::HashSet<String> = state
        .claude_pool()
        .loaded_thread_ids()
        .await
        .into_iter()
        .filter(|id| !id.starts_with("utility_"))
        .collect();
    // git_info 每条要 fork 三个 git 子进程。全局列表一页 50 条会产生 150 个进程、
    // 实测约 3 秒；同一页里的 thread 通常只落在少数几个 cwd 上，按 cwd 去重后
    // 降到个位数。
    let mut git_info_by_cwd: std::collections::HashMap<
        String,
        Option<alleycat_codex_proto::GitInfo>,
    > = std::collections::HashMap::new();
    let data = page
        .data
        .into_iter()
        .map(|entry| {
            let git_info = git_info_by_cwd
                .entry(entry.cwd.clone())
                .or_insert_with(|| alleycat_bridge_core::git_info_for_cwd(&entry.cwd))
                .clone();
            let mut t = crate::index::entry_to_thread_with_git_info(&entry, Some(git_info));
            let is_loaded = loaded.contains(&t.id);
            apply_live_thread_status(&mut t, is_loaded);
            t
        })
        .collect();
    Ok(p::ThreadListResponse {
        data,
        next_cursor: page.next_cursor,
        backwards_cursor,
    })
}

// ============================================================================
// thread/loaded/list
// ============================================================================

pub async fn handle_thread_loaded_list(
    state: &Arc<ConnectionState>,
    _params: p::ThreadLoadedListParams,
) -> p::ThreadLoadedListResponse {
    let mut data = state.claude_pool().loaded_thread_ids().await;
    data.retain(|id| !id.starts_with("utility_"));
    p::ThreadLoadedListResponse {
        data,
        next_cursor: None,
    }
}

// ============================================================================
// thread/read
// ============================================================================

pub async fn handle_thread_read(
    state: &Arc<ConnectionState>,
    params: p::ThreadReadParams,
) -> Result<p::ThreadReadResponse, ThreadError> {
    let entry = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;
    let mut thread = thread_from_entry(&entry);
    if params.include_turns {
        thread.turns = cached_thread_turns(state, &entry).await?;
    }
    let is_loaded = state
        .claude_pool()
        .loaded_thread_ids()
        .await
        .iter()
        .any(|id| id == &params.thread_id);
    apply_live_thread_status(&mut thread, is_loaded);
    Ok(p::ThreadReadResponse { thread })
}

// ============================================================================
// thread/turns/list
// ============================================================================

/// Turn 游标：turns 是一次性物化的有序向量，用 turn id 作位置锚点即可，
/// 不依赖 `started_at`（它允许为 None，用时间戳会在补写的历史上产生歧义）。
/// 编码方式与 thread 列表游标保持一致：base64url(JSON)。
fn encode_turn_cursor(turn_id: &str) -> String {
    let json = serde_json::json!({ "turnId": turn_id }).to_string();
    URL_SAFE_NO_PAD.encode(json)
}

fn decode_turn_cursor(raw: &str) -> Option<String> {
    let bytes = URL_SAFE_NO_PAD.decode(raw).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    value
        .get("turnId")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
}

pub async fn handle_thread_turns_list(
    state: &Arc<ConnectionState>,
    params: p::ThreadTurnsListParams,
) -> Result<p::ThreadTurnsListResponse, ThreadError> {
    let entry = state
        .thread_index()
        .lookup(&params.thread_id)
        .await
        .ok_or_else(|| ThreadError::NotFound(params.thread_id.clone()))?;
    let turns = cached_thread_turns(state, &entry).await?;
    Ok(paginate_turns(
        turns,
        params.cursor.as_deref(),
        params.limit,
        matches!(
            params.sort_direction.unwrap_or(p::SortDirection::Desc),
            p::SortDirection::Desc
        ),
    ))
}

/// turns 的游标分页。抽成纯函数便于覆盖跨页边界，handler 只负责取数据。
fn paginate_turns(
    mut turns: Vec<p::Turn>,
    cursor: Option<&str>,
    limit: Option<u32>,
    descending: bool,
) -> p::ThreadTurnsListResponse {
    if descending {
        turns.reverse();
    }

    // 游标定位到锚点之后一位。锚点不在本次结果里（turn 被截断或 id 变了）时返回
    // 空页且不再给 next_cursor，让调用方干净收敛，而不是从头重发导致重复。
    let start = match cursor.filter(|c| !c.is_empty()) {
        Some(raw) => {
            let Some(anchor) = decode_turn_cursor(raw) else {
                return p::ThreadTurnsListResponse::default();
            };
            match turns.iter().position(|turn| turn.id == anchor) {
                Some(index) => index + 1,
                None => return p::ThreadTurnsListResponse::default(),
            }
        }
        None => 0,
    };
    if start >= turns.len() {
        return p::ThreadTurnsListResponse::default();
    }

    // limit 只决定单页大小；它过去被当成"只保留最新 N 轮"，早期历史因此永远取不到。
    let limit = alleycat_bridge_core::resolve_list_limit(limit) as usize;
    let end = turns.len().min(start + limit);
    let has_more = end < turns.len();
    let page: Vec<p::Turn> = turns[start..end].to_vec();

    let next_cursor = if has_more {
        page.last().map(|turn| encode_turn_cursor(&turn.id))
    } else {
        None
    };
    // backwards_cursor 指向本页第一条：调用方带着它反向请求可以回到上一页边界。
    let backwards_cursor = if start > 0 {
        page.first().map(|turn| encode_turn_cursor(&turn.id))
    } else {
        None
    };

    p::ThreadTurnsListResponse {
        data: page,
        next_cursor,
        backwards_cursor,
    }
}

// ============================================================================
// thread/backgroundTerminals/clean
// ============================================================================

pub async fn handle_thread_background_terminals_clean(
    _state: &Arc<ConnectionState>,
    _params: p::ThreadBackgroundTerminalsCleanParams,
) -> p::ThreadBackgroundTerminalsCleanResponse {
    p::ThreadBackgroundTerminalsCleanResponse::default()
}

// ============================================================================
// helpers
// ============================================================================

fn resolve_cwd(requested: Option<&str>) -> Result<PathBuf, ThreadError> {
    match requested {
        Some(path) if !path.is_empty() => Ok(PathBuf::from(path)),
        _ => std::env::current_dir().map_err(|e| {
            ThreadError::InvalidParams(format!("cwd not provided and bridge cwd unavailable: {e}"))
        }),
    }
}

pub(crate) fn resume_cwd_or_fallback(
    persisted: &str,
    thread_id: &str,
    trust_persisted_cwd: bool,
) -> PathBuf {
    let original = PathBuf::from(persisted);
    if trust_persisted_cwd || original.is_dir() {
        return original;
    }
    let fallback = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    tracing::warn!(
        thread_id,
        original = %original.display(),
        fallback = %fallback.display(),
        "persisted thread cwd is missing; falling back to home dir"
    );
    fallback
}

/// 本地空会话只写入索引，首个 turn 再承担 Claude CLI 冷启动成本。
/// 远程 launcher 和带线程级配置的调用仍保持预启动，避免改变既有参数语义。
fn should_defer_process_start(
    state: &ConnectionState,
    model: &Option<String>,
    system_prompt: &Option<String>,
) -> bool {
    !state.trust_persisted_cwd() && model.is_none() && system_prompt.is_none()
}

async fn transcript_turns(
    state: &Arc<ConnectionState>,
    path: &Path,
) -> Result<Vec<p::Turn>, ThreadError> {
    if state.trust_persisted_cwd() {
        let text = read_transcript_via_launcher(state, path).await?;
        return Ok(messages_text_to_turns(&text));
    }
    messages_to_turns(path).await.map_err(ThreadError::from)
}

/// Claude JSONL 是跨 App/bridge 重启的权威历史，内存日志负责补上当前进程
/// 尚未 flush 的实时事件。每次 read/resume/turns-list 都尝试对账；磁盘已
/// 落下的成功 terminal 可以修复 live cache 漏项，但不能覆盖运行中或失败状态。
pub(super) async fn cached_thread_turns(
    state: &Arc<ConnectionState>,
    entry: &IndexEntry,
) -> Result<Vec<p::Turn>, ThreadError> {
    let live = state.thread_log(&entry.thread_id);
    let persisted = match transcript_turns(state, &entry.metadata.claude_session_path).await {
        Ok(turns) => turns,
        Err(err) if !live.is_empty() => {
            tracing::warn!(
                thread_id = %entry.thread_id,
                live_turns = live.len(),
                error = %err,
                "claude transcript reconciliation failed; serving live cache"
            );
            return Ok(live);
        }
        Err(err) => return Err(err),
    };
    let report = state.reconcile_thread_log(&entry.thread_id, persisted);
    if report.seeded_turns > 0
        || report.repaired_turns > 0
        || report.protected_turns > 0
        || report.reanchored_turns > 0
    {
        tracing::info!(
            thread_id = %entry.thread_id,
            live_turns = report.live_turns,
            persisted_turns = report.persisted_turns,
            seeded_turns = report.seeded_turns,
            repaired_turns = report.repaired_turns,
            protected_turns = report.protected_turns,
            reanchored_turns = report.reanchored_turns,
            "reconciled claude transcript with live thread cache"
        );
    }
    Ok(state.thread_log(&entry.thread_id))
}

async fn transcript_user_message_ids(
    state: &Arc<ConnectionState>,
    path: &Path,
) -> Result<Vec<String>, ThreadError> {
    if state.trust_persisted_cwd() {
        let text = read_transcript_via_launcher(state, path).await?;
        return Ok(list_user_message_ids_from_text(&text));
    }
    list_user_message_ids(path)
        .await
        .map_err(|e| ThreadError::ClaudeRpc(format!("reading transcript: {e:#}")))
}

/// Best-effort scan of a thread's on-disk transcript for the most recent
/// assistant `model`. Errors and missing files become `None` — this is only
/// used to seed a response field, never to gate the request.
async fn transcript_model(state: &Arc<ConnectionState>, path: &Path) -> Option<String> {
    if state.trust_persisted_cwd() {
        let text = read_transcript_via_launcher(state, path).await.ok()?;
        return last_assistant_model_from_text(&text);
    }
    last_assistant_model(path).await.ok().flatten()
}

async fn read_transcript_via_launcher(
    state: &Arc<ConnectionState>,
    path: &Path,
) -> Result<String, ThreadError> {
    let Some(launcher) = state.launcher() else {
        return Err(ThreadError::ClaudeRpc(
            "remote transcript read requested without a launcher".to_string(),
        ));
    };

    let mut spec = ProcessSpec::new("cat");
    spec.role = ProcessRole::ToolCommand;
    spec.args.push(path.as_os_str().to_os_string());
    spec.stdin = StdioMode::Null;
    spec.stdout = StdioMode::Piped;
    spec.stderr = StdioMode::Piped;

    let mut child = launcher
        .launch(spec)
        .await
        .map_err(|e| ThreadError::ClaudeRpc(format!("launch transcript read: {e}")))?;
    let mut stdout = child
        .take_stdout()
        .ok_or_else(|| ThreadError::ClaudeRpc("transcript read stdout unavailable".to_string()))?;
    let mut out = Vec::new();
    stdout
        .read_to_end(&mut out)
        .await
        .map_err(|e| ThreadError::ClaudeRpc(format!("read transcript stdout: {e}")))?;

    let mut err = Vec::new();
    if let Some(mut stderr) = child.take_stderr() {
        stderr
            .read_to_end(&mut err)
            .await
            .map_err(|e| ThreadError::ClaudeRpc(format!("read transcript stderr: {e}")))?;
    }

    let status = child
        .wait()
        .await
        .map_err(|e| ThreadError::ClaudeRpc(format!("wait transcript read: {e}")))?;
    if !status.success() {
        let stderr = String::from_utf8_lossy(&err);
        tracing::warn!(
            path = %path.display(),
            status = ?status,
            stderr = %stderr.trim(),
            "claude transcript read over launcher failed"
        );
        return Ok(String::new());
    }

    Ok(String::from_utf8_lossy(&out).into_owned())
}

fn now_unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn thread_from_entry(entry: &IndexEntry) -> p::Thread {
    crate::index::entry_to_thread(entry)
}

/// 磁盘索引不知道常驻 Claude 进程是否正在执行。所有 thread 查询必须以
/// live active-turn registry 为准，否则 App 会把运行会话当成 idle 并再次 start。
fn apply_live_thread_status(thread: &mut p::Thread, is_loaded: bool) {
    if crate::handlers::turn::active_turn_id(&thread.id).is_some() {
        thread.status = p::ThreadStatus::Active {
            active_flags: Vec::new(),
        };
    } else if is_loaded {
        thread.status = p::ThreadStatus::Idle;
    }
}

/// Default `permissionProfile` matching codex's `{type: "disabled"}` shape
/// for threads with no named profile. claude doesn't expose a profile
/// system; emitting null leaves codex clients rendering "unconfigured",
/// which mismatches the rest of the spec.
fn default_permission_profile() -> p::PermissionProfile {
    serde_json::json!({ "type": "disabled" })
}

/// `serviceTier` is the OpenAI account tier flag (upstream schema enum is
/// `"fast" | "flex" | null`). claude has no equivalent — `null` is the
/// correct shape, and bridges should not invent an enum value the spec
/// doesn't define.
fn default_service_tier() -> p::ServiceTier {
    serde_json::Value::Null
}

fn sandbox_value(mode: Option<p::SandboxMode>) -> p::SandboxPolicy {
    match mode {
        Some(p::SandboxMode::ReadOnly) => serde_json::json!({ "type": "readOnly" }),
        Some(p::SandboxMode::DangerFullAccess) => {
            serde_json::json!({ "type": "dangerFullAccess" })
        }
        Some(p::SandboxMode::WorkspaceWrite) | None => {
            serde_json::json!({ "type": "workspaceWrite" })
        }
    }
}

fn parse_cwd_filter(value: &Option<serde_json::Value>) -> Option<Vec<String>> {
    let v = value.as_ref()?;
    match v {
        serde_json::Value::String(s) => Some(vec![s.clone()]),
        serde_json::Value::Array(arr) => Some(
            arr.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect(),
        ),
        _ => None,
    }
}

fn effort_from_params(
    additional: &std::collections::HashMap<String, serde_json::Value>,
) -> Option<p::ReasoningEffort> {
    additional.get("effort").and_then(parse_effort)
}

fn parse_effort(value: &serde_json::Value) -> Option<p::ReasoningEffort> {
    match value.as_str()? {
        "minimal" => Some(p::ReasoningEffort::Minimal),
        "low" => Some(p::ReasoningEffort::Low),
        "medium" => Some(p::ReasoningEffort::Medium),
        "high" => Some(p::ReasoningEffort::High),
        "xhigh" => Some(p::ReasoningEffort::XHigh),
        "max" => Some(p::ReasoningEffort::Max),
        _ => None,
    }
}

/// Mirror claude's on-disk session-file convention:
/// `~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`.
fn claude_session_path_for(cwd: &std::path::Path, session_id: &str) -> PathBuf {
    let encoded = encode_cwd(cwd);
    let mut path =
        crate::index::claude_projects_dir().unwrap_or_else(|| PathBuf::from(".claude/projects"));
    path.push(encoded);
    path.push(format!("{session_id}.jsonl"));
    path
}

/// Encode a cwd the way claude does on disk:
///  - canonicalize so macOS `/var/...` resolves to `/private/var/...` (claude
///    does this on its side; without it, sessions written to a tempdir under
///    `/var/folders/...` won't match the bridge's lookup path);
///  - then replace every non-alphanumeric byte with `-` (claude's actual
///    rule — `/T/.tmp` becomes `-T--tmp`, not `-T-.tmp`).
fn encode_cwd(cwd: &std::path::Path) -> String {
    let canonical = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let s = canonical.to_string_lossy();
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
        } else {
            out.push('-');
        }
    }
    out
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

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(id: &str) -> p::Turn {
        p::Turn {
            id: id.to_string(),
            items: Vec::new(),
            items_view: p::default_items_view(),
            status: p::TurnStatus::Completed,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        }
    }

    fn turns(count: usize) -> Vec<p::Turn> {
        (0..count).map(|i| turn(&format!("turn-{i}"))).collect()
    }

    fn ids(response: &p::ThreadTurnsListResponse) -> Vec<String> {
        response.data.iter().map(|t| t.id.clone()).collect()
    }

    /// MIM-251：limit 只是单页大小。回归前它等价于"只保留最新 N 轮"，
    /// 早期历史因此永远取不到。
    #[test]
    fn paginate_turns_walks_every_turn_without_gaps_or_repeats() {
        let all = turns(23);
        let mut seen: Vec<String> = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..10 {
            let page = paginate_turns(all.clone(), cursor.as_deref(), Some(5), true);
            assert!(!page.data.is_empty(), "分页不得在走完之前返回空页");
            seen.extend(ids(&page));
            match page.next_cursor {
                Some(next) => cursor = Some(next),
                None => break,
            }
        }
        // 倒序：最新的 turn-22 在最前，一路翻到最早的 turn-0
        let expected: Vec<String> = (0..23).rev().map(|i| format!("turn-{i}")).collect();
        assert_eq!(seen, expected, "必须无重复无跳段地覆盖全部 23 轮");
    }

    #[test]
    fn paginate_turns_reports_cursors_at_page_boundaries() {
        let all = turns(7);
        let first = paginate_turns(all.clone(), None, Some(3), true);
        assert_eq!(ids(&first), ["turn-6", "turn-5", "turn-4"]);
        assert!(first.next_cursor.is_some(), "还有更多时必须给 next_cursor");
        assert!(
            first.backwards_cursor.is_none(),
            "首页没有上一页，不应给 backwards_cursor"
        );

        let second = paginate_turns(all.clone(), first.next_cursor.as_deref(), Some(3), true);
        assert_eq!(ids(&second), ["turn-3", "turn-2", "turn-1"]);
        assert!(
            second.backwards_cursor.is_some(),
            "非首页必须给 backwards_cursor 以便回翻"
        );

        let last = paginate_turns(all, second.next_cursor.as_deref(), Some(3), true);
        assert_eq!(ids(&last), ["turn-0"]);
        assert!(
            last.next_cursor.is_none(),
            "走到最早一轮后不得再给 next_cursor"
        );
    }

    #[test]
    fn paginate_turns_respects_ascending_order() {
        let page = paginate_turns(turns(4), None, Some(2), false);
        assert_eq!(ids(&page), ["turn-0", "turn-1"]);
    }

    #[test]
    fn paginate_turns_terminates_on_unknown_or_invalid_cursor() {
        // 锚点已不在结果里（历史被截断/重写）时必须干净收敛，不能从头重发造成重复。
        let stale = encode_turn_cursor("turn-does-not-exist");
        let page = paginate_turns(turns(3), Some(&stale), Some(2), true);
        assert!(page.data.is_empty());
        assert!(page.next_cursor.is_none());

        let garbage = paginate_turns(turns(3), Some("!!!not-base64!!!"), Some(2), true);
        assert!(garbage.data.is_empty());
        assert!(garbage.next_cursor.is_none());
    }

    #[test]
    fn paginate_turns_handles_empty_thread() {
        let page = paginate_turns(Vec::new(), None, Some(5), true);
        assert!(page.data.is_empty());
        assert!(page.next_cursor.is_none());
        assert!(page.backwards_cursor.is_none());
    }

    #[test]
    fn turn_cursor_round_trips() {
        assert_eq!(
            decode_turn_cursor(&encode_turn_cursor("turn-42")).as_deref(),
            Some("turn-42")
        );
    }

    #[test]
    fn encode_cwd_strips_slashes() {
        assert_eq!(
            encode_cwd(std::path::Path::new("/Users/me/dev/proj")),
            "-Users-me-dev-proj"
        );
    }

    #[test]
    fn parse_cwd_filter_handles_string_array_null() {
        use serde_json::json;
        assert_eq!(
            parse_cwd_filter(&Some(json!("/repo"))),
            Some(vec!["/repo".to_string()])
        );
        assert_eq!(
            parse_cwd_filter(&Some(json!(["/a", "/b"]))),
            Some(vec!["/a".to_string(), "/b".to_string()])
        );
        assert_eq!(parse_cwd_filter(&None), None);
        assert_eq!(parse_cwd_filter(&Some(json!(null))), None);
    }

    #[test]
    fn sandbox_value_round_trips_each_mode() {
        use serde_json::json;
        assert_eq!(
            sandbox_value(Some(p::SandboxMode::ReadOnly)),
            json!({"type": "readOnly"})
        );
        assert_eq!(
            sandbox_value(Some(p::SandboxMode::DangerFullAccess)),
            json!({"type": "dangerFullAccess"})
        );
        assert_eq!(sandbox_value(None), json!({"type": "workspaceWrite"}));
    }

    #[test]
    fn parse_effort_recognizes_codex_levels() {
        use serde_json::json;
        assert!(matches!(
            parse_effort(&json!("minimal")),
            Some(p::ReasoningEffort::Minimal)
        ));
        assert!(matches!(
            parse_effort(&json!("xhigh")),
            Some(p::ReasoningEffort::XHigh)
        ));
        assert!(matches!(
            parse_effort(&json!("max")),
            Some(p::ReasoningEffort::Max)
        ));
        assert!(parse_effort(&json!(42)).is_none());
    }

    #[test]
    fn rollback_rejects_zero_turns() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let err = handle_thread_rollback(
                &dummy_state().await,
                p::ThreadRollbackParams {
                    thread_id: "t".into(),
                    num_turns: 0,
                },
            )
            .await
            .unwrap_err();
            assert!(matches!(err, ThreadError::InvalidParams(_)));
            assert_eq!(err.rpc_code(), p::error_codes::INVALID_PARAMS);
        });
    }

    #[test]
    fn rollback_rejects_unknown_thread() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let err = handle_thread_rollback(
                &dummy_state().await,
                p::ThreadRollbackParams {
                    thread_id: "ghost".into(),
                    num_turns: 1,
                },
            )
            .await
            .unwrap_err();
            assert!(matches!(err, ThreadError::NotFound(_)));
            assert_eq!(err.rpc_code(), p::error_codes::INVALID_PARAMS);
        });
    }

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
}
