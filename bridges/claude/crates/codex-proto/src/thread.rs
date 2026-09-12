//! `thread/*` request, response, and supporting types.

use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;

use super::common::{
    ApprovalsReviewer, AskForApproval, ConfigOverrides, GitInfo, PermissionProfile, Personality,
    ReasoningEffort, SandboxMode, SandboxPolicy, ServiceTier, SessionSource, ThreadStatus,
    TurnError, TurnStatus,
};
use super::items::ThreadItem;

// === Thread / Turn objects =================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub id: String,
    pub session_id: String,
    #[serde(default)]
    pub forked_from_id: Option<String>,
    pub preview: String,
    pub ephemeral: bool,
    pub model_provider: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub status: ThreadStatus,
    /// Path to the underlying session file. For pi-bridge this is the pi
    /// JSONL path.
    #[serde(default)]
    pub path: Option<String>,
    pub cwd: String,
    pub cli_version: String,
    pub source: SessionSource,
    #[serde(default)]
    pub thread_source: Option<Value>,
    #[serde(default)]
    pub agent_nickname: Option<String>,
    #[serde(default)]
    pub agent_role: Option<String>,
    #[serde(default)]
    pub git_info: Option<GitInfo>,
    #[serde(default)]
    pub name: Option<String>,
    /// 上游用它表示线程是否接受直接输入（子 Agent 线程为 false）。Claude bridge
    /// 在会话被本机其他 Claude 进程持有时也置为 false。缺省不序列化，旧客户端不受影响。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_accept_direct_input: Option<bool>,
    /// Claude 专用：正持有该会话的本机进程摘要（`entrypoint` / `kind` / `status` / `pid`）。
    /// 只在 `can_accept_direct_input == Some(false)` 且原因是别处持有时出现。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_owner: Option<Value>,
    /// Populated only on resume / fork / rollback / read+includeTurns.
    #[serde(default)]
    pub turns: Vec<Turn>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub id: String,
    /// Populated only on resume / fork responses (and replay reads).
    #[serde(default)]
    pub items: Vec<ThreadItem>,
    #[serde(default = "default_items_view")]
    pub items_view: String,
    pub status: TurnStatus,
    #[serde(default)]
    pub error: Option<TurnError>,
    #[serde(default)]
    pub started_at: Option<i64>,
    #[serde(default)]
    pub completed_at: Option<i64>,
    #[serde(default)]
    pub duration_ms: Option<i64>,
}

pub fn default_items_view() -> String {
    "full".to_string()
}

// === thread/start ==========================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadStartParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<ServiceTier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<AskForApproval>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approvals_reviewer: Option<ApprovalsReviewer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandbox: Option<SandboxMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_profile: Option<PermissionProfile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<ConfigOverrides>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub developer_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub personality: Option<Personality>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ephemeral: Option<bool>,
    /// Captures any other fields the bridge does not introspect (environments,
    /// dynamicTools, mockExperimentalField, raw event opts, etc.).
    #[serde(flatten)]
    pub additional: HashMap<String, Value>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadStartResponse {
    pub thread: Thread,
    pub model: String,
    pub model_provider: String,
    #[serde(default)]
    pub service_tier: Option<ServiceTier>,
    pub cwd: String,
    #[serde(default)]
    pub instruction_sources: Vec<String>,
    pub approval_policy: AskForApproval,
    pub approvals_reviewer: ApprovalsReviewer,
    pub sandbox: SandboxPolicy,
    #[serde(default)]
    pub permission_profile: Option<PermissionProfile>,
    #[serde(default)]
    pub active_permission_profile: Option<PermissionProfile>,
    #[serde(default)]
    pub reasoning_effort: Option<ReasoningEffort>,
}

// === thread/resume =========================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadResumeParams {
    pub thread_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<ServiceTier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<AskForApproval>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approvals_reviewer: Option<ApprovalsReviewer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandbox: Option<SandboxMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_profile: Option<PermissionProfile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<ConfigOverrides>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub developer_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub personality: Option<Personality>,
    #[serde(default)]
    pub exclude_turns: bool,
    #[serde(flatten)]
    pub additional: HashMap<String, Value>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadResumeResponse {
    pub thread: Thread,
    pub model: String,
    pub model_provider: String,
    #[serde(default)]
    pub service_tier: Option<ServiceTier>,
    pub cwd: String,
    #[serde(default)]
    pub instruction_sources: Vec<String>,
    pub approval_policy: AskForApproval,
    pub approvals_reviewer: ApprovalsReviewer,
    pub sandbox: SandboxPolicy,
    #[serde(default)]
    pub permission_profile: Option<PermissionProfile>,
    #[serde(default)]
    pub active_permission_profile: Option<PermissionProfile>,
    #[serde(default)]
    pub reasoning_effort: Option<ReasoningEffort>,
}

