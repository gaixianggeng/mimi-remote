//! Per-connection state for `claude-bridge`.
//!
//! One `ConnectionState` exists per connected codex client (keyed by session
//! id on the bridge). Handlers borrow it through `Arc<ConnectionState>`;
//! mutable bits live behind their own locks rather than wrapping the whole
//! struct in a `Mutex`, so a long-running turn does not block unrelated
//! requests.

use std::cmp::Reverse;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::RwLock;

use alleycat_bridge_core::ProcessLauncher;
use alleycat_bridge_core::session::Session;
use serde_json::Value;
use tokio::sync::oneshot;

use alleycat_codex_proto::{
    ApprovalsReviewer, AskForApproval, InitializeCapabilities, JsonRpcMessage, RateLimitSnapshot,
    ReasoningEffort, RequestId, SandboxMode, ThreadItem, Turn, TurnError, TurnStatus,
};

use crate::index::{ClaudeHistoryRefresher, ClaudeSessionRef};
use crate::pool::ClaudePool;
use crate::pool::claude_protocol::{McpServerInit, RateLimitInfo, SystemInit};
use crate::translate::items::normalize_dynamic_tool_call_output;

/// Compat re-export so the daemon's
/// `Arc<dyn alleycat_claude_bridge::state::ThreadIndexHandle>` keeps spelling
/// the right trait. Goes away in A5 once the daemon adopts the builder API.
///
/// Implementors specialize on [`ClaudeSessionRef`]; the supertrait constraint
/// pins the metadata so the daemon doesn't need to spell it.
pub trait ThreadIndexHandle: alleycat_bridge_core::ThreadIndexHandle<ClaudeSessionRef> {}

impl<T> ThreadIndexHandle for T where
    T: alleycat_bridge_core::ThreadIndexHandle<ClaudeSessionRef> + ?Sized
{
}

pub use crate::index::{IndexEntry, ListFilter, ListPage, ListSort};

/// Per-connection bridge state. Cheap to clone via `Arc`.
pub struct ConnectionState {
    defaults: Mutex<ThreadDefaults>,
    /// 当前可交付通知的 bridge session。
    ///
    /// `ConnectionState` 会跨 WebSocket 连接复用，而 bridge-core 在长时间
    /// 离线后可能为同一个稳定 session key 创建新的 `Session`。这里必须
    /// 可重新绑定，否则后台 runtime 仍会把事件写进已经脱离 registry 的
    /// 旧 replay ring。
    session: RwLock<Arc<Session>>,
    claude_pool: Arc<ClaudePool>,
    thread_index: Arc<dyn ThreadIndexHandle>,
    /// 仅生产 builder 注入；旧的测试 helper 沿用 `None`，普通列表行为不变。
    history_refresher: Option<Arc<ClaudeHistoryRefresher>>,
    /// Launcher used for `command/exec` shell tools. `None` falls back to a
    /// bridge-default [`alleycat_bridge_core::LocalLauncher`] (preserves the
    /// pre-refactor behavior of the legacy `for_test` helper).
    launcher: Option<Arc<dyn ProcessLauncher>>,
    /// Trust indexed thread cwd values without checking local filesystem
    /// existence. Embedders that run the agent somewhere else, like Litter's
    /// SSH launcher, need the cwd to be validated by that remote process.
    trust_persisted_cwd: bool,
    caches: Mutex<ClaudeCaches>,
    oauth_rate_limit_refresh: tokio::sync::Mutex<()>,
    thread_logs: Mutex<HashMap<String, Vec<RecordedTurn>>>,
}

/// One turn's worth of items captured live from the event pump.
#[derive(Debug, Clone)]
pub struct RecordedTurn {
    pub turn_id: String,
    pub started_at: i64,
    pub completed_at: Option<i64>,
    pub status: TurnStatus,
    pub error: Option<TurnError>,
    pub items: Vec<ThreadItem>,
}

pub use alleycat_bridge_core::state::Capabilities;

/// Bridge defaults for a new thread. Seeded on construction and overrideable
/// per-`thread/start` request via `ThreadStartParams`.
#[derive(Debug, Clone, Default)]
pub struct ThreadDefaults {
    pub model: Option<String>,
    pub model_provider: Option<String>,
    pub reasoning_effort: Option<ReasoningEffort>,
    pub approval_policy: Option<AskForApproval>,
    pub approvals_reviewer: Option<ApprovalsReviewer>,
    pub sandbox: Option<SandboxMode>,
    pub service_name: Option<String>,
    pub system_prompt: Option<String>,
}

/// Bridge-wide caches refreshed from claude wire events.
#[derive(Debug, Clone, Default)]
pub struct ClaudeCaches {
    pub last_init: Option<SystemInit>,
    pub mcp_servers: Vec<McpServerInit>,
    pub skills: Vec<String>,
    pub slash_commands: Vec<String>,
    pub agents: Vec<String>,
    /// Claude 每次事件只携带一个窗口；按类型缓存，避免 5h/7d 连续到达时
    /// 后一个把前一个覆盖掉。
    pub rate_limit_infos: HashMap<String, RateLimitInfo>,
    /// OAuth usage 主动查询的短缓存。只保存百分比与重置时间，不保存凭据。
    pub oauth_rate_limit: Option<CachedOAuthRateLimit>,
    /// 失败也短暂退避，避免设置页并发刷新连续访问 Keychain/OAuth endpoint。
    pub oauth_last_attempt_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct CachedOAuthRateLimit {
    pub snapshot: RateLimitSnapshot,
    pub fetched_at: i64,
}

impl ClaudeCaches {
    pub fn refresh_rate_limit(&mut self, info: RateLimitInfo) -> Option<Vec<RateLimitInfo>> {
        let key = info
            .rate_limit_type
            .clone()
            .unwrap_or_else(|| "unknown".into());

        // Claude 可能在同一轮里重复发送完全相同的 allowed_warning。
        // 快照没有变化时不再广播 account/rateLimits/updated，避免上层把
        // 同一条“接近限额”状态反复渲染成提示。
        if self.rate_limit_infos.get(&key) == Some(&info) {
            return None;
        }

        self.rate_limit_infos.insert(key, info);
        Some(self.rate_limit_infos.values().cloned().collect())
    }

    pub fn cached_oauth_rate_limit(
        &self,
        now: i64,
        max_age_secs: i64,
    ) -> Option<RateLimitSnapshot> {
        self.oauth_rate_limit.as_ref().and_then(|cached| {
            (now.saturating_sub(cached.fetched_at) <= max_age_secs).then(|| cached.snapshot.clone())
        })
    }

    pub fn begin_oauth_rate_limit_refresh(&mut self, now: i64, min_interval_secs: i64) -> bool {
        if self
            .oauth_last_attempt_at
            .is_some_and(|last| now.saturating_sub(last) < min_interval_secs)
        {
            return false;
        }
        self.oauth_last_attempt_at = Some(now);
        true
    }

    pub fn store_oauth_rate_limit(&mut self, snapshot: RateLimitSnapshot, fetched_at: i64) {
        self.oauth_rate_limit = Some(CachedOAuthRateLimit {
            snapshot,
            fetched_at,
        });
    }
}

#[derive(Debug, Clone)]
pub enum ServerRequestError {
    Rpc { code: i64, message: String },
    ConnectionClosed,
    TimedOut,
}

impl From<alleycat_bridge_core::state::ServerRequestError> for ServerRequestError {
    fn from(value: alleycat_bridge_core::state::ServerRequestError) -> Self {
        match value {
            alleycat_bridge_core::state::ServerRequestError::Rpc(err) => Self::Rpc {
                code: err.code,
                message: err.message,
            },
            alleycat_bridge_core::state::ServerRequestError::ConnectionClosed => {
                Self::ConnectionClosed
            }
            alleycat_bridge_core::state::ServerRequestError::TimedOut => Self::TimedOut,
        }
    }
}

impl ConnectionState {
    pub fn new(
        session: Arc<Session>,
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
    ) -> Self {
        Self::with_launcher(session, claude_pool, thread_index, defaults, None, false)
    }

    pub fn with_launcher(
        session: Arc<Session>,
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
        launcher: Option<Arc<dyn ProcessLauncher>>,
        trust_persisted_cwd: bool,
    ) -> Self {
        Self::with_launcher_and_history_refresher(
            session,
            claude_pool,
            thread_index,
            defaults,
            launcher,
            trust_persisted_cwd,
            None,
        )
    }

    pub fn with_launcher_and_history_refresher(
        session: Arc<Session>,
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
        launcher: Option<Arc<dyn ProcessLauncher>>,
        trust_persisted_cwd: bool,
        history_refresher: Option<Arc<ClaudeHistoryRefresher>>,
    ) -> Self {
        Self {
            defaults: Mutex::new(defaults),
            session: RwLock::new(session),
            claude_pool,
            thread_index,
            history_refresher,
            launcher,
            trust_persisted_cwd,
            caches: Mutex::new(ClaudeCaches::default()),
            oauth_rate_limit_refresh: tokio::sync::Mutex::new(()),
            thread_logs: Mutex::new(HashMap::new()),
        }
    }

    pub fn launcher(&self) -> Option<&Arc<dyn ProcessLauncher>> {
        self.launcher.as_ref()
    }

    pub fn trust_persisted_cwd(&self) -> bool {
        self.trust_persisted_cwd
    }

    pub fn history_refresher(&self) -> Option<&Arc<ClaudeHistoryRefresher>> {
        self.history_refresher.as_ref()
    }

    pub fn session(&self) -> Arc<Session> {
        Arc::clone(&self.session.read().unwrap())
    }

    /// 将长期存活的 runtime 状态重新绑定到本次 attach 解析出的 session。
    /// 已存在的事件驱动器只持有 `ConnectionState`，所以后续通知会自动发往
    /// 新 ring，而不需要跟随页面或 WebSocket 重建。
    pub fn rebind_session(&self, session: Arc<Session>) {
        let mut current = self.session.write().unwrap();
        if !Arc::ptr_eq(&current, &session) {
            *current = session;
        }
    }

    pub fn set_capabilities(
        &self,
        client_name: Option<String>,
        client_title: Option<String>,
        client_version: Option<String>,
        caps: Option<&InitializeCapabilities>,
    ) {
        let opt_out = caps
            .and_then(|c| c.opt_out_notification_methods.as_ref())
            .map(|v| v.iter().cloned().collect())
            .unwrap_or_default();
        self.session().set_capabilities(Capabilities {
            experimental_api: caps.is_some_and(|c| c.experimental_api),
            opt_out_notification_methods: opt_out,
            client_name,
            client_title,
            client_version,
        });
    }

    pub fn capabilities(&self) -> Capabilities {
        self.session().capabilities()
    }

    pub fn should_emit(&self, method: &str) -> bool {
        self.session().should_emit(method)
    }

    pub fn defaults(&self) -> ThreadDefaults {
        self.defaults.lock().unwrap().clone()
    }

    pub fn update_defaults(&self, f: impl FnOnce(&mut ThreadDefaults)) {
        let mut slot = self.defaults.lock().unwrap();
        f(&mut slot);
    }

    pub fn send(&self, msg: JsonRpcMessage) -> Result<(), SendError> {
        match serde_json::to_value(&msg) {
            Ok(value) => {
                self.session().enqueue(value);
                Ok(())
            }
            Err(_) => Err(SendError::ConnectionClosed),
        }
    }

    /// Register a server→client request and put its frame on the wire in one
    /// step. See [`Session::publish_server_request`]: registering first and
    /// sending after leaves a window where a reattach delivers the prompt
    /// twice.
    pub async fn publish_server_request(
        &self,
        request_id: RequestId,
        method: String,
        params: Value,
        frame: JsonRpcMessage,
    ) -> Result<oneshot::Receiver<Result<Value, ServerRequestError>>, SendError> {
        let payload = serde_json::to_value(&frame).map_err(|_| SendError::ConnectionClosed)?;
        let (tx, rx) = oneshot::channel();
        let key = request_id.to_string();
        let (core_tx, core_rx) =
            oneshot::channel::<Result<Value, alleycat_bridge_core::state::ServerRequestError>>();
        self.session()
            .publish_server_request(key, method, params, core_tx, payload);
        tokio::spawn(async move {
            let mapped = match core_rx.await {
                Ok(Ok(v)) => Ok(v),
                Ok(Err(e)) => Err(e.into()),
                Err(_) => Err(ServerRequestError::ConnectionClosed),
            };
            let _ = tx.send(mapped);
        });
        Ok(rx)
    }

    pub async fn register_pending_request(
        &self,
        request_id: RequestId,
        method: String,
        params: Value,
    ) -> oneshot::Receiver<Result<Value, ServerRequestError>> {
        let (tx, rx) = oneshot::channel();
        let key = request_id.to_string();
        let (core_tx, core_rx) =
            oneshot::channel::<Result<Value, alleycat_bridge_core::state::ServerRequestError>>();
        self.session()
            .register_pending(key, method, params, core_tx);
        tokio::spawn(async move {
            let mapped = match core_rx.await {
                Ok(Ok(v)) => Ok(v),
                Ok(Err(e)) => Err(e.into()),
                Err(_) => Err(ServerRequestError::ConnectionClosed),
            };
            let _ = tx.send(mapped);
        });
        rx
    }

    pub async fn resolve_pending_request(
        &self,
        request_id: &RequestId,
        result: Result<Value, ServerRequestError>,
    ) -> bool {
        let mapped: Result<Value, alleycat_bridge_core::state::ServerRequestError> = match result {
            Ok(v) => Ok(v),
            Err(ServerRequestError::Rpc { code, message }) => {
                Err(alleycat_bridge_core::state::ServerRequestError::Rpc(
                    alleycat_bridge_core::JsonRpcError {
                        code,
                        message,
                        data: None,
                    },
                ))
            }
            Err(ServerRequestError::ConnectionClosed) => {
                Err(alleycat_bridge_core::state::ServerRequestError::ConnectionClosed)
            }
            Err(ServerRequestError::TimedOut) => {
                Err(alleycat_bridge_core::state::ServerRequestError::TimedOut)
            }
        };
        self.session()
            .resolve_pending(&request_id.to_string(), mapped)
    }

    pub async fn cancel_all_pending_requests(&self) {
        self.session().cancel_all_pending();
    }

    pub fn claude_pool(&self) -> &Arc<ClaudePool> {
        &self.claude_pool
    }

    pub fn thread_index(&self) -> &Arc<dyn ThreadIndexHandle> {
        &self.thread_index
    }

    pub fn caches(&self) -> ClaudeCaches {
        self.caches.lock().unwrap().clone()
    }

    pub fn refresh_init_cache(&self, init: SystemInit) {
        let mut slot = self.caches.lock().unwrap();
        slot.mcp_servers = init.mcp_servers.clone();
        slot.skills = init.skills.clone();
        slot.slash_commands = init.slash_commands.clone();
        slot.agents = init.agents.clone();
        slot.last_init = Some(init);
    }

    pub fn refresh_rate_limit_cache(&self, info: RateLimitInfo) -> Option<Vec<RateLimitInfo>> {
        let mut slot = self.caches.lock().unwrap();
        slot.refresh_rate_limit(info)
    }

    pub fn cached_oauth_rate_limit(
        &self,
        now: i64,
        max_age_secs: i64,
    ) -> Option<RateLimitSnapshot> {
        self.caches
            .lock()
            .unwrap()
            .cached_oauth_rate_limit(now, max_age_secs)
    }

    pub async fn lock_oauth_rate_limit_refresh(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.oauth_rate_limit_refresh.lock().await
    }

    pub fn begin_oauth_rate_limit_refresh(&self, now: i64, min_interval_secs: i64) -> bool {
        self.caches
            .lock()
            .unwrap()
            .begin_oauth_rate_limit_refresh(now, min_interval_secs)
    }

    pub fn store_oauth_rate_limit(&self, snapshot: RateLimitSnapshot, fetched_at: i64) {
        self.caches
            .lock()
            .unwrap()
            .store_oauth_rate_limit(snapshot, fetched_at);
    }

    pub fn record_turn_started(&self, thread_id: &str, turn_id: String, started_at: i64) {
        let mut logs = self.thread_logs.lock().unwrap();
        let list = logs.entry(thread_id.to_string()).or_default();
        if list.iter().any(|turn| turn.turn_id == turn_id) {
            return;
        }
        list.push(RecordedTurn {
            turn_id,
            started_at,
            completed_at: None,
            status: TurnStatus::InProgress,
            error: None,
            items: Vec::new(),
        });
    }

    pub fn record_item(&self, thread_id: &str, turn_id: &str, item: ThreadItem) {
        let mut logs = self.thread_logs.lock().unwrap();
        let Some(list) = logs.get_mut(thread_id) else {
            return;
        };
        let Some(turn) = list.iter_mut().rev().find(|t| t.turn_id == turn_id) else {
            return;
        };
        let new_id = item.id().to_string();
        if let Some(idx) = turn
            .items
            .iter()
            .position(|existing| existing.id() == new_id)
        {
            turn.items[idx] = item;
        } else {
            turn.items.push(item);
        }
    }

    pub fn record_turn_completed(
        &self,
        thread_id: &str,
        turn_id: &str,
        completed_at: i64,
        status: TurnStatus,
        error: Option<TurnError>,
    ) {
        let mut logs = self.thread_logs.lock().unwrap();
        let Some(list) = logs.get_mut(thread_id) else {
            return;
        };
        if let Some(turn) = list.iter_mut().rev().find(|t| t.turn_id == turn_id) {
            turn.completed_at = Some(completed_at);
            turn.status = status;
            turn.error = error;
        }
    }

    /// 使用 Claude JSONL 权威历史修复 live cache。
    ///
    /// JSONL 没有可靠的失败/运行中 terminal 标记，所以只允许它补全已经成功
    /// `Completed` 的 live turn；`InProgress` / `Failed` / `Interrupted` 必须保留
    /// bridge 已观测到的状态，避免一次历史读取把真实失败伪装成成功。
    pub fn reconcile_thread_log(&self, thread_id: &str, persisted: Vec<Turn>) -> ReconcileReport {
        let mut logs = self.thread_logs.lock().unwrap();
        let slot = logs.entry(thread_id.to_string()).or_default();
        if persisted.is_empty() {
            return ReconcileReport {
                live_turns: slot.len(),
                ..Default::default()
            };
        }

        if slot.is_empty() {
            let seeded = persisted.len();
            *slot = persisted.into_iter().map(RecordedTurn::from).collect();
            return ReconcileReport {
                live_turns: 0,
                persisted_turns: seeded,
                seeded_turns: seeded,
                ..Default::default()
            };
        }

        let live_turns = slot.len();
        let persisted_turns = persisted.len();
        let mut matched_live = vec![false; slot.len()];
        let mut reconciled = Vec::with_capacity(slot.len().max(persisted.len()));
        let mut report = ReconcileReport {
            live_turns,
            persisted_turns,
            ..Default::default()
        };

        for persisted_turn in persisted {
            let matched = slot
                .iter()
                .enumerate()
                .filter(|(index, _)| !matched_live[*index])
                .filter_map(|(index, live)| {
                    let score = turn_match_score(&persisted_turn, live);
                    (score > 0).then_some((index, score))
                })
                .min_by_key(|(index, score)| (Reverse(*score), *index))
                .map(|(index, _)| index);

            if let Some(index) = matched {
                matched_live[index] = true;
                let mut live = slot[index].clone();
                if turn_user_key(&persisted_turn.items).is_some()
                    && turn_user_key(&live.items).is_none()
                {
                    report.reanchored_turns += 1;
                }
                if live.status == TurnStatus::Completed
                    && persisted_has_successful_output(&persisted_turn.items)
                {
                    let repaired = if !persisted_has_successful_output(&live.items)
                        && persisted_turn.items != live.items
                    {
                        // live 只有用户输入时，JSONL 的完整成功结果可以整体接管。
                        live.items = persisted_turn.items;
                        true
                    } else {
                        // live 已有部分输出时不能按数量或临时 item id 判断 superset。
                        // 只在可见内容构成严格顺序前缀时追加权威尾部：既补齐断流
                        // 后缺失的最终回复，也不会用较旧 JSONL 回滚更新的 live 内容。
                        append_strict_persisted_output_tail(&mut live.items, &persisted_turn.items)
                    };
                    if repaired {
                        report.repaired_turns += 1;
                    }
                } else if live.status != TurnStatus::Completed {
                    report.protected_turns += 1;
                }
                reconciled.push(live);
            } else {
                reconciled.push(RecordedTurn::from(persisted_turn));
                report.seeded_turns += 1;
            }
        }

        // JSONL flush 可能落后于实时事件；所有尚未在权威历史出现的 live turn
        // 按原顺序保留在尾部，其中也包括没有用户消息锚点的自主 turn。
        for (index, live) in slot.iter().enumerate() {
            if !matched_live[index] {
                reconciled.push(live.clone());
            }
        }
        *slot = reconciled;
        report
    }

    pub fn thread_log(&self, thread_id: &str) -> Vec<Turn> {
        let logs = self.thread_logs.lock().unwrap();
        let Some(list) = logs.get(thread_id) else {
            return Vec::new();
        };
        list.iter()
            .map(|t| {
                let started_at = t.started_at;
                let completed_at = t.completed_at;
                let duration_ms = completed_at.map(|end| ((end - started_at) * 1000).max(0));
                Turn {
                    id: t.turn_id.clone(),
                    items: t.items.clone(),
                    items_view: alleycat_codex_proto::default_items_view(),
                    status: t.status,
                    error: t.error.clone(),
                    started_at: Some(started_at),
                    completed_at,
                    duration_ms,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alleycat_codex_proto::UserInput;

    async fn test_state() -> Arc<ConnectionState> {
        let dir = tempfile::tempdir().unwrap();
        let index = alleycat_bridge_core::ThreadIndex::<crate::index::ClaudeSessionRef>::open_at(
            dir.path().join("threads.json"),
        )
        .await
        .unwrap();
        std::mem::forget(dir);
        ConnectionState::for_test(
            Arc::new(crate::pool::ClaudePool::new("/dev/null")),
            index,
            Default::default(),
        )
        .0
    }

    fn user(id: &str, text: &str) -> ThreadItem {
        ThreadItem::UserMessage {
            id: id.into(),
            content: vec![UserInput::Text {
                text: text.into(),
                text_elements: Vec::new(),
            }],
            client_id: None,
        }
    }

    fn persisted_turn(text: &str) -> Turn {
        Turn {
            id: "disk-turn".into(),
            items: vec![
                user("disk-user", text),
                ThreadItem::AgentMessage {
                    id: "disk-agent".into(),
                    text: "权威历史中的完整回复".into(),
                    phase: None,
                    memory_citation: None,
                },
            ],
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(1),
            completed_at: Some(2),
            duration_ms: Some(1_000),
        }
    }

    fn completed_turn(
        id: &str,
        user_text: Option<&str>,
        output: &str,
        started_at_ms: i64,
        completed_at_ms: i64,
    ) -> Turn {
        let mut items = Vec::new();
        if let Some(text) = user_text {
            items.push(user(&format!("{id}-user"), text));
        }
        items.push(ThreadItem::AgentMessage {
            id: format!("{id}-agent"),
            text: output.into(),
            phase: None,
            memory_citation: None,
        });
        Turn {
            id: id.into(),
            items,
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(started_at_ms),
            completed_at: Some(completed_at_ms),
            duration_ms: Some(completed_at_ms - started_at_ms),
        }
    }

    fn record_completed_live_turn(
        state: &ConnectionState,
        thread_id: &str,
        turn_id: &str,
        user_text: Option<&str>,
        output: &str,
        started_at: i64,
        completed_at: i64,
    ) {
        state.record_turn_started(thread_id, turn_id.into(), started_at);
        if let Some(text) = user_text {
            state.record_item(thread_id, turn_id, user(&format!("{turn_id}-user"), text));
        }
        state.record_item(
            thread_id,
            turn_id,
            ThreadItem::AgentMessage {
                id: format!("{turn_id}-agent"),
                text: output.into(),
                phase: None,
                memory_citation: None,
            },
        );
        state.record_turn_completed(
            thread_id,
            turn_id,
            completed_at,
            TurnStatus::Completed,
            None,
        );
    }

    #[tokio::test]
    async fn persisted_success_repairs_completed_live_turn() {
        let state = test_state().await;
        state.record_turn_started("thread", "live-turn".into(), 1);
        state.record_item("thread", "live-turn", user("live-user", "五分钟后回复"));
        state.record_turn_completed("thread", "live-turn", 2, TurnStatus::Completed, None);

        let report = state.reconcile_thread_log("thread", vec![persisted_turn("五分钟后回复")]);
        assert_eq!(report.repaired_turns, 1);
        let turns = state.thread_log("thread");
        assert_eq!(turns[0].id, "live-turn", "live turn id must stay stable");
        assert!(turns[0]
            .items
            .iter()
            .any(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text.contains("完整回复"))));
    }

    #[tokio::test]
    async fn persisted_completed_tail_repairs_partially_observed_live_output_without_duplicates() {
        let state = test_state().await;
        state.record_turn_started("thread", "live-partial".into(), 1);
        state.record_item(
            "thread",
            "live-partial",
            user("live-user", "检查历史一致性"),
        );
        state.record_item(
            "thread",
            "live-partial",
            ThreadItem::AgentMessage {
                id: "live-progress".into(),
                text: "先读取状态".into(),
                phase: None,
                memory_citation: None,
            },
        );
        state.record_item(
            "thread",
            "live-partial",
            ThreadItem::CommandExecution {
                id: "live-command".into(),
                command: "git status".into(),
                cwd: "/tmp".into(),
                process_id: None,
                source: Default::default(),
                status: alleycat_codex_proto::CommandExecutionStatus::Completed,
                command_actions: Vec::new(),
                aggregated_output: Some("工作区干净".into()),
                exit_code: Some(0),
                duration_ms: Some(10),
            },
        );
        state.record_turn_completed("thread", "live-partial", 2, TurnStatus::Completed, None);

        // 跨设备冷读时，live cache 可能已有部分成功输出，而 JSONL 才包含完整尾部；
        // 对账必须补齐权威历史，不能因为 live 已有成功 item 就跳过这次修复。
        let persisted = Turn {
            id: "disk-turn".into(),
            items: vec![
                user("disk-user", "检查历史一致性"),
                ThreadItem::AgentMessage {
                    id: "disk-progress".into(),
                    text: "先读取状态".into(),
                    phase: None,
                    memory_citation: None,
                },
                ThreadItem::CommandExecution {
                    id: "disk-command".into(),
                    command: "git status".into(),
                    cwd: "/tmp".into(),
                    process_id: None,
                    source: Default::default(),
                    status: alleycat_codex_proto::CommandExecutionStatus::Completed,
                    command_actions: Vec::new(),
                    aggregated_output: Some("工作区干净".into()),
                    exit_code: Some(0),
                    duration_ms: Some(10),
                },
                ThreadItem::AgentMessage {
                    id: "disk-final".into(),
                    text: "最终完整回复".into(),
                    phase: None,
                    memory_citation: None,
                },
            ],
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(1_000),
            completed_at: Some(2_000),
            duration_ms: Some(1_000),
        };

        let report = state.reconcile_thread_log("thread", vec![persisted]);
        let turns = state.thread_log("thread");
        assert_eq!(turns.len(), 1, "同一 user anchor 不应产生重复 turn");
        let items = &turns[0].items;
        assert_eq!(
            items
                .iter()
                .filter(|item| matches!(item, ThreadItem::UserMessage { content, .. } if content.iter().any(|input| matches!(input, UserInput::Text { text, .. } if text == "检查历史一致性"))))
                .count(),
            1,
            "同一 user anchor 只能保留一份"
        );
        assert_eq!(
            items
                .iter()
                .filter(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text == "先读取状态"))
                .count(),
            1,
            "已有 live assistant 输出只能保留一份"
        );
        assert_eq!(
            items
                .iter()
                .filter(|item| matches!(item, ThreadItem::CommandExecution { command, .. } if command == "git status"))
                .count(),
            1,
            "已有 live command execution 只能保留一份"
        );
        assert_eq!(
            items
                .iter()
                .filter(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text == "最终完整回复"))
                .count(),
            1,
            "persisted 最终 assistant 尾部必须补齐"
        );
        assert_eq!(report.seeded_turns, 0, "匹配到的 turn 不应重复 seed");
    }

    #[tokio::test]
    async fn persisted_completed_tail_includes_missing_file_change_before_final_message() {
        let state = test_state().await;
        record_completed_live_turn(
            &state,
            "thread",
            "live-partial",
            Some("修改配置"),
            "先检查配置",
            1,
            2,
        );

        let persisted = Turn {
            id: "disk-turn".into(),
            items: vec![
                user("disk-user", "修改配置"),
                ThreadItem::AgentMessage {
                    id: "disk-progress".into(),
                    text: "先检查配置".into(),
                    phase: None,
                    memory_citation: None,
                },
                ThreadItem::FileChange {
                    id: "disk-file-change".into(),
                    changes: vec![alleycat_codex_proto::FileUpdateChange {
                        path: "/tmp/config.json".into(),
                        kind: alleycat_codex_proto::PatchChangeKind::Update { move_path: None },
                        diff: "-old\n+new".into(),
                    }],
                    status: alleycat_codex_proto::PatchApplyStatus::Completed,
                },
                ThreadItem::AgentMessage {
                    id: "disk-final".into(),
                    text: "配置已更新".into(),
                    phase: None,
                    memory_citation: None,
                },
            ],
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(1_000),
            completed_at: Some(2_000),
            duration_ms: Some(1_000),
        };

        let report = state.reconcile_thread_log("thread", vec![persisted]);
        assert_eq!(report.repaired_turns, 1);
        let items = &state.thread_log("thread")[0].items;
        assert_eq!(
            items
                .iter()
                .filter(|item| matches!(item, ThreadItem::FileChange { .. }))
                .count(),
            1,
            "缺失的文件修改必须随 persisted 尾部一起补齐"
        );
        assert!(items.iter().any(
            |item| matches!(item, ThreadItem::AgentMessage { text, .. } if text == "配置已更新")
        ));
    }

    #[test]
    fn output_signatures_ignore_known_live_disk_representation_differences() {
        let dynamic_live = ThreadItem::DynamicToolCall {
            id: "live-dynamic".into(),
            namespace: Some("claude".into()),
            tool: "CustomTool".into(),
            arguments: serde_json::json!({"path": "/tmp/a"}),
            status: alleycat_codex_proto::DynamicToolCallStatus::Completed,
            content_items: Some(vec![serde_json::json!({
                "type": "text",
                "text": "done"
            })]),
            success: Some(true),
            duration_ms: Some(12),
        };
        let dynamic_disk = ThreadItem::DynamicToolCall {
            id: "disk-dynamic".into(),
            namespace: Some("claude".into()),
            tool: "CustomTool".into(),
            arguments: serde_json::json!({"path": "/tmp/a"}),
            status: alleycat_codex_proto::DynamicToolCallStatus::Completed,
            content_items: Some(vec![serde_json::json!({
                "type": "inputText",
                "text": "done"
            })]),
            success: Some(true),
            duration_ms: None,
        };
        assert_eq!(
            turn_output_signature(&dynamic_live),
            turn_output_signature(&dynamic_disk),
            "dynamic tool result 的 live/disk 包装差异不应破坏同一调用的前缀匹配"
        );
        let mut dynamic_diverged = dynamic_disk.clone();
        if let ThreadItem::DynamicToolCall { content_items, .. } = &mut dynamic_diverged {
            *content_items = Some(vec![serde_json::json!({
                "type": "inputText",
                "text": "different result"
            })]);
        }
        assert_ne!(
            turn_output_signature(&dynamic_live),
            turn_output_signature(&dynamic_diverged),
            "相同参数但真实结果不同的 dynamic call 必须阻止旧尾部拼接"
        );

        let mcp_live = ThreadItem::McpToolCall {
            id: "live-mcp".into(),
            server: "server".into(),
            tool: "lookup".into(),
            status: alleycat_codex_proto::McpToolCallStatus::Completed,
            arguments: serde_json::json!({"query": "MIM-47"}),
            mcp_app_resource_uri: None,
            result: Some(Box::new(alleycat_codex_proto::McpToolCallResult {
                content: vec![serde_json::json!({"type": "text", "text": "new result"})],
                structured_content: None,
                is_error: None,
                meta: None,
            })),
            error: None,
            duration_ms: Some(20),
        };
        let mut mcp_disk = mcp_live.clone();
        if let ThreadItem::McpToolCall {
            id, duration_ms, ..
        } = &mut mcp_disk
        {
            *id = "disk-mcp".into();
            *duration_ms = None;
        }
        assert_eq!(
            turn_output_signature(&mcp_live),
            turn_output_signature(&mcp_disk),
            "MCP 的临时 id 和耗时差异不应破坏前缀匹配"
        );
        if let ThreadItem::McpToolCall { result, .. } = &mut mcp_disk {
            result.as_mut().unwrap().content =
                vec![serde_json::json!({"type": "text", "text": "old result"})];
        }
        assert_ne!(
            turn_output_signature(&mcp_live),
            turn_output_signature(&mcp_disk),
            "相同参数但真实结果不同的 MCP call 必须阻止旧尾部拼接"
        );

        let receiver_id = "subagent-toolu_1".to_string();
        let mut live_states = std::collections::HashMap::new();
        live_states.insert(
            receiver_id.clone(),
            alleycat_codex_proto::CollabAgentState {
                status: alleycat_codex_proto::CollabAgentStatus::Completed,
                message: Some("researcher".into()),
            },
        );
        let collab_live = ThreadItem::CollabAgentToolCall {
            id: "toolu_1".into(),
            tool: alleycat_codex_proto::CollabAgentTool::SpawnAgent,
            status: alleycat_codex_proto::CollabAgentToolCallStatus::Completed,
            sender_thread_id: "real-thread-id".into(),
            receiver_thread_ids: vec![receiver_id.clone()],
            prompt: Some("检查实现".into()),
            model: None,
            reasoning_effort: None,
            agents_states: live_states,
        };
        let mut disk_states = std::collections::HashMap::new();
        disk_states.insert(
            receiver_id.clone(),
            alleycat_codex_proto::CollabAgentState {
                status: alleycat_codex_proto::CollabAgentStatus::Completed,
                message: Some("researcher".into()),
            },
        );
        let collab_disk = ThreadItem::CollabAgentToolCall {
            id: "toolu_1".into(),
            tool: alleycat_codex_proto::CollabAgentTool::SpawnAgent,
            status: alleycat_codex_proto::CollabAgentToolCallStatus::Completed,
            sender_thread_id: String::new(),
            receiver_thread_ids: vec![receiver_id],
            prompt: Some("检查实现".into()),
            model: None,
            reasoning_effort: None,
            agents_states: disk_states,
        };
        assert_eq!(
            turn_output_signature(&collab_live),
            turn_output_signature(&collab_disk),
            "disk 缺失 sender thread 不应让同一 subagent 调用被判成内容分叉"
        );
    }

    #[tokio::test]
    async fn persisted_success_does_not_overwrite_active_or_failed_terminal() {
        for status in [TurnStatus::InProgress, TurnStatus::Failed] {
            let state = test_state().await;
            state.record_turn_started("thread", "live-turn".into(), 1);
            state.record_item("thread", "live-turn", user("live-user", "同一问题"));
            if status == TurnStatus::Failed {
                state.record_turn_completed(
                    "thread",
                    "live-turn",
                    2,
                    status,
                    Some(TurnError {
                        message: "真实失败".into(),
                        code: None,
                        codex_error_info: None,
                        additional_details: None,
                    }),
                );
            }

            let report = state.reconcile_thread_log("thread", vec![persisted_turn("同一问题")]);
            assert_eq!(report.protected_turns, 1);
            let turn = &state.thread_log("thread")[0];
            assert_eq!(turn.status, status);
            assert!(
                !turn
                    .items
                    .iter()
                    .any(|item| matches!(item, ThreadItem::AgentMessage { .. }))
            );
        }
    }

    #[tokio::test]
    async fn autonomous_turn_reconciliation_matches_without_user_anchor_and_does_not_duplicate() {
        let state = test_state().await;
        state.record_turn_started("thread", "live-autonomous".into(), 10);
        state.record_item(
            "thread",
            "live-autonomous",
            ThreadItem::AgentMessage {
                id: "live-agent".into(),
                text: "⏰ 五分钟到了".into(),
                phase: None,
                memory_citation: None,
            },
        );
        state.record_turn_completed("thread", "live-autonomous", 11, TurnStatus::Completed, None);

        let persisted = Turn {
            id: "disk-autonomous".into(),
            items: vec![
                ThreadItem::AgentMessage {
                    id: "disk-agent-partial".into(),
                    text: "⏰ 五分钟到了".into(),
                    phase: None,
                    memory_citation: None,
                },
                ThreadItem::AgentMessage {
                    id: "disk-agent-final".into(),
                    text: "当前时间 14:06:06".into(),
                    phase: None,
                    memory_citation: None,
                },
            ],
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(10),
            completed_at: Some(11),
            duration_ms: Some(1_000),
        };

        let report = state.reconcile_thread_log("thread", vec![persisted]);
        assert_eq!(report.repaired_turns, 1);
        let turns = state.thread_log("thread");
        assert_eq!(turns.len(), 1, "同一自主 turn 不应 seed 后再 append");
        assert_eq!(turns[0].id, "live-autonomous");
        assert!(turns[0]
            .items
            .iter()
            .any(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text.contains("五分钟到了"))));
        assert!(turns[0]
            .items
            .iter()
            .any(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text.contains("14:06:06"))));
    }

    #[tokio::test]
    async fn persisted_tail_does_not_overwrite_diverged_completed_live_output() {
        let state = test_state().await;
        record_completed_live_turn(
            &state,
            "thread",
            "live-turn",
            Some("检查状态"),
            "live 中更新的结果",
            1,
            2,
        );

        let persisted = Turn {
            id: "disk-turn".into(),
            items: vec![
                user("disk-user", "检查状态"),
                ThreadItem::AgentMessage {
                    id: "disk-old".into(),
                    text: "JSONL 中较旧的结果".into(),
                    phase: None,
                    memory_citation: None,
                },
                ThreadItem::AgentMessage {
                    id: "disk-tail".into(),
                    text: "不能盲目追加的尾部".into(),
                    phase: None,
                    memory_citation: None,
                },
            ],
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(1_000),
            completed_at: Some(2_000),
            duration_ms: Some(1_000),
        };

        let report = state.reconcile_thread_log("thread", vec![persisted]);
        assert_eq!(report.repaired_turns, 0);
        let turns = state.thread_log("thread");
        assert!(turns[0]
            .items
            .iter()
            .any(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text == "live 中更新的结果")));
        assert!(!turns[0]
            .items
            .iter()
            .any(|item| matches!(item, ThreadItem::AgentMessage { text, .. } if text == "不能盲目追加的尾部")));
    }

    #[tokio::test]
    async fn steered_turn_reconciliation_keeps_anchorless_live_output_in_historical_position() {
        let state = test_state().await;
        record_completed_live_turn(
            &state,
            "thread",
            "live-original",
            Some("先检查 MIM-53"),
            "正在检查验收标准",
            100,
            110,
        );
        // turn/steer 可能在前一轮刚完成时才被 Claude 消费。事件驱动会把后续
        // 输出记录为无 user item 的 autonomous turn，但 JSONL 会用 steer 输入
        // 开启一个普通历史 turn；两者其实是同一轮回复。
        record_completed_live_turn(
            &state,
            "thread",
            "live-steered",
            None,
            "MIM-53 的验收标准已更新",
            121,
            180,
        );
        record_completed_live_turn(
            &state,
            "thread",
            "live-current",
            Some("继续处理当前任务"),
            "当前任务回复",
            300,
            320,
        );

        let report = state.reconcile_thread_log(
            "thread",
            vec![
                completed_turn(
                    "disk-original",
                    Some("先检查 MIM-53"),
                    "正在检查验收标准",
                    100_000,
                    110_000,
                ),
                completed_turn(
                    "disk-steered",
                    Some("更新下 issue"),
                    "MIM-53 的验收标准已更新",
                    115_000,
                    180_000,
                ),
                completed_turn(
                    "disk-current",
                    Some("继续处理当前任务"),
                    "当前任务回复",
                    300_000,
                    320_000,
                ),
            ],
        );

        assert_eq!(report.seeded_turns, 0);
        assert_eq!(report.reanchored_turns, 1);
        let turns = state.thread_log("thread");
        assert_eq!(turns.len(), 3, "steer 回复不应在当前回合后再追加一份");
        assert_eq!(
            turns
                .iter()
                .map(|turn| turn.id.as_str())
                .collect::<Vec<_>>(),
            vec!["live-original", "live-steered", "live-current"]
        );
    }

    #[tokio::test]
    async fn anchorless_live_output_outside_persisted_window_stays_independent() {
        let state = test_state().await;
        record_completed_live_turn(
            &state,
            "thread",
            "live-later",
            None,
            "相同但很常见的完成提示",
            300,
            310,
        );

        let report = state.reconcile_thread_log(
            "thread",
            vec![completed_turn(
                "disk-earlier",
                Some("较早的用户请求"),
                "相同但很常见的完成提示",
                100_000,
                110_000,
            )],
        );

        assert_eq!(report.reanchored_turns, 0);
        assert_eq!(report.seeded_turns, 1);
        assert_eq!(
            state
                .thread_log("thread")
                .iter()
                .map(|turn| turn.id.as_str())
                .collect::<Vec<_>>(),
            vec!["disk-earlier", "live-later"]
        );
    }

    #[tokio::test]
    async fn active_anchorless_live_turn_is_not_absorbed_by_persisted_history() {
        let state = test_state().await;
        state.record_turn_started("thread", "live-active".into(), 105);
        state.record_item(
            "thread",
            "live-active",
            ThreadItem::AgentMessage {
                id: "live-active-agent".into(),
                text: "仍在生成的相同输出".into(),
                phase: None,
                memory_citation: None,
            },
        );

        let report = state.reconcile_thread_log(
            "thread",
            vec![completed_turn(
                "disk-completed",
                Some("已经完成的请求"),
                "仍在生成的相同输出",
                100_000,
                110_000,
            )],
        );

        assert_eq!(report.reanchored_turns, 0);
        let turns = state.thread_log("thread");
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0].id, "disk-completed");
        assert_eq!(turns[1].id, "live-active");
        assert_eq!(turns[1].status, TurnStatus::InProgress);
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReconcileReport {
    pub live_turns: usize,
    pub persisted_turns: usize,
    pub seeded_turns: usize,
    pub repaired_turns: usize,
    pub protected_turns: usize,
    pub reanchored_turns: usize,
}

impl From<Turn> for RecordedTurn {
    fn from(turn: Turn) -> Self {
        Self {
            turn_id: turn.id,
            started_at: turn.started_at.unwrap_or_default(),
            completed_at: turn.completed_at,
            status: turn.status,
            error: turn.error,
            items: turn.items,
        }
    }
}

fn turn_user_key(items: &[ThreadItem]) -> Option<String> {
    items.iter().find_map(|item| match item {
        ThreadItem::UserMessage { content, .. } => serde_json::to_string(content).ok(),
        _ => None,
    })
}

// 先以用户输入锚定普通 turn；自主 turn 没有 user item，则使用不含临时 id
// 的可见内容指纹匹配。turn/steer 有一个特殊竞态：Claude 可能在原 client
// turn 收口后才消费 steer，live cache 因此记录成无 user 的 autonomous turn，
// 但 JSONL 会用 steer 输入开启普通 turn。此时只在完成态、时间窗口重合且
// 可见输出相同时恢复关联，避免把真正独立的自主任务误合并。
fn turn_match_score(persisted: &Turn, live: &RecordedTurn) -> u8 {
    let persisted_user = turn_user_key(&persisted.items);
    let live_user = turn_user_key(&live.items);
    let persisted_has_user = persisted_user.is_some();
    match (persisted_user.as_deref(), live_user.as_deref()) {
        (Some(left), Some(right)) => return u8::from(left == right) * 4,
        (Some(_), None) => {
            if live.status != TurnStatus::Completed
                || !completed_turn_windows_overlap(persisted, live)
            {
                return 0;
            }
        }
        (None, Some(_)) => return 0,
        (None, None) => {}
    }
    let persisted_visible = turn_visible_signatures(&persisted.items);
    let live_visible = turn_visible_signatures(&live.items);
    if persisted_visible
        .iter()
        .any(|signature| live_visible.contains(signature))
    {
        if persisted_has_user { 2 } else { 3 }
    } else {
        0
    }
}

fn completed_turn_windows_overlap(persisted: &Turn, live: &RecordedTurn) -> bool {
    let (Some(persisted_start), Some(persisted_end), Some(live_end)) = (
        persisted.started_at,
        persisted.completed_at,
        live.completed_at,
    ) else {
        return false;
    };
    // JSONL 的 RFC 3339 时间由 translate/items 记录为毫秒；实时回合使用
    // now_unix_secs。只在这个对账边界把权威历史归一到秒，避免改动协议字段
    // 的既有语义，也避免毫秒值与秒值直接比较导致 steer 回合永远无法重锚。
    let persisted_start_secs = persisted_start.div_euclid(1_000);
    let persisted_end_secs = persisted_end.div_euclid(1_000);
    persisted_start_secs <= live_end && live.started_at <= persisted_end_secs
}

fn turn_visible_signatures(items: &[ThreadItem]) -> Vec<String> {
    items.iter().filter_map(turn_visible_signature).collect()
}

fn turn_visible_signature(item: &ThreadItem) -> Option<String> {
    match item {
        ThreadItem::AgentMessage { text, .. } => Some(format!("agent:{text}")),
        ThreadItem::Plan { text, .. } => Some(format!("plan:{text}")),
        ThreadItem::Reasoning {
            summary, content, ..
        } => Some(format!("reasoning:{summary:?}:{content:?}")),
        ThreadItem::CommandExecution {
            command,
            aggregated_output,
            ..
        } => Some(format!("command:{command}:{aggregated_output:?}")),
        ThreadItem::HookPrompt { fragments, .. } => Some(format!("hook:{fragments:?}")),
        _ => None,
    }
}

/// 历史尾部对账需要覆盖全部用户可见输出，而不仅是用于 autonomous turn
/// 粗匹配的文本类指纹。签名排除实时/JSONL 之间不稳定的 item id 和耗时字段，
/// 但保留工具输入、结果与状态；内容分叉时宁可不修，也不盲目拼接旧快照。
fn turn_output_signature(item: &ThreadItem) -> Option<String> {
    if let Some(signature) = turn_visible_signature(item) {
        return Some(signature);
    }
    match item {
        ThreadItem::FileChange {
            changes, status, ..
        } => Some(format!("fileChange:{status:?}:{changes:?}")),
        ThreadItem::McpToolCall {
            server,
            tool,
            status,
            arguments,
            result,
            error,
            ..
        } => {
            let result = result
                .as_ref()
                .map(|result| (&result.content, &result.structured_content, result.is_error));
            let error = error
                .as_ref()
                .map(|error| (&error.message, error.code, &error.data));
            Some(format!(
                "mcp:{server}:{tool}:{status:?}:{arguments}:{result:?}:{error:?}"
            ))
        }
        ThreadItem::DynamicToolCall {
            namespace,
            tool,
            arguments,
            status,
            content_items,
            success,
            ..
        } => {
            let normalized_content = content_items
                .as_deref()
                .unwrap_or_default()
                .iter()
                .flat_map(normalize_dynamic_tool_call_output)
                .collect::<Vec<_>>();
            Some(format!(
                "dynamic:{namespace:?}:{tool}:{arguments}:{status:?}:{success:?}:{normalized_content:?}"
            ))
        }
        ThreadItem::CollabAgentToolCall {
            tool,
            status,
            receiver_thread_ids,
            prompt,
            model,
            reasoning_effort,
            agents_states,
            ..
        } => {
            let mut messages = agents_states
                .values()
                .filter_map(|state| state.message.as_deref())
                .collect::<Vec<_>>();
            messages.sort_unstable();
            Some(format!(
                "collab:{tool:?}:{status:?}:{receiver_thread_ids:?}:{prompt:?}:{model:?}:{reasoning_effort:?}:{messages:?}"
            ))
        }
        ThreadItem::WebSearch { query, action, .. } => {
            Some(format!("webSearch:{query}:{action:?}"))
        }
        ThreadItem::ImageView { path, .. } => Some(format!("imageView:{path}")),
        ThreadItem::ImageGeneration {
            status,
            revised_prompt,
            result,
            saved_path,
            ..
        } => Some(format!(
            "imageGeneration:{status}:{revised_prompt:?}:{result}:{saved_path:?}"
        )),
        ThreadItem::EnteredReviewMode { review, .. } => Some(format!("enteredReview:{review}")),
        ThreadItem::ExitedReviewMode { review, .. } => Some(format!("exitedReview:{review}")),
        ThreadItem::ContextCompaction { .. } => Some("contextCompaction".into()),
        ThreadItem::UserMessage { .. }
        | ThreadItem::HookPrompt { .. }
        | ThreadItem::AgentMessage { .. }
        | ThreadItem::Plan { .. }
        | ThreadItem::Reasoning { .. }
        | ThreadItem::CommandExecution { .. } => None,
    }
}

/// 当 live 已观测到的全部可见输出是 persisted 的严格顺序前缀时，补入 JSONL
/// 中尚未到达实时事件流的尾部。这里故意使用不含临时 id 的内容签名；Claude 的
/// 实时 AgentMessage id 是 bridge 生成的 UUID，而 JSONL 使用 message id 派生值。
fn append_strict_persisted_output_tail(
    live_items: &mut Vec<ThreadItem>,
    persisted_items: &[ThreadItem],
) -> bool {
    let live_visible = live_items
        .iter()
        .filter_map(turn_output_signature)
        .collect::<Vec<_>>();
    let persisted_visible = persisted_items
        .iter()
        .filter_map(turn_output_signature)
        .collect::<Vec<_>>();
    if live_visible.is_empty()
        || live_visible.len() >= persisted_visible.len()
        || !persisted_visible.starts_with(&live_visible)
    {
        return false;
    }

    let first_missing_visible = live_visible.len();
    let mut visible_index = 0;
    let Some(first_missing_item) = persisted_items.iter().position(|item| {
        if turn_output_signature(item).is_none() {
            return false;
        }
        let is_first_missing = visible_index == first_missing_visible;
        visible_index += 1;
        is_first_missing
    }) else {
        return false;
    };

    live_items.extend_from_slice(&persisted_items[first_missing_item..]);
    true
}

fn persisted_has_successful_output(items: &[ThreadItem]) -> bool {
    items.iter().any(|item| {
        matches!(
            item,
            ThreadItem::AgentMessage { .. }
                | ThreadItem::Plan { .. }
                | ThreadItem::CommandExecution { .. }
                | ThreadItem::FileChange { .. }
                | ThreadItem::McpToolCall { .. }
                | ThreadItem::DynamicToolCall { .. }
                | ThreadItem::CollabAgentToolCall { .. }
        )
    })
}

#[derive(Debug, thiserror::Error)]
pub enum SendError {
    #[error("connection writer is closed")]
    ConnectionClosed,
}

impl ConnectionState {
    /// Build a `ConnectionState` for tests, backed by an in-memory session.
    pub fn for_test(
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
    ) -> (
        Arc<Self>,
        tokio::sync::mpsc::UnboundedReceiver<alleycat_bridge_core::session::Sequenced>,
    ) {
        let session = Arc::new(Session::new("claude", "test".into(), 64, 1 << 20));
        let attach = session.install_attachment(None);
        let state = Arc::new(Self::new(session, claude_pool, thread_index, defaults));
        (state, attach.live_rx)
    }
}
