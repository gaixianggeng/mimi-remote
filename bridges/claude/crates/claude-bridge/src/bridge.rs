//! `ClaudeBridge` — the unified `Bridge` impl.
//!
//! Owns the [`ClaudePool`], the disk-backed thread index, the launcher seam,
//! and per-connection state keyed by session id. Replaces the legacy
//! [`crate::server::run_connection_with_session`] free function (which is kept
//! as a thin compat shim during the migration).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::server::{Bridge, Conn};
use alleycat_bridge_core::{JsonRpcError, LocalLauncher, ProcessLauncher, error_codes};
use alleycat_codex_proto as p;
use anyhow::Result;
use async_trait::async_trait;
use dashmap::DashMap;
use serde_json::Value;

use crate::handlers;
use crate::index::{
    ClaudeHistoryRefresher, ClaudeHydrator, DEFAULT_HISTORY_REFRESH_INTERVAL,
    open_index_and_hydrate,
};
use crate::pool::{ClaudePool, PoolPolicy};
use crate::state::{ConnectionState, ThreadDefaults};

/// Concrete handle type stored on the bridge. Uses [`crate::state::ThreadIndexHandle`]
/// (a marker subtrait of `bridge_core::ThreadIndexHandle<ClaudeSessionRef>`)
/// so the daemon's `Arc<dyn alleycat_claude_bridge::state::ThreadIndexHandle>`
/// flows in directly through the compat shim.
pub type ThreadIndexHandle = Arc<dyn crate::state::ThreadIndexHandle>;

/// Default codex_home: matches `handlers::lifecycle::default_codex_home()`.
fn default_codex_home() -> PathBuf {
    handlers::lifecycle::default_codex_home()
}

/// Unified claude-bridge facade.
pub struct ClaudeBridge {
    pool: Arc<ClaudePool>,
    thread_index: ThreadIndexHandle,
    history_refresher: Option<Arc<ClaudeHistoryRefresher>>,
    codex_home: PathBuf,
    /// Held so embedders (Litter) can swap launchers; the pool already has its
    /// own `Arc<dyn ProcessLauncher>` clone for spawning agent processes.
    /// `command_exec` will route through this when migrated.
    #[allow(dead_code)]
    launcher: Arc<dyn ProcessLauncher>,
    per_conn: DashMap<String, Arc<ConnectionState>>,
    trust_persisted_cwd: bool,
}

impl std::fmt::Debug for ClaudeBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClaudeBridge")
            .field("codex_home", &self.codex_home)
            .field("connections", &self.per_conn.len())
            .field("trust_persisted_cwd", &self.trust_persisted_cwd)
            .finish_non_exhaustive()
    }
}

impl ClaudeBridge {
    pub fn builder() -> ClaudeBridgeBuilder {
        ClaudeBridgeBuilder::default()
    }

    pub fn pool(&self) -> &Arc<ClaudePool> {
        &self.pool
    }

    pub fn thread_index(&self) -> &ThreadIndexHandle {
        &self.thread_index
    }

    pub fn codex_home(&self) -> &std::path::Path {
        &self.codex_home
    }

    pub fn launcher(&self) -> &Arc<dyn ProcessLauncher> {
        &self.launcher
    }

    /// Look up (or lazily create) the per-connection state for the session
    /// `(node_id, agent)` tuple. Defaults are seeded fresh; subsequent calls
    /// return the same `Arc`.
    pub fn per_conn(&self, ctx: &Conn) -> Arc<ConnectionState> {
        let session = ctx.session();
        let key = format!("{}:{}", session.agent, session.node_id);
        if let Some(existing) = self.per_conn.get(&key) {
            let state = Arc::clone(existing.value());
            // 同一个稳定 session key 在 bridge-core 的离线 TTL 之后会得到
            // 一个新的 replay ring。runtime 状态继续复用，但交付目标必须切到
            // 本次 attach 的 Session，避免通知写进已经被回收的旧 ring。
            state.rebind_session(Arc::clone(session));
            return state;
        }
        let state = Arc::new(ConnectionState::with_launcher_and_history_refresher(
            Arc::clone(ctx.session()),
            Arc::clone(&self.pool),
            Arc::clone(&self.thread_index),
            ThreadDefaults::default(),
            Some(Arc::clone(&self.launcher)),
            self.trust_persisted_cwd,
            self.history_refresher.as_ref().map(Arc::clone),
        ));
        // Insert; concurrent calls may race — entry/or_insert resolves the
        // race deterministically.
        let entry = self
            .per_conn
            .entry(key)
            .or_insert_with(|| Arc::clone(&state));
        Arc::clone(entry.value())
    }

    /// Drop per-connection state for `session_id`. Called by the daemon when
    /// the session reaper evicts the session.
    pub fn drop_session(&self, session_id: &str) {
        self.per_conn.remove(session_id);
    }

    /// Internal: assemble a bridge from already-built parts. Used by the
    /// legacy `run_connection_with_session` compat shim (see `server.rs`).
    #[doc(hidden)]
    pub fn __assemble(
        pool: Arc<ClaudePool>,
        thread_index: ThreadIndexHandle,
        codex_home: PathBuf,
        launcher: Arc<dyn ProcessLauncher>,
        per_conn: DashMap<String, Arc<ConnectionState>>,
    ) -> Self {
        Self {
            pool,
            thread_index,
            history_refresher: None,
            codex_home,
            launcher,
            per_conn,
            trust_persisted_cwd: false,
        }
    }
}

/// Builder mirror of A2's `PiBridgeBuilder`.
pub struct ClaudeBridgeBuilder {
    agent_bin: Option<PathBuf>,
    launcher: Option<Arc<dyn ProcessLauncher>>,
    codex_home: Option<PathBuf>,
    pool_capacity: Option<usize>,
    idle_ttl: Option<Duration>,
    bypass_permissions: bool,
    trust_persisted_cwd: bool,
    /// Override for the claude `projects/` directory (test hook). `None`
    /// uses [`crate::index::claude_projects_dir`].
    projects_dir_override: Option<PathBuf>,
    history_refresh_interval: Duration,
}

impl Default for ClaudeBridgeBuilder {
    fn default() -> Self {
        Self {
            agent_bin: None,
            launcher: None,
            codex_home: None,
            pool_capacity: None,
            idle_ttl: None,
            bypass_permissions: PoolPolicy::default().bypass_permissions,
            trust_persisted_cwd: false,
            projects_dir_override: None,
            history_refresh_interval: DEFAULT_HISTORY_REFRESH_INTERVAL,
        }
    }
}

impl ClaudeBridgeBuilder {
    pub fn agent_bin(mut self, bin: impl Into<PathBuf>) -> Self {
        self.agent_bin = Some(bin.into());
        self
    }

    pub fn launcher(mut self, launcher: Arc<dyn ProcessLauncher>) -> Self {
        self.launcher = Some(launcher);
        self
    }

    pub fn codex_home(mut self, home: impl Into<PathBuf>) -> Self {
        self.codex_home = Some(home.into());
        self
    }

    pub fn pool_capacity(mut self, n: usize) -> Self {
        self.pool_capacity = Some(n);
        self
    }

    pub fn idle_ttl(mut self, ttl: Duration) -> Self {
        self.idle_ttl = Some(ttl);
        self
    }

    pub fn bypass_permissions(mut self, b: bool) -> Self {
        self.bypass_permissions = b;
        self
    }

    pub fn trust_persisted_cwd(mut self, trust: bool) -> Self {
        self.trust_persisted_cwd = trust;
        self
    }

    pub fn projects_dir_override(mut self, dir: PathBuf) -> Self {
        self.projects_dir_override = Some(dir);
        self
    }

    /// 调整显式历史扫描冷却窗口。生产使用默认值，测试可用更长窗口验证限频。
    pub fn history_refresh_interval(mut self, interval: Duration) -> Self {
        self.history_refresh_interval = interval;
        self
    }

    /// Populate fields from environment variables. Reads:
    /// - `CLAUDE_BRIDGE_CLAUDE_BIN` for the agent binary path
    /// - `CODEX_HOME` for the index directory
    /// - `CLAUDE_BRIDGE_BYPASS_PERMISSIONS` (`1`/`true`/`yes`/`on` enables;
    ///   anything else disables) for the pool-wide bypass flag
    ///
    /// Builder-set values stay; env vars only fill in fields the caller
    /// hasn't already set explicitly.
    pub fn from_env(mut self) -> Self {
        if self.agent_bin.is_none() {
            if let Some(bin) = std::env::var_os("CLAUDE_BRIDGE_CLAUDE_BIN") {
                self.agent_bin = Some(PathBuf::from(bin));
            }
        }
        if self.codex_home.is_none() {
            if let Some(home) = std::env::var_os("CODEX_HOME").filter(|v| !v.is_empty()) {
                self.codex_home = Some(PathBuf::from(home));
            }
        }
        if let Ok(value) = std::env::var("CLAUDE_BRIDGE_BYPASS_PERMISSIONS") {
            self.bypass_permissions = matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            );
        }
        self
    }

    pub async fn build(self) -> Result<Arc<ClaudeBridge>> {
        let claude_bin = self.agent_bin.unwrap_or_else(|| PathBuf::from("claude"));
        let launcher: Arc<dyn ProcessLauncher> = self
            .launcher
            .unwrap_or_else(|| Arc::new(LocalLauncher) as Arc<dyn ProcessLauncher>);
        let codex_home = self.codex_home.unwrap_or_else(default_codex_home);
        if let Err(err) = std::fs::create_dir_all(&codex_home) {
            tracing::warn!(?codex_home, %err, "failed to ensure codex_home; continuing");
        }

        let policy = PoolPolicy {
            bypass_permissions: self.bypass_permissions,
        };
        let max_processes = self
            .pool_capacity
            .unwrap_or(crate::pool::DEFAULT_MAX_PROCESSES);
        let idle_ttl = self.idle_ttl.unwrap_or(crate::pool::DEFAULT_IDLE_TTL);
        let pool = Arc::new(ClaudePool::with_launcher_and_limits(
            claude_bin,
            Arc::clone(&launcher),
            policy,
            max_processes,
            idle_ttl,
        ));

        let hydrator = match self.projects_dir_override {
            Some(dir) => ClaudeHydrator::with_override_dir(dir),
            None => ClaudeHydrator::new(),
        };
        let index = open_index_and_hydrate(codex_home.join("threads.json"), &hydrator).await?;
        let history_refresher = Arc::new(ClaudeHistoryRefresher::with_interval(
            Arc::clone(&index),
            hydrator,
            self.history_refresh_interval,
        ));
        let thread_index: ThreadIndexHandle = index;

        Ok(Arc::new(ClaudeBridge {
            pool,
            thread_index,
            history_refresher: Some(history_refresher),
            codex_home,
            launcher,
            per_conn: DashMap::new(),
            trust_persisted_cwd: self.trust_persisted_cwd,
        }))
    }
}

#[async_trait]
impl Bridge for ClaudeBridge {
    async fn initialize(&self, ctx: &Conn, params: Value) -> Result<Value, JsonRpcError> {
        let typed: p::InitializeParams =
            serde_json::from_value(params).map_err(|err| invalid_params(err.to_string()))?;
        let state = self.per_conn(ctx);
        let response = handlers::lifecycle::handle_initialize(&state, typed, &self.codex_home);
        serde_json::to_value(response).map_err(|err| internal(err.to_string()))
    }

    async fn dispatch(
        &self,
        ctx: &Conn,
        method: &str,
        params: Value,
    ) -> Result<Value, JsonRpcError> {
        let state = self.per_conn(ctx);
        dispatch_request(&state, &self.codex_home, method, params).await
    }

    async fn notification(&self, ctx: &Conn, method: &str, _params: Value) {
        if method == "initialized" {
            let state = self.per_conn(ctx);
            handlers::lifecycle::handle_initialized(&state);
            return;
        }
        tracing::debug!(method, "ignoring unknown client notification");
    }
}

fn invalid_params(msg: impl Into<String>) -> JsonRpcError {
    JsonRpcError {
        code: error_codes::INVALID_PARAMS,
        message: msg.into(),
        data: None,
    }
}

fn internal(msg: impl Into<String>) -> JsonRpcError {
    JsonRpcError {
        code: error_codes::INTERNAL_ERROR,
        message: msg.into(),
        data: None,
    }
}

fn method_not_found(method: &str) -> JsonRpcError {
    JsonRpcError {
        code: error_codes::METHOD_NOT_FOUND,
        message: format!("method `{method}` is not implemented"),
        data: None,
    }
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, JsonRpcError> {
    serde_json::from_value(value).map_err(|err| invalid_params(err.to_string()))
}

async fn dispatch_request(
    state: &Arc<ConnectionState>,
    codex_home: &std::path::Path,
    method: &str,
    params: Value,
) -> Result<Value, JsonRpcError> {
    match method {
        "account/read" => {
            let typed: p::GetAccountParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            to_value(handlers::lifecycle::handle_account_read(state, typed))
        }
        "account/rateLimits/read" => {
            to_value(handlers::lifecycle::handle_account_rate_limits_read(state).await)
        }
        "account/login/start" => {
            let typed: p::LoginAccountParams = decode(params)?;
            let resp = handlers::lifecycle::handle_account_login_start(state, typed)
                .map_err(|err| internal(err.to_string()))?;
            to_value(resp)
        }
        "account/login/cancel" => {
            let typed: p::CancelLoginAccountParams = decode(params)?;
            to_value(handlers::lifecycle::handle_account_login_cancel(
                state, typed,
            ))
        }
        "account/logout" => to_value(handlers::lifecycle::handle_account_logout(state)),
        "feedback/upload" => {
            let typed: p::FeedbackUploadParams = decode(params)?;
            to_value(handlers::lifecycle::handle_feedback_upload(state, typed))
        }
        "config/read" => {
            let typed: p::ConfigReadParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            let resp = handlers::config::handle_config_read(state, codex_home, typed)
                .map_err(|err| internal(err.to_string()))?;
            to_value(resp)
        }
        "config/value/write" => {
            let typed: p::ConfigValueWriteParams = decode(params)?;
            let resp = handlers::config::handle_config_value_write(state, codex_home, typed)
                .map_err(|err| internal(err.to_string()))?;
            to_value(resp)
        }
        "config/batchWrite" => {
            let typed: p::ConfigBatchWriteParams = decode(params)?;
            let resp = handlers::config::handle_config_batch_write(state, codex_home, typed)
                .map_err(|err| internal(err.to_string()))?;
            to_value(resp)
        }
        "configRequirements/read" => {
            to_value(handlers::config::handle_config_requirements_read(state))
        }
        "mcpServerStatus/list" => {
            let typed: p::ListMcpServerStatusParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            to_value(handlers::mcp::handle_mcp_server_status_list(state, typed))
        }
        "config/mcpServer/reload" => to_value(handlers::mcp::handle_mcp_server_refresh(state)),
        "mcpServer/oauth/login" => {
            let typed: p::McpServerOauthLoginParams = decode(params)?;
            to_value(handlers::mcp::handle_mcp_server_oauth_login(state, typed))
        }
        "mock/experimentalMethod" => {
            let typed: p::MockExperimentalMethodParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            to_value(p::MockExperimentalMethodResponse {
                echoed: typed.value,
            })
        }
        "experimentalFeature/list" => to_value(p::ExperimentalFeatureListResponse {
            data: Vec::new(),
            next_cursor: None,
        }),
        "collaborationMode/list" => to_value(p::CollaborationModeListResponse { data: Vec::new() }),
        "model/list" => {
            let typed: p::ModelListParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            to_value(handlers::model::handle_model_list(state, typed).await)
        }
        "skills/list" => {
            let typed: p::SkillsListParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            to_value(handlers::skills::handle_skills_list(state, typed).await)
        }
        "skills/remote/list" => Ok(handlers::skills::handle_skills_remote_list(state).await),
        "skills/remote/export" => {
            Ok(handlers::skills::handle_skills_remote_export(state, params).await)
        }
        "skills/config/write" => {
            let typed: p::SkillsConfigWriteParams = decode(params)?;
            to_value(handlers::skills::handle_skills_config_write(state, typed).await)
        }
        "command/exec" => {
            let typed: p::CommandExecParams = decode(params)?;
            let resp = handlers::command_exec::handle_command_exec(state, typed)
                .await
                .map_err(exec_to_rpc)?;
            to_value(resp)
        }
        "command/exec/terminate" => {
            let typed: p::CommandExecTerminateParams = decode(params)?;
            to_value(handlers::command_exec::handle_command_exec_terminate(state, typed).await)
        }
        "command/exec/write" => {
            let typed: p::CommandExecWriteParams = decode(params)?;
            let resp = handlers::command_exec::handle_command_exec_write(state, typed)
                .await
                .map_err(exec_to_rpc)?;
            to_value(resp)
        }
        "command/exec/resize" => {
            let typed: p::CommandExecResizeParams = decode(params)?;
            let resp = handlers::command_exec::handle_command_exec_resize(state, typed)
                .await
                .map_err(exec_to_rpc)?;
            to_value(resp)
        }
        "thread/start" => {
            let typed: p::ThreadStartParams = decode(params)?;
            let resp = handlers::thread::handle_thread_start(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/resume" => {
            let typed: p::ThreadResumeParams = decode(params)?;
            let resp = handlers::thread::handle_thread_resume(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/fork" => {
            let typed: p::ThreadForkParams = decode(params)?;
            let resp = handlers::thread::handle_thread_fork(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/archive" => {
            let typed: p::ThreadArchiveParams = decode(params)?;
            let resp = handlers::thread::handle_thread_archive(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/unarchive" => {
            let typed: p::ThreadUnarchiveParams = decode(params)?;
            let resp = handlers::thread::handle_thread_unarchive(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/name/set" => {
            let typed: p::ThreadSetNameParams = decode(params)?;
            let resp = handlers::thread::handle_thread_set_name(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/compact/start" => {
            let typed: p::ThreadCompactStartParams = decode(params)?;
            let resp = handlers::thread::handle_thread_compact_start(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/rollback" => {
            let typed: p::ThreadRollbackParams = decode(params)?;
            let resp = handlers::thread::handle_thread_rollback(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/list" => {
            let typed: p::ThreadListParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            let resp = handlers::thread::handle_thread_list(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/loaded/list" => {
            let typed: p::ThreadLoadedListParams = if params.is_null() {
                Default::default()
            } else {
                decode(params)?
            };
            to_value(handlers::thread::handle_thread_loaded_list(state, typed).await)
        }
        "thread/read" => {
            let typed: p::ThreadReadParams = decode(params)?;
            let resp = handlers::thread::handle_thread_read(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/turns/list" => {
            let typed: p::ThreadTurnsListParams = decode(params)?;
            let resp = handlers::thread::handle_thread_turns_list(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/items/list" => {
            let typed: p::ThreadItemsListParams = decode(params)?;
            let resp = handlers::thread::handle_thread_items_list(state, typed)
                .await
                .map_err(thread_to_rpc)?;
            to_value(resp)
        }
        "thread/backgroundTerminals/clean" => {
            let typed: p::ThreadBackgroundTerminalsCleanParams = decode(params)?;
            to_value(handlers::thread::handle_thread_background_terminals_clean(state, typed).await)
        }
        "turn/start" => {
            let typed: p::TurnStartParams = decode(params)?;
            let resp = handlers::turn::handle_turn_start(state, typed)
                .await
                .map_err(turn_to_rpc)?;
            to_value(resp)
        }
        "turn/steer" => {
            let typed: p::TurnSteerParams = decode(params)?;
            let resp = handlers::turn::handle_turn_steer(state, typed)
                .await
                .map_err(turn_to_rpc)?;
            to_value(resp)
        }
        "turn/interrupt" => {
            let typed: p::TurnInterruptParams = decode(params)?;
            let resp = handlers::turn::handle_turn_interrupt(state, typed)
                .await
                .map_err(turn_to_rpc)?;
            to_value(resp)
        }
        "review/start" => {
            let typed: p::ReviewStartParams = decode(params)?;
            let resp = handlers::turn::handle_review_start(state, typed)
                .await
                .map_err(turn_to_rpc)?;
            to_value(resp)
        }
        other => Err(method_not_found(other)),
    }
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, JsonRpcError> {
    serde_json::to_value(value).map_err(|err| internal(err.to_string()))
}

fn exec_to_rpc(err: handlers::command_exec::ExecError) -> JsonRpcError {
    JsonRpcError {
        code: err.rpc_code(),
        message: err.to_string(),
        data: None,
    }
}

fn thread_to_rpc(err: handlers::thread::ThreadError) -> JsonRpcError {
    JsonRpcError {
        code: err.rpc_code(),
        message: err.to_string(),
        data: None,
    }
}

fn turn_to_rpc(err: handlers::turn::TurnError) -> JsonRpcError {
    let data = err.rpc_data();
    JsonRpcError {
        code: err.rpc_code(),
        message: err.to_string(),
        data,
    }
}