// === thread/fork ===========================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadForkParams {
    pub thread_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<ServiceTier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<AskForApproval>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approvals_reviewer: Option<ApprovalsReviewer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandbox: Option<SandboxMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_profile: Option<PermissionProfile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<ConfigOverrides>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub developer_instructions: Option<String>,
    #[serde(default)]
    pub ephemeral: bool,
    #[serde(default)]
    pub exclude_turns: bool,
    #[serde(flatten)]
    pub additional: HashMap<String, Value>,
}

/// `thread/fork` response shape mirrors `thread/start`/`resume`.
pub type ThreadForkResponse = ThreadResumeResponse;

// === thread/archive / unarchive ============================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadArchiveParams {
    pub thread_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadArchiveResponse {}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUnarchiveParams {
    pub thread_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUnarchiveResponse {
    pub thread: Thread,
}

// === thread/name/set =======================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSetNameParams {
    pub thread_id: String,
    pub name: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSetNameResponse {}

// === thread/compact/start ==================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadCompactStartParams {
    pub thread_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadCompactStartResponse {}

// === thread/rollback =======================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRollbackParams {
    pub thread_id: String,
    pub num_turns: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRollbackResponse {
    pub thread: Thread,
}

// === thread/list ===========================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadListParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_key: Option<ThreadSortKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_direction: Option<SortDirection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_providers: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_kinds: Option<Vec<ThreadSourceKind>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived: Option<bool>,
    /// `cwd` may be a single string or a list. Preserve verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<Value>,
    #[serde(default)]
    pub use_state_db_only: bool,
    /// Mimi 的显式历史刷新标记。仅 Claude bridge 消费；普通列表与分页保持只读索引路径。
    #[serde(default)]
    pub refresh_history: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_term: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ThreadSourceKind {
    Cli,
    #[serde(rename = "vscode")]
    VsCode,
    Exec,
    AppServer,
    SubAgent,
    SubAgentReview,
    SubAgentCompact,
    SubAgentThreadSpawn,
    SubAgentOther,
    Unknown,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ThreadSortKey {
    CreatedAt,
    UpdatedAt,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SortDirection {
    Asc,
    Desc,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadListResponse {
    pub data: Vec<Thread>,
    pub next_cursor: Option<String>,
    pub backwards_cursor: Option<String>,
}

// === thread/loaded/list ====================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadLoadedListParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadLoadedListResponse {
    pub data: Vec<String>,
    pub next_cursor: Option<String>,
}

// === thread/read ===========================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadReadParams {
    pub thread_id: String,
    #[serde(default)]
    pub include_turns: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadReadResponse {
    pub thread: Thread,
}

// === thread/turns/list =====================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnsListParams {
    pub thread_id: String,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub limit: Option<u32>,
    #[serde(default)]
    pub sort_direction: Option<SortDirection>,
    /// `summary` 只保留用户与助手文本；`full`（默认）带全部 item。
    #[serde(default)]
    pub items_view: Option<String>,
    /// 调用方（agentd 网关）会转发 `thread/items/list` 时才为 true，只有这时 bridge 才按
    /// summary 裁掉工具过程。旧网关不认识这个字段、转发时会丢掉，bridge 就照旧回完整
    /// item；否则被裁掉的内容在旧网关后面再也补不回来。
    #[serde(default)]
    pub items_list_available: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnsListResponse {
    pub data: Vec<Turn>,
    pub next_cursor: Option<String>,
    pub backwards_cursor: Option<String>,
}

// === thread/items/list =====================================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadItemsListParams {
    pub thread_id: String,
    /// 为空时列出整个 thread 的 item。
    #[serde(default)]
    pub turn_id: Option<String>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub limit: Option<u32>,
    #[serde(default)]
    pub sort_direction: Option<SortDirection>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadItemsListEntry {
    pub turn_id: String,
    pub item: ThreadItem,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadItemsListResponse {
    pub data: Vec<ThreadItemsListEntry>,
    pub next_cursor: Option<String>,
}

// === thread/backgroundTerminals/clean ======================================

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadBackgroundTerminalsCleanParams {
    pub thread_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadBackgroundTerminalsCleanResponse {}
