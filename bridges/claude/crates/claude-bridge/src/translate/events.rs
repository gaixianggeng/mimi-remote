//! Translate live claude `stream-json` events into codex JSON-RPC
//! notifications.
//!
//! Per-turn state lives in [`EventTranslatorState`]. The pump in
//! `handlers/turn.rs` builds one per `turn/start` and feeds every
//! [`ClaudeOutbound`] event through [`EventTranslatorState::translate`] until
//! the terminal `result` envelope arrives.
//!
//! The translator owns three book-keeping tables:
//!
//! - `open_message_items: HashMap<u32, OpenItem>` — keyed by `content_block.index`
//!   of the *parent* assistant message, holds the codex `item_id` we minted at
//!   `content_block_start` for text blocks.
//! - `open_thinking_items: HashMap<u32, OpenItem>` — same shape for `thinking`
//!   blocks.
//! - `open_tool_calls: HashMap<tool_use_id, OpenToolCall>` — pairs each
//!   `tool_use` `content_block` with the later `user.message.content[
//!   tool_result ]` envelope that carries its result. Holds the codex
//!   `item_id`, the `CodexToolKind`, an `input_buf` of streamed JSON, and the
//!   parsed tool name (for re-classification on completion).
//!
//! Subagent hierarchy: [`EventTranslatorState::subagent_parents`] maps each
//! tool_use_id we open to the codex item id we picked, so a subsequent event
//! carrying `parent_tool_use_id == that_id` (claude's `Task` tool launches
//! independent message streams) gets its `parent_item_id` stamped. If an event
//! arrives for a parent we haven't yet opened, it goes into a small ring
//! buffer and is replayed once the parent shows up. Stale ring entries are
//! dropped after 30s.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use uuid::Uuid;

use alleycat_codex_proto::{
    AgentMessageDeltaNotification, CollabAgentState, CollabAgentStatus, CollabAgentTool,
    CollabAgentToolCallStatus, CommandExecutionOutputDeltaNotification, CommandExecutionStatus,
    DynamicToolCallArgumentsDeltaNotification, DynamicToolCallStatus, ErrorNotification,
    FileChangePatchUpdatedNotification, FileUpdateChange, ItemCompletedNotification,
    ItemStartedNotification, McpToolCallError, McpToolCallProgressNotification, McpToolCallResult,
    McpToolCallStatus, PatchApplyStatus, PatchChangeKind, ReasoningTextDeltaNotification,
    ServerNotification, ThreadItem, ThreadTokenUsage, ThreadTokenUsageUpdatedNotification,
    TokenUsageBreakdown, TurnError, TurnPlanStep, TurnPlanStepStatus, TurnPlanUpdatedNotification,
    TurnStatus, WarningNotification,
};

use crate::pool::claude_protocol::{
    AssistantEnvelope, ClaudeOutbound, ContentBlock, ContentBlockDelta, RateLimitEnvelope,
    RawAnthropicEvent, ResultEnvelope, StreamEventEnvelope, SystemEvent, UserEnvelope,
};
use crate::translate::tool_call::{CodexToolKind, classify};

/// How long an early-arriving subagent event waits for its parent `Task`
/// `tool_use` to appear before being dropped with a warning.
const SUBAGENT_BUFFER_TTL: Duration = Duration::from_secs(30);
/// Soft upper bound on the per-parent buffered-event count. Keeps a runaway
/// subagent from pinning unbounded memory if its parent never lands.
const SUBAGENT_BUFFER_CAP_PER_PARENT: usize = 32;

/// Per-(thread, turn) state the translator carries between events. One per
/// `turn/start`; dropped on `turn/completed`.
#[derive(Debug)]
pub struct EventTranslatorState {
    thread_id: String,
    turn_id: String,
    user_interrupt_requested: bool,

    /// Open text content blocks keyed by their `content_block.index`.
    open_message_items: HashMap<u32, OpenItem>,
    /// Open thinking content blocks keyed by their `content_block.index`.
    open_thinking_items: HashMap<u32, OpenItem>,
    /// Open `tool_use` content blocks keyed by `tool_use_id` (Anthropic's
    /// `toolu_*`). Carries everything we need to resolve the matching
    /// `tool_result` later.
    open_tool_calls: HashMap<String, OpenToolCall>,

    /// `content_block.index → tool_use_id` so `input_json_delta` /
    /// `content_block_stop` events can find their matching open tool call
    /// without iterating the entire `open_tool_calls` table.
    // 子 Agent 的流会重复使用 content block index；必须连同 parent 一起索引。
    block_index_to_tool_id: HashMap<(Option<String>, u32), String>,
    /// `tool_use_id → item_id` for every tool open in this turn. Used to
    /// resolve `parent_tool_use_id` on subagent events.
    subagent_parents: HashMap<String, String>,
    /// Subagent events that arrived before their parent. Replayed once the
    /// parent lands; entries past `SUBAGENT_BUFFER_TTL` are dropped.
    subagent_buffer: HashMap<String, BufferedSubagent>,

    /// Latest token usage seen on this turn. Sent as
    /// `thread/tokenUsage/updated` on `message_delta` events and again at
    /// `turn/completed` time.
    last_token_usage: Option<TokenUsageBreakdown>,
    /// Cumulative across the turn (sum of every `message_delta.usage` we
    /// see — claude can emit several when multi-iteration loops fire).
    cumulative_token_usage: TokenUsageBreakdown,

    /// Latest model-context-window observation, populated from `result.modelUsage`.
    model_context_window: Option<i64>,

    /// Per-turn todo-list state, indexed by claude `taskId` so updates
    /// patch the right step. Insertion order is preserved by the Vec
    /// shape so emitted plans have a stable display order. Mirrors what
    /// upstream codex publishes via `turn/plan/updated`.
    todo_steps: Vec<(String, TurnPlanStep)>,
}

#[derive(Debug, Clone)]
struct OpenItem {
    item_id: String,
    /// Accumulated text — used to fill the `text`/`content` field on
    /// `content_block_stop`.
    accumulated: String,
    /// `parent_tool_use_id` of the opening event, if any. Forwarded on
    /// every delta so the codex client can render nesting.
    parent_tool_use_id: Option<String>,
}

#[derive(Debug, Clone)]
struct OpenToolCall {
    item_id: String,
    kind: CodexToolKind,
    /// Original claude tool name (`Read`, `Task`, `ExitPlanMode`, ...). Kept
    /// alongside `kind` because the semantic kinds (`PlanExit`, `Subagent`,
    /// etc.) don't carry the original string and translators need it to
    /// build canonical items or fall back to a Dynamic shape.
    tool_name: String,
    /// Raw streamed `input_json_delta` accumulator.
    input_buf: String,
    /// Cursor into `input_buf` for the Bash command-string streaming parser.
    /// Bytes already converted into `outputDelta` notifications.
    bash_cursor: usize,
    /// True once we've found the start of the JSON `command` string and are
    /// streaming its contents byte-by-byte.
    bash_in_command_value: bool,
    /// True once we've emitted the trailing `\n` after `content_block_stop`.
    bash_command_terminated: bool,
    /// `parent_tool_use_id` of the opening `content_block_start`. Lifted onto
    /// every notification this tool call emits.
    parent_tool_use_id: Option<String>,
}

#[derive(Debug)]
struct BufferedSubagent {
    deadline: Instant,
    events: Vec<ClaudeOutbound>,
}

impl EventTranslatorState {
    pub fn new(thread_id: impl Into<String>, turn_id: impl Into<String>) -> Self {
        Self {
            thread_id: thread_id.into(),
            turn_id: turn_id.into(),
            user_interrupt_requested: false,
            open_message_items: HashMap::new(),
            open_thinking_items: HashMap::new(),
            open_tool_calls: HashMap::new(),
            block_index_to_tool_id: HashMap::new(),
            subagent_parents: HashMap::new(),
            subagent_buffer: HashMap::new(),
            last_token_usage: None,
            cumulative_token_usage: TokenUsageBreakdown::default(),
            model_context_window: None,
            todo_steps: Vec::new(),
        }
    }

    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    pub fn turn_id(&self) -> &str {
        &self.turn_id
    }

    /// 由 turn handler 在确认本地 interrupt intent 后调用。translator 自身不根据
    /// 模糊错误文本推断用户意图，避免吞掉真实的流式故障。
    pub(crate) fn mark_user_interrupt_requested(&mut self) {
        self.user_interrupt_requested = true;
    }

    /// Translate one outbound claude event into zero or more codex
    /// notifications. Drains any subagent buffer entries whose parent has
    /// since landed.
    pub fn translate(&mut self, event: ClaudeOutbound) -> Vec<ServerNotification> {
        // Buffer events arriving before their parent `Task` `tool_use` open.
        if let Some(parent_id) = event_parent_tool_use_id(&event) {
            if !self.subagent_parents.contains_key(parent_id) {
                self.buffer_subagent_event(parent_id.to_string(), event);
                return Vec::new();
            }
        }

        let mut out = self.translate_one(event);
        // Replay any buffered subagent events whose parent is now known.
        let replay = self.drain_known_subagent_buffer();
        for ev in replay {
            out.extend(self.translate_one(ev));
        }
        // Garbage-collect stale buffer entries on every translate call so a
        // parent that never lands eventually frees memory + logs a warning.
        self.gc_subagent_buffer();
        out
    }

    fn translate_one(&mut self, event: ClaudeOutbound) -> Vec<ServerNotification> {
        match event {
            ClaudeOutbound::System(SystemEvent::Init(_)) => Vec::new(),
            ClaudeOutbound::System(SystemEvent::Status(_)) => Vec::new(),
            ClaudeOutbound::System(SystemEvent::Other) => Vec::new(),
            ClaudeOutbound::StreamEvent(env) => self.translate_stream_event(env),
            ClaudeOutbound::Assistant(env) => self.translate_assistant_envelope(env),
            ClaudeOutbound::User(env) => self.translate_user_envelope(env),
            ClaudeOutbound::RateLimitEvent(env) => self.translate_rate_limit(env),
            ClaudeOutbound::Result(r) => self.translate_result(r),
            // Liveness + in-band control RPC envelopes — silently dropped in
            // v1. Permission bridging via inbound `control_request` is a v2
            // follow-up tracked separately.
            ClaudeOutbound::KeepAlive
            | ClaudeOutbound::ControlRequest(_)
            | ClaudeOutbound::ControlCancelRequest(_)
            | ClaudeOutbound::ControlResponse(_)
            | ClaudeOutbound::StreamlinedText(_)
            | ClaudeOutbound::StreamlinedToolUseSummary(_)
            | ClaudeOutbound::Other => Vec::new(),
        }
    }

    // ------------------------------------------------------------------
    // stream_event
    // ------------------------------------------------------------------

    fn translate_stream_event(&mut self, env: StreamEventEnvelope) -> Vec<ServerNotification> {
        let parent = env.parent_tool_use_id.as_deref();
        match env.event {
            RawAnthropicEvent::MessageStart { .. } => Vec::new(),
            RawAnthropicEvent::ContentBlockStart {
                index,
                content_block,
            } => self.translate_block_start(index, content_block, parent),
            RawAnthropicEvent::ContentBlockDelta { index, delta } => {
                self.translate_block_delta(index, delta, parent)
            }
            RawAnthropicEvent::ContentBlockStop { index } => {
                self.translate_block_stop(index, parent)
            }
            RawAnthropicEvent::MessageDelta {
                delta: _, usage, ..
            } => self.translate_message_delta_usage(usage),
            RawAnthropicEvent::MessageStop => Vec::new(),
        }
    }

    /// 嵌套 Agent 偶尔只发送完整 assistant 快照而没有对应 stream_event。
    /// 以 tool_use_id 去重补建调用，避免后续 tool_result 找不到上下文。
    fn translate_assistant_envelope(&mut self, env: AssistantEnvelope) -> Vec<ServerNotification> {
        let parent = env.parent_tool_use_id.as_deref();
        let mut out = Vec::new();
        let content = env
            .message
            .get("content")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for block in content {
            if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                continue;
            }
            let Some(id) = block.get("id").and_then(Value::as_str).map(str::to_string) else {
                continue;
            };
            if self.open_tool_calls.contains_key(&id) || self.subagent_parents.contains_key(&id) {
                continue;
            }
            let name = block
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string();
            let input = block.get("input").cloned().unwrap_or(Value::Null);
            let kind = classify(&name);
            let call = OpenToolCall {
                item_id: id.clone(),
                kind: kind.clone(),
                tool_name: name.clone(),
                input_buf: input.to_string(),
                bash_cursor: 0,
                bash_in_command_value: false,
                bash_command_terminated: true,
                parent_tool_use_id: parent.map(str::to_string),
            };
            self.subagent_parents.insert(id.clone(), id.clone());
            let deferred = matches!(
                kind,
                CodexToolKind::PlanExit
                    | CodexToolKind::RequestUserInput
                    | CodexToolKind::TodoUpdate
                    | CodexToolKind::ExplorationRead
                    | CodexToolKind::ExplorationSearch
                    | CodexToolKind::ExplorationList
                    | CodexToolKind::WebSearch
                    | CodexToolKind::Subagent
            );
            let item = if deferred {
                build_deferred_started_item(&call, &self.thread_id)
            } else {
                Some(tool_started_item(&kind, &name, &id, &input))
            };
            self.open_tool_calls.insert(id, call);
            if let Some(item) = item {
                out.push(self.item_started(item, parent));
            }
        }
        out
    }

    fn translate_block_start(
        &mut self,
        index: u32,
        block: ContentBlock,
        parent: Option<&str>,
    ) -> Vec<ServerNotification> {
        match block {
            ContentBlock::Text { .. } => {
                let item_id = new_item_id();
                self.open_message_items.insert(
                    index,
                    OpenItem {
                        item_id: item_id.clone(),
                        accumulated: String::new(),
                        parent_tool_use_id: parent.map(str::to_string),
                    },
                );
                vec![self.item_started(
                    ThreadItem::AgentMessage {
                        id: item_id,
                        text: String::new(),
                        phase: Some(serde_json::Value::String("final_answer".into())),
                        memory_citation: None,
                    },
                    parent,
                )]
            }
            ContentBlock::Thinking { thinking, .. } => {
                let item_id = new_item_id();
                self.open_thinking_items.insert(
                    index,
                    OpenItem {
                        item_id: item_id.clone(),
                        accumulated: thinking,
                        parent_tool_use_id: parent.map(str::to_string),
                    },
                );
                vec![self.item_started(
                    ThreadItem::Reasoning {
                        id: item_id,
                        summary: Vec::new(),
                        content: Vec::new(),
                    },
                    parent,
                )]
            }
            ContentBlock::ToolUse { id, name, input } => {
                let kind = classify(&name);
                let item_id = id.clone();
                self.subagent_parents.insert(id.clone(), item_id.clone());
                self.block_index_to_tool_id
                    .insert((parent.map(str::to_string), index), id.clone());
                // Some kinds need their full input JSON to compose a useful
                // ItemStarted (Plan needs the plan text; Read/Grep/Glob need
                // the file_path / pattern to build the command string and
                // command_actions; WebSearch needs the query). Defer those
                // to content_block_stop. AskUserQuestion / TodoUpdate emit
                // no item here at all (handled later as a server request /
                // turn/plan/updated).
                let defer_item_started = matches!(
                    kind,
                    CodexToolKind::PlanExit
                        | CodexToolKind::RequestUserInput
                        | CodexToolKind::TodoUpdate
                        | CodexToolKind::ExplorationRead
                        | CodexToolKind::ExplorationSearch
                        | CodexToolKind::ExplorationList
                        | CodexToolKind::WebSearch
                        | CodexToolKind::Subagent
                );
                let started = if defer_item_started {
                    None
                } else {
                    Some(tool_started_item(&kind, &name, &item_id, &input))
                };
                self.open_tool_calls.insert(
                    id,
                    OpenToolCall {
                        item_id: item_id.clone(),
                        kind,
                        tool_name: name,
                        input_buf: String::new(),
                        bash_cursor: 0,
                        bash_in_command_value: false,
                        bash_command_terminated: false,
                        parent_tool_use_id: parent.map(str::to_string),
                    },
                );
                match started {
                    Some(item) => vec![self.item_started(item, parent)],
                    None => Vec::new(),
                }
            }
        }
    }

    fn translate_block_delta(
        &mut self,
        index: u32,
        delta: ContentBlockDelta,
        parent: Option<&str>,
    ) -> Vec<ServerNotification> {
        match delta {
            ContentBlockDelta::TextDelta { text } => {
                let Some(item) = self.open_message_items.get_mut(&index) else {
                    return Vec::new();
                };
                item.accumulated.push_str(&text);
                vec![ServerNotification::AgentMessageDelta(
                    AgentMessageDeltaNotification {
                        thread_id: self.thread_id.clone(),
                        turn_id: self.turn_id.clone(),
                        item_id: item.item_id.clone(),
                        delta: text,
                        parent_item_id: self.resolve_parent(parent),
                    },
                )]
            }
            ContentBlockDelta::ThinkingDelta { thinking } => {
                let Some(item) = self.open_thinking_items.get_mut(&index) else {
                    return Vec::new();
                };
                item.accumulated.push_str(&thinking);
                vec![ServerNotification::ReasoningTextDelta(
                    ReasoningTextDeltaNotification {
                        thread_id: self.thread_id.clone(),
                        turn_id: self.turn_id.clone(),
                        item_id: item.item_id.clone(),
                        delta: thinking,
                        content_index: 0,
                        parent_item_id: self.resolve_parent(parent),
                    },
                )]
            }
            ContentBlockDelta::SignatureDelta { .. } => Vec::new(),
            ContentBlockDelta::InputJsonDelta { partial_json } => {
                self.translate_input_json_delta_for_block(index, partial_json, parent)
            }
        }
    }

    fn translate_input_json_delta_for_block(
        &mut self,
        index: u32,
        delta: String,
        parent: Option<&str>,
    ) -> Vec<ServerNotification> {
        let parent_resolved = self.resolve_parent(parent);
        let thread_id = self.thread_id.clone();
        let turn_id = self.turn_id.clone();
        let tool_id = self.tool_id_for_block_index(index, parent);
        let Some(tool_id) = tool_id else {
            return Vec::new();
        };
        let Some(call) = self.open_tool_calls.get_mut(&tool_id) else {
            return Vec::new();
        };
        call.input_buf.push_str(&delta);
        let item_id = call.item_id.clone();

        match call.kind.clone() {
            CodexToolKind::CommandExecution => {
                let chars = bash_command_emit(call);
                if chars.is_empty() {
                    return Vec::new();
                }
                vec![ServerNotification::CommandExecutionOutputDelta(
                    CommandExecutionOutputDeltaNotification {
                        thread_id,
                        turn_id,
                        item_id,
                        delta: chars,
                        parent_item_id: parent_resolved,
                    },
                )]
            }
            CodexToolKind::FileChange => {
                // Best-effort partial parse: try the buffered JSON; if it
                // parses now we surface the snapshot. Otherwise emit nothing
                // (the final snapshot lands on `tool_result`).
                if let Some(changes) = parse_partial_file_change(&call.input_buf) {
                    vec![ServerNotification::FileChangePatchUpdated(
                        FileChangePatchUpdatedNotification {
                            thread_id,
                            turn_id,
                            item_id,
                            changes,
                        },
                    )]
                } else {
                    Vec::new()
                }
            }
            CodexToolKind::Mcp { .. } => {
                let snapshot = call.input_buf.clone();
                vec![ServerNotification::McpToolCallProgress(
                    McpToolCallProgressNotification {
                        thread_id,
                        turn_id,
                        item_id,
                        message: snapshot,
                        parent_item_id: parent_resolved,
                    },
                )]
            }
            CodexToolKind::Dynamic { .. } => {
                vec![ServerNotification::DynamicToolCallArgumentsDelta(
                    DynamicToolCallArgumentsDeltaNotification {
                        thread_id,
                        turn_id,
                        item_id,
                        delta,
                        parent_item_id: parent_resolved,
                    },
                )]
            }
            // Plan (text known only after full parse), Exploration* and
            // WebSearch (need full input to build command/query), Subagent
            // (need prompt before emitting CollabAgent),
            // AskUserQuestion (UI event is the requestUserInput round-trip),
            // and TodoUpdate (collapses to turn/plan/updated) all emit
            // nothing during input streaming. Their canonical item lands
            // at content_block_stop / tool_result.
            CodexToolKind::PlanExit
            | CodexToolKind::RequestUserInput
            | CodexToolKind::TodoUpdate
            | CodexToolKind::ExplorationRead
            | CodexToolKind::ExplorationSearch
            | CodexToolKind::ExplorationList
            | CodexToolKind::WebSearch
            | CodexToolKind::Subagent => Vec::new(),
        }
    }

    /// Find the open tool call whose `content_block.index` matches `index`,
    /// via the side map populated at `content_block_start` time.
    fn tool_id_for_block_index(&self, index: u32, parent: Option<&str>) -> Option<String> {
        self.block_index_to_tool_id
            .get(&(parent.map(str::to_string), index))
            .cloned()
    }

    fn translate_block_stop(
        &mut self,
        index: u32,
        parent: Option<&str>,
    ) -> Vec<ServerNotification> {
        // Text block close: emit item/completed AgentMessage.
        if let Some(item) = self.open_message_items.remove(&index) {
            return vec![self.item_completed_with(
                ThreadItem::AgentMessage {
                    id: item.item_id,
                    text: item.accumulated,
                    phase: Some(serde_json::Value::String("final_answer".into())),
                    memory_citation: None,
                },
                item.parent_tool_use_id.as_deref().or(parent),
            )];
        }
        // Thinking block close: emit item/completed Reasoning.
        if let Some(item) = self.open_thinking_items.remove(&index) {
            return vec![self.item_completed_with(
                ThreadItem::Reasoning {
                    id: item.item_id,
                    summary: Vec::new(),
                    content: vec![item.accumulated],
                },
                item.parent_tool_use_id.as_deref().or(parent),
            )];
        }
        // Tool use block close: emit a final command-echo `\n` for Bash so
        // subsequent stdout deltas read on a fresh line. For PlanExit, this
        // is also where we know the input JSON is complete, so we can parse
        // `arguments.plan` and emit ItemStarted{Plan} now. The actual
        // item/completed waits for the matching tool_result.
        let mut out = Vec::new();
        let parent_resolved = self.resolve_parent(parent);
        let tool_id = self.tool_id_for_block_index(index, parent);
        if let Some(tool_id) = tool_id {
            if let Some(call) = self.open_tool_calls.get(&tool_id) {
                if let Some(item) = build_deferred_started_item(call, &self.thread_id) {
                    out.push(
                        self.item_started(item, call.parent_tool_use_id.as_deref().or(parent)),
                    );
                }
            }
            if let Some(call) = self.open_tool_calls.get_mut(&tool_id) {
                if matches!(call.kind, CodexToolKind::CommandExecution)
                    && !call.bash_command_terminated
                {
                    call.bash_command_terminated = true;
                    out.push(ServerNotification::CommandExecutionOutputDelta(
                        CommandExecutionOutputDeltaNotification {
                            thread_id: self.thread_id.clone(),
                            turn_id: self.turn_id.clone(),
                            item_id: call.item_id.clone(),
                            delta: "\n".to_string(),
                            parent_item_id: parent_resolved,
                        },
                    ));
                }
            }
        }
        out
    }

    fn translate_message_delta_usage(&mut self, usage: Value) -> Vec<ServerNotification> {
        let breakdown = parse_usage_breakdown(&usage);
        if breakdown.total_tokens == 0
            && breakdown.input_tokens == 0
            && breakdown.output_tokens == 0
        {
            return Vec::new();
        }
        // Update cumulative + last; emit a single thread/tokenUsage/updated.
        self.cumulative_token_usage = sum_breakdown(&self.cumulative_token_usage, &breakdown);
        self.last_token_usage = Some(breakdown.clone());

        vec![ServerNotification::ThreadTokenUsageUpdated(
            ThreadTokenUsageUpdatedNotification {
                thread_id: self.thread_id.clone(),
                turn_id: self.turn_id.clone(),
                token_usage: ThreadTokenUsage {
                    total: self.cumulative_token_usage.clone(),
                    last: breakdown,
                    model_context_window: self.model_context_window,
                },
            },
        )]
    }

    // ------------------------------------------------------------------
    // user (tool_result)
    // ------------------------------------------------------------------

    fn translate_user_envelope(&mut self, env: UserEnvelope) -> Vec<ServerNotification> {
        let mut out = Vec::new();
        let parent = env.parent_tool_use_id.as_deref().map(str::to_string);
        let content = env
            .message
            .get("content")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        // The user envelope's top-level `tool_use_result` (live wire) /
        // `toolUseResult` (on-disk) carries claude's structured stdout/stderr
        // /interrupted payload. Per the wire-corrections addendum, this is
        // the source of truth for Bash exit status — the inline content[]
        // text mirrors stdout but doesn't carry stderr or interrupted bits.
        let tool_use_result = env.tool_use_result.clone();

        for entry in content {
            let Some(block_type) = entry.get("type").and_then(Value::as_str) else {
                continue;
            };
            if block_type != "tool_result" {
                continue;
            }
            let Some(tool_use_id) = entry.get("tool_use_id").and_then(Value::as_str) else {
                continue;
            };
            let is_error = entry
                .get("is_error")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let inline_text = stringify_tool_result_content(entry.get("content"));
            let Some(call) = self.open_tool_calls.remove(tool_use_id) else {
                tracing::warn!(
                    %tool_use_id,
                    "tool_result with no matching open tool_use; dropping"
                );
                continue;
            };
            self.subagent_parents.remove(tool_use_id);
            self.block_index_to_tool_id
                .retain(|_, id| id != tool_use_id);
            out.extend(self.complete_tool_call(
                call,
                inline_text,
                tool_use_result.as_ref(),
                is_error,
                parent.as_deref(),
            ));
        }
        out
    }

    fn complete_tool_call(
        &mut self,
        call: OpenToolCall,
        inline_content: String,
        tool_use_result: Option<&Value>,
        is_error: bool,
        parent: Option<&str>,
    ) -> Vec<ServerNotification> {
        let parent_for_call = call.parent_tool_use_id.as_deref().or(parent);
        match &call.kind {
            CodexToolKind::CommandExecution => {
                let (stdout, stderr, interrupted) = bash_extract_streams(tool_use_result);
                // Use the structured stdout when present; fall back to the
                // inline text claude embeds in the content[] block.
                let mut aggregated = stdout.unwrap_or(inline_content);
                if let Some(stderr) = stderr {
                    if !stderr.is_empty() {
                        if !aggregated.is_empty() && !aggregated.ends_with('\n') {
                            aggregated.push('\n');
                        }
                        aggregated.push_str("[stderr] ");
                        aggregated.push_str(&stderr);
                    }
                }
                let status = if is_error || interrupted {
                    CommandExecutionStatus::Failed
                } else {
                    CommandExecutionStatus::Completed
                };
                let item = ThreadItem::CommandExecution {
                    id: call.item_id.clone(),
                    command: extract_bash_command(&call.input_buf),
                    cwd: String::new(),
                    process_id: None,
                    source: Default::default(),
                    status,
                    command_actions: Vec::new(),
                    aggregated_output: Some(aggregated),
                    exit_code: None,
                    duration_ms: None,
                };
                vec![self.item_completed_with(item, parent_for_call)]
            }
            CodexToolKind::FileChange => {
                let status = if is_error {
                    PatchApplyStatus::Failed
                } else {
                    PatchApplyStatus::Completed
                };
                let parsed_args: Value =
                    serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let changes = synthesize_file_changes(&call.tool_name, &parsed_args);
                vec![self.item_completed_with(
                    ThreadItem::FileChange {
                        id: call.item_id.clone(),
                        changes,
                        status,
                    },
                    parent_for_call,
                )]
            }
            CodexToolKind::Mcp { server, tool } => {
                let parsed_input: Value =
                    serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let (result_payload, error) =
                    mcp_result_split(inline_content, tool_use_result.cloned(), is_error);
                let item = ThreadItem::McpToolCall {
                    id: call.item_id.clone(),
                    server: server.clone(),
                    tool: tool.clone(),
                    status: if is_error {
                        McpToolCallStatus::Failed
                    } else {
                        McpToolCallStatus::Completed
                    },
                    arguments: parsed_input,
                    mcp_app_resource_uri: None,
                    result: result_payload,
                    error,
                    duration_ms: None,
                };
                vec![self.item_completed_with(item, parent_for_call)]
            }
            CodexToolKind::Dynamic { namespace, tool } => {
                let parsed_input: Value =
                    serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let content_items =
                    build_dynamic_content_items(&inline_content, tool_use_result.cloned());
                vec![self.item_completed_with(
                    ThreadItem::DynamicToolCall {
                        id: call.item_id.clone(),
                        namespace: namespace.clone(),
                        tool: tool.clone(),
                        arguments: parsed_input,
                        status: if is_error {
                            DynamicToolCallStatus::Failed
                        } else {
                            DynamicToolCallStatus::Completed
                        },
                        content_items,
                        success: Some(!is_error),
                        duration_ms: None,
                    },
                    parent_for_call,
                )]
            }
            CodexToolKind::PlanExit => {
                let plan_text = parse_plan_text(&call.input_buf);
                let mut out = vec![self.item_completed_with(
                    ThreadItem::Plan {
                        id: call.item_id.clone(),
                        text: plan_text,
                    },
                    parent_for_call,
                )];
                if is_error {
                    let detail = inline_content.trim();
                    let message = if detail.is_empty() {
                        "Plan rejected by user.".to_string()
                    } else {
                        format!("Plan rejected by user: {detail}")
                    };
                    out.push(ServerNotification::Warning(WarningNotification {
                        thread_id: Some(self.thread_id.clone()),
                        message,
                    }));
                }
                out
            }
            CodexToolKind::ExplorationRead
            | CodexToolKind::ExplorationSearch
            | CodexToolKind::ExplorationList => {
                let parsed: Value = serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let aggregated = cap_aggregated_output(inline_content);
                let status = if is_error {
                    CommandExecutionStatus::Failed
                } else {
                    CommandExecutionStatus::Completed
                };
                let item = build_exploration_command_item(
                    &call.kind,
                    &call.tool_name,
                    &call.item_id,
                    &parsed,
                    status,
                    Some(aggregated),
                );
                vec![self.item_completed_with(item, parent_for_call)]
            }
            CodexToolKind::WebSearch => {
                let parsed: Value = serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let query = parsed
                    .get("query")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                vec![self.item_completed_with(
                    ThreadItem::WebSearch {
                        id: call.item_id.clone(),
                        query,
                        action: Some(serde_json::json!({"type": "search"})),
                    },
                    parent_for_call,
                )]
            }
            CodexToolKind::Subagent => {
                let parsed: Value = serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let (call_status, agent_status) = if is_error {
                    (
                        CollabAgentToolCallStatus::Failed,
                        CollabAgentStatus::Errored,
                    )
                } else {
                    (
                        CollabAgentToolCallStatus::Completed,
                        CollabAgentStatus::Completed,
                    )
                };
                let item = build_subagent_item(
                    &call.item_id,
                    &self.thread_id,
                    &parsed,
                    call_status,
                    agent_status,
                );
                vec![self.item_completed_with(item, parent_for_call)]
            }
            CodexToolKind::TodoUpdate => {
                if is_error {
                    return Vec::new();
                }
                let parsed_input: Value =
                    serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
                let result_value = tool_use_result.cloned().unwrap_or_else(|| {
                    serde_json::from_str::<Value>(&inline_content).unwrap_or(Value::Null)
                });
                self.apply_todo_tool(&call.tool_name, &parsed_input, &result_value)
            }
            // The UI event for AskUserQuestion is the
            // `item/tool/requestUserInput` round-trip; the matching
            // `tool_result` envelope was synthesized by the orchestrator
            // and injected into claude's stdin, so by the time we see it
            // here the user-facing flow is already complete. Emit
            // nothing — emitting a Dynamic card would double-render the
            // question/answer pair.
            CodexToolKind::RequestUserInput => Vec::new(),
        }
    }

    /// Apply a `TaskCreate` / `TaskUpdate` mutation to the per-turn todo
    /// step list and emit the resulting `turn/plan/updated` snapshot.
    /// Returns an empty Vec if the mutation produced no observable change
    /// (eg an unknown taskId in TaskUpdate).
    fn apply_todo_tool(
        &mut self,
        tool_name: &str,
        input: &Value,
        result: &Value,
    ) -> Vec<ServerNotification> {
        let mutated = match tool_name {
            "TaskCreate" => {
                let subject = input
                    .get("subject")
                    .and_then(Value::as_str)
                    .or_else(|| input.get("description").and_then(Value::as_str))
                    .unwrap_or("")
                    .to_string();
                // The new task id arrives in the tool_result. Try a few
                // shapes — direct `{id}`, nested `{task: {id}}`, or string
                // body — and fall back to a synthesized id so we still
                // emit something rather than silently dropping the entry.
                let task_id = result
                    .get("id")
                    .and_then(Value::as_str)
                    .or_else(|| result.get("taskId").and_then(Value::as_str))
                    .or_else(|| {
                        result
                            .get("task")
                            .and_then(|t| t.get("id"))
                            .and_then(Value::as_str)
                    })
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("task-{}", self.todo_steps.len()));
                let initial_status = input
                    .get("status")
                    .and_then(Value::as_str)
                    .map(parse_todo_status)
                    .unwrap_or(TurnPlanStepStatus::Pending);
                self.todo_steps.push((
                    task_id,
                    TurnPlanStep {
                        step: subject,
                        status: initial_status,
                    },
                ));
                true
            }
            "TaskUpdate" => {
                let task_id = input
                    .get("taskId")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let new_status = input
                    .get("status")
                    .and_then(Value::as_str)
                    .map(parse_todo_status);
                let Some(task_id) = task_id else {
                    return Vec::new();
                };
                let Some(new_status) = new_status else {
                    return Vec::new();
                };
                let mut found = false;
                for (id, step) in self.todo_steps.iter_mut() {
                    if id == &task_id {
                        step.status = new_status;
                        found = true;
                        break;
                    }
                }
                found
            }
            _ => false,
        };
        if !mutated {
            return Vec::new();
        }
        let plan: Vec<TurnPlanStep> = self
            .todo_steps
            .iter()
            .map(|(_, step)| step.clone())
            .collect();
        vec![ServerNotification::TurnPlanUpdated(
            TurnPlanUpdatedNotification {
                thread_id: self.thread_id.clone(),
                turn_id: self.turn_id.clone(),
                explanation: None,
                plan,
            },
        )]
    }

    // ------------------------------------------------------------------
    // rate_limit / result
    // ------------------------------------------------------------------

    fn translate_rate_limit(&self, _env: RateLimitEnvelope) -> Vec<ServerNotification> {
        // rate_limit_event 已由 event driver 写入账号快照，并通过
        // account/rateLimits/updated 通知 App。这里不再生成时间线 Warning：
        // allowed_warning 只是接近阈值，rejected 也应由阻塞额度横幅统一表达。
        Vec::new()
    }

    fn translate_result(&mut self, result: ResultEnvelope) -> Vec<ServerNotification> {
        let mut out = Vec::new();

        // Pull a `model_context_window` out of `result.modelUsage` for future
        // ThreadTokenUsageUpdated notifications; ignored if absent.
        if let Some(model_usage) = result.model_usage.as_ref() {
            if let Some(window) = first_context_window(model_usage) {
                self.model_context_window = Some(window);
            }
        }

        // Surface every permission denial as its own error notification, even
        // on success.
        for denial in &result.permission_denials {
            let message = format!("claude permission denial: {denial}");
            out.push(self.error_notification(message, false));
        }

        // For non-success terminal results, also surface a top-level error so
        // the codex client doesn't have to dig into the matching
        // turn/completed payload.
        if (result.is_error || result.subtype != "success")
            && !is_user_interrupted_result(&result, self.user_interrupt_requested)
        {
            let message = result
                .result
                .clone()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| {
                    format!(
                        "claude turn ended with subtype {} (terminal_reason={:?})",
                        result.subtype, result.terminal_reason
                    )
                });
            out.push(self.error_notification(message, false));
        }
        out
    }

    /// Close every item that is still open when the turn terminates without
    /// its matching content-block stop or tool result.
    ///
    /// Claude can lose stdout or be interrupted between `tool_use` and
    /// `tool_result`. Leaving those items InProgress makes the App look as if
    /// the turn is still running even after `turn/completed{failed}`.
    pub fn abort_open_items(&mut self, reason: &str) -> Vec<ServerNotification> {
        let mut out = Vec::new();

        let messages = std::mem::take(&mut self.open_message_items);
        for (_, item) in messages {
            out.push(self.item_completed_with(
                ThreadItem::AgentMessage {
                    id: item.item_id,
                    text: item.accumulated,
                    phase: Some(Value::String("final_answer".into())),
                    memory_citation: None,
                },
                item.parent_tool_use_id.as_deref(),
            ));
        }

        let thinking = std::mem::take(&mut self.open_thinking_items);
        for (_, item) in thinking {
            out.push(self.item_completed_with(
                ThreadItem::Reasoning {
                    id: item.item_id,
                    summary: Vec::new(),
                    content: vec![item.accumulated],
                },
                item.parent_tool_use_id.as_deref(),
            ));
        }

        let tools = std::mem::take(&mut self.open_tool_calls);
        for (_, call) in tools {
            out.extend(self.complete_tool_call(call, reason.to_string(), None, true, None));
        }
        self.block_index_to_tool_id.clear();
        self.subagent_parents.clear();
        self.subagent_buffer.clear();
        out
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// Map `parent_tool_use_id → item_id` if known; else `None`. The bridge
    /// stamps the result onto every emitted notification so codex clients can
    /// render the subagent tree.
    fn resolve_parent(&self, parent_tool_use_id: Option<&str>) -> Option<String> {
        let key = parent_tool_use_id?;
        self.subagent_parents.get(key).cloned()
    }

    fn buffer_subagent_event(&mut self, parent_id: String, event: ClaudeOutbound) {
        let entry = self
            .subagent_buffer
            .entry(parent_id)
            .or_insert_with(|| BufferedSubagent {
                deadline: Instant::now() + SUBAGENT_BUFFER_TTL,
                events: Vec::new(),
            });
        if entry.events.len() >= SUBAGENT_BUFFER_CAP_PER_PARENT {
            entry.events.remove(0);
        }
        entry.events.push(event);
    }

    fn drain_known_subagent_buffer(&mut self) -> Vec<ClaudeOutbound> {
        let known: Vec<String> = self
            .subagent_buffer
            .keys()
            .filter(|k| self.subagent_parents.contains_key(k.as_str()))
            .cloned()
            .collect();
        let mut out = Vec::new();
        for k in known {
            if let Some(entry) = self.subagent_buffer.remove(&k) {
                out.extend(entry.events);
            }
        }
        out
    }

    fn gc_subagent_buffer(&mut self) {
        let now = Instant::now();
        let stale: Vec<String> = self
            .subagent_buffer
            .iter()
            .filter(|(_, b)| b.deadline < now)
            .map(|(k, _)| k.clone())
            .collect();
        for k in stale {
            tracing::warn!(
                parent_tool_use_id = %k,
                "dropping subagent events whose parent never landed within {SUBAGENT_BUFFER_TTL:?}"
            );
            self.subagent_buffer.remove(&k);
        }
    }

    fn item_started(&self, item: ThreadItem, parent: Option<&str>) -> ServerNotification {
        ServerNotification::ItemStarted(ItemStartedNotification {
            item,
            thread_id: self.thread_id.clone(),
            turn_id: self.turn_id.clone(),
            parent_item_id: self.resolve_parent(parent),
        })
    }

    fn item_completed_with(&self, item: ThreadItem, parent: Option<&str>) -> ServerNotification {
        ServerNotification::ItemCompleted(ItemCompletedNotification {
            item,
            thread_id: self.thread_id.clone(),
            turn_id: self.turn_id.clone(),
            parent_item_id: self.resolve_parent(parent),
        })
    }

    fn error_notification(&self, message: String, will_retry: bool) -> ServerNotification {
        let code = claude_error_code(&message).map(str::to_string);
        ServerNotification::Error(ErrorNotification {
            error: TurnError {
                message,
                code,
                codex_error_info: None,
                additional_details: None,
            },
            will_retry,
            thread_id: self.thread_id.clone(),
            turn_id: self.turn_id.clone(),
        })
    }
}

// === free helpers =========================================================

fn new_item_id() -> String {
    Uuid::now_v7().to_string()
}

fn event_parent_tool_use_id(event: &ClaudeOutbound) -> Option<&str> {
    match event {
        ClaudeOutbound::StreamEvent(env) => env.parent_tool_use_id.as_deref(),
        ClaudeOutbound::Assistant(env) => env.parent_tool_use_id.as_deref(),
        ClaudeOutbound::User(env) => env.parent_tool_use_id.as_deref(),
        ClaudeOutbound::System(_)
        | ClaudeOutbound::RateLimitEvent(_)
        | ClaudeOutbound::Result(_)
        | ClaudeOutbound::KeepAlive
        | ClaudeOutbound::ControlRequest(_)
        | ClaudeOutbound::ControlCancelRequest(_)
        | ClaudeOutbound::ControlResponse(_)
        | ClaudeOutbound::StreamlinedText(_)
        | ClaudeOutbound::StreamlinedToolUseSummary(_)
        | ClaudeOutbound::Other => None,
    }
}

/// Streaming Bash parser: walk `call.input_buf[call.bash_cursor..]` looking
/// for the contents of the `"command"` JSON string, emit each new character
/// (with backslash-escapes resolved) and advance the cursor.
fn bash_command_emit(call: &mut OpenToolCall) -> String {
    let mut out = String::new();
    let bytes = call.input_buf.as_bytes();
    let mut i = call.bash_cursor;
    while i < bytes.len() {
        if !call.bash_in_command_value {
            // Look for `"command"` followed by `:` followed by `"`.
            if let Some(start) = find_command_string_start(call.input_buf.as_str(), i) {
                call.bash_in_command_value = true;
                i = start;
                continue;
            } else {
                // The `"command"` opening might be split across deltas — wait
                // for more bytes.
                break;
            }
        }
        // Inside the JSON string. Emit chars until we hit an unescaped `"`.
        let b = bytes[i];
        if b == b'\\' {
            // Need at least one more byte to know what to do.
            if i + 1 >= bytes.len() {
                break;
            }
            let escape = bytes[i + 1];
            let (decoded, advance) = match escape {
                b'"' => ('"', 2),
                b'\\' => ('\\', 2),
                b'/' => ('/', 2),
                b'n' => ('\n', 2),
                b't' => ('\t', 2),
                b'r' => ('\r', 2),
                b'b' => ('\x08', 2),
                b'f' => ('\x0C', 2),
                b'u' => {
                    if i + 6 > bytes.len() {
                        break;
                    }
                    let hex = &call.input_buf[i + 2..i + 6];
                    match u32::from_str_radix(hex, 16).ok().and_then(char::from_u32) {
                        Some(c) => (c, 6),
                        None => ('?', 6),
                    }
                }
                _ => (escape as char, 2),
            };
            out.push(decoded);
            i += advance;
            continue;
        }
        if b == b'"' {
            // End of command string.
            call.bash_in_command_value = false;
            i += 1;
            break;
        }
        // Plain UTF-8 character: copy through. Slice forward to the next
        // char boundary so we never split a multibyte sequence.
        let next = next_char_boundary(call.input_buf.as_str(), i);
        out.push_str(&call.input_buf[i..next]);
        i = next;
    }
    call.bash_cursor = i;
    out
}

fn find_command_string_start(buf: &str, from: usize) -> Option<usize> {
    let needle = "\"command\"";
    let idx = buf[from..].find(needle)? + from;
    let mut j = idx + needle.len();
    let bytes = buf.as_bytes();
    while j < bytes.len() && bytes[j].is_ascii_whitespace() {
        j += 1;
    }
    if j >= bytes.len() || bytes[j] != b':' {
        return None;
    }
    j += 1;
    while j < bytes.len() && bytes[j].is_ascii_whitespace() {
        j += 1;
    }
    if j >= bytes.len() || bytes[j] != b'"' {
        return None;
    }
    Some(j + 1)
}

fn next_char_boundary(s: &str, mut i: usize) -> usize {
    i += 1;
    while i < s.len() && !s.is_char_boundary(i) {
        i += 1;
    }
    i
}

fn extract_bash_command(input_buf: &str) -> String {
    serde_json::from_str::<Value>(input_buf)
        .ok()
        .and_then(|v| {
            v.get("command")
                .and_then(|c| c.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default()
}

/// Map claude's TaskUpdate status string ("pending" | "in_progress" |
/// "completed") to the codex `TurnPlanStepStatus` enum. Unknown values
/// stay Pending — the bridge never invents new statuses.
fn parse_todo_status(status: &str) -> TurnPlanStepStatus {
    match status {
        "in_progress" => TurnPlanStepStatus::InProgress,
        "completed" => TurnPlanStepStatus::Completed,
        _ => TurnPlanStepStatus::Pending,
    }
}

/// Build a `Vec<FileUpdateChange>` from a claude file-mutating tool's
/// arguments. Emits one entry per file edited, with a hand-rolled
/// unified-diff hunk in the `diff` field. Returns empty when args are
/// missing or unparseable — callers fall back to `changes: vec![]` and
/// the file-change card renders blank, which is what current behavior
/// already does.
///
/// Hunk synthesis is deliberately naive: we don't have line numbers from
/// the model's `old_string` / `new_string`, so we emit
/// `@@ -1,N +1,M @@` with the entire old as `-` and entire new as `+`.
/// Renderers that detect added/removed lines via the `+` / `-` prefix
/// (litter, codex's tui) work fine; renderers that need accurate line
/// numbers can still fall back to a "modified" pill.
pub(crate) fn synthesize_file_changes(tool_name: &str, args: &Value) -> Vec<FileUpdateChange> {
    match tool_name {
        "Write" => {
            let path = args
                .get("file_path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let content = args.get("content").and_then(Value::as_str).unwrap_or("");
            if path.is_empty() {
                return Vec::new();
            }
            vec![FileUpdateChange {
                path,
                kind: PatchChangeKind::Add,
                diff: unified_addition(content),
            }]
        }
        "Edit" => {
            let path = args
                .get("file_path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let old = args.get("old_string").and_then(Value::as_str).unwrap_or("");
            let new = args.get("new_string").and_then(Value::as_str).unwrap_or("");
            if path.is_empty() {
                return Vec::new();
            }
            vec![FileUpdateChange {
                path,
                kind: PatchChangeKind::Update { move_path: None },
                diff: unified_hunk(old, new),
            }]
        }
        "MultiEdit" => {
            let path = args
                .get("file_path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let edits = args
                .get("edits")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if path.is_empty() || edits.is_empty() {
                return Vec::new();
            }
            let mut diff = String::new();
            for edit in &edits {
                let old = edit.get("old_string").and_then(Value::as_str).unwrap_or("");
                let new = edit.get("new_string").and_then(Value::as_str).unwrap_or("");
                diff.push_str(&unified_hunk(old, new));
            }
            vec![FileUpdateChange {
                path,
                kind: PatchChangeKind::Update { move_path: None },
                diff,
            }]
        }
        "NotebookEdit" => {
            let path = args
                .get("notebook_path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let new_source = args.get("new_source").and_then(Value::as_str).unwrap_or("");
            if path.is_empty() {
                return Vec::new();
            }
            vec![FileUpdateChange {
                path,
                kind: PatchChangeKind::Update { move_path: None },
                diff: unified_addition(new_source),
            }]
        }
        _ => Vec::new(),
    }
}

/// Build a `@@ -1,N +1,M @@` hunk for an in-place edit. `old` and `new`
/// can each contain multiple lines. Trailing-newline-less inputs still
/// render correctly — `str::lines()` strips the trailing empty line.
fn unified_hunk(old: &str, new: &str) -> String {
    let old_count = old.lines().count().max(1);
    let new_count = new.lines().count().max(1);
    let mut out = format!("@@ -1,{old_count} +1,{new_count} @@\n");
    for line in old.lines() {
        out.push('-');
        out.push_str(line);
        out.push('\n');
    }
    for line in new.lines() {
        out.push('+');
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Build a `@@ -0,0 +1,N @@` hunk for a fresh-file write — every line
/// of the new content is a `+` addition.
fn unified_addition(content: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let count = lines.len().max(1);
    let mut out = format!("@@ -0,0 +1,{count} @@\n");
    for line in &lines {
        out.push('+');
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Pull `arguments.plan` out of an ExitPlanMode tool's accumulated input
/// buffer. Returns an empty string if the JSON isn't yet parseable or the
/// `plan` field is missing/non-string.
fn parse_plan_text(input_buf: &str) -> String {
    serde_json::from_str::<Value>(input_buf)
        .ok()
        .and_then(|v| v.get("plan").and_then(|p| p.as_str()).map(str::to_string))
        .unwrap_or_default()
}

/// Cap arbitrary tool output (a Read body, a Grep result) before stuffing
/// it into `aggregated_output`. Multi-megabyte bodies otherwise inflate
/// every notification round-trip.
const EXPLORATION_OUTPUT_CAP: usize = 256 * 1024;

fn cap_aggregated_output(mut text: String) -> String {
    if text.len() <= EXPLORATION_OUTPUT_CAP {
        return text;
    }
    // Truncate on a UTF-8 char boundary.
    let mut idx = EXPLORATION_OUTPUT_CAP;
    while idx > 0 && !text.is_char_boundary(idx) {
        idx -= 1;
    }
    text.truncate(idx);
    text.push_str("\n... [truncated]");
    text
}

/// Compose the deferred ItemStarted for kinds whose canonical shape
/// requires the parsed input. Returns `None` for kinds whose
/// ItemStarted is not produced at content_block_stop (PlanExit and
/// Exploration*/WebSearch are the producers; AskUserQuestion and
/// TodoUpdate emit nothing at all).
fn build_deferred_started_item(call: &OpenToolCall, thread_id: &str) -> Option<ThreadItem> {
    let parsed: Value = serde_json::from_str(&call.input_buf).unwrap_or(Value::Null);
    match call.kind {
        CodexToolKind::PlanExit => Some(ThreadItem::Plan {
            id: call.item_id.clone(),
            text: parsed
                .get("plan")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        }),
        CodexToolKind::ExplorationRead
        | CodexToolKind::ExplorationSearch
        | CodexToolKind::ExplorationList => Some(build_exploration_command_item(
            &call.kind,
            &call.tool_name,
            &call.item_id,
            &parsed,
            CommandExecutionStatus::InProgress,
            None,
        )),
        CodexToolKind::WebSearch => Some(ThreadItem::WebSearch {
            id: call.item_id.clone(),
            query: parsed
                .get("query")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            action: Some(serde_json::json!({"type": "search"})),
        }),
        CodexToolKind::Subagent => Some(build_subagent_item(
            &call.item_id,
            thread_id,
            &parsed,
            CollabAgentToolCallStatus::InProgress,
            CollabAgentStatus::Running,
        )),
        _ => None,
    }
}

/// Compose a `CollabAgentToolCall` ThreadItem from Claude `Task` /
/// `Agent` arguments. The receiver thread is synthesized as
/// `subagent-<tool_use_id>` because the bridge doesn't yet mint a real
/// child thread id; the same synthetic id is used to key
/// `agents_states`. `subagent_type` and `description` from claude land in
/// the agent state's `message` field since the codex shape has no
/// dedicated slot for them.
fn build_subagent_item(
    item_id: &str,
    sender_thread_id: &str,
    args: &Value,
    call_status: CollabAgentToolCallStatus,
    agent_status: CollabAgentStatus,
) -> ThreadItem {
    let prompt = args
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::to_string);
    let label = subagent_label(args);
    let receiver_id = format!("subagent-{item_id}");
    let mut agents_states = std::collections::HashMap::new();
    agents_states.insert(
        receiver_id.clone(),
        CollabAgentState {
            status: agent_status,
            message: if label.is_empty() { None } else { Some(label) },
        },
    );
    ThreadItem::CollabAgentToolCall {
        id: item_id.to_string(),
        tool: CollabAgentTool::SpawnAgent,
        status: call_status,
        sender_thread_id: sender_thread_id.to_string(),
        receiver_thread_ids: vec![receiver_id],
        prompt,
        model: None,
        reasoning_effort: None,
        agents_states,
    }
}

/// Build a `ThreadItem::CommandExecution` for one of the read-only
/// exploration tools. `status` and `aggregated_output` differ between
/// the InProgress (block_stop) and Completed (tool_result) emissions.
fn build_exploration_command_item(
    kind: &CodexToolKind,
    tool_name: &str,
    item_id: &str,
    args: &Value,
    status: CommandExecutionStatus,
    aggregated_output: Option<String>,
) -> ThreadItem {
    let (command, command_actions) = match kind {
        CodexToolKind::ExplorationRead => {
            let path = args
                .get("file_path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let command = read_command(&path, args);
            let name = command_action_name(&path);
            let action = serde_json::json!({
                "type": "read",
                "command": command.clone(),
                "name": name,
                "path": path
            });
            (command, vec![action])
        }
        CodexToolKind::ExplorationSearch => {
            let pattern = args
                .get("pattern")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let path = args.get("path").and_then(Value::as_str);
            let command = grep_command(&pattern, args);
            let mut action = serde_json::json!({
                "type": "search",
                "command": command.clone(),
                "query": pattern
            });
            if let Some(p) = path {
                action["path"] = Value::String(p.to_string());
            }
            (command, vec![action])
        }
        CodexToolKind::ExplorationList => {
            let pattern = args
                .get("pattern")
                .and_then(Value::as_str)
                .map(str::to_string);
            let path = args.get("path").and_then(Value::as_str).map(str::to_string);
            let display = match (&pattern, &path) {
                (Some(p), Some(d)) => format!("{tool_name} {p} {d}"),
                (Some(p), None) => format!("{tool_name} {p}"),
                (None, Some(d)) => format!("{tool_name} {d}"),
                _ => tool_name.to_string(),
            };
            let mut action = serde_json::json!({"type": "listFiles", "command": display.clone()});
            if let Some(p) = path {
                action["path"] = Value::String(p);
            }
            if let Some(p) = pattern {
                action["pattern"] = Value::String(p);
            }
            (display, vec![action])
        }
        _ => (String::new(), Vec::new()),
    };
    ThreadItem::CommandExecution {
        id: item_id.to_string(),
        command,
        cwd: String::new(),
        process_id: None,
        source: Default::default(),
        status,
        command_actions,
        aggregated_output,
        exit_code: None,
        duration_ms: None,
    }
}

fn command_action_name(path: &str) -> String {
    path.rsplit(['/', '\\'])
        .find(|part| !part.is_empty())
        .unwrap_or("file")
        .to_string()
}

fn subagent_label(args: &Value) -> String {
    let name = json_str_arg(args, "name");
    let subagent_type = json_str_arg(args, "subagent_type");
    let description = json_str_arg(args, "description");
    let mut parts = Vec::new();
    match (name, subagent_type, description) {
        (Some(name), Some(kind), Some(description)) => {
            parts.push(format!("{name} · {kind}: {description}"));
        }
        (Some(name), Some(kind), None) => {
            parts.push(format!("{name} · {kind}"));
        }
        (Some(name), None, Some(description)) => {
            parts.push(format!("{name}: {description}"));
        }
        (Some(name), None, None) => parts.push(name.to_string()),
        (None, Some(kind), Some(description)) => {
            parts.push(format!("{kind}: {description}"));
        }
        (None, Some(kind), None) => parts.push(kind.to_string()),
        (None, None, Some(description)) => parts.push(description.to_string()),
        (None, None, None) => {}
    }
    if let Some(team_name) = json_str_arg(args, "team_name") {
        parts.push(format!("team {team_name}"));
    }
    if let Some(true) = json_bool_arg(args, "run_in_background") {
        parts.push("background".to_string());
    }
    parts.join(" · ")
}

fn read_command(path: &str, args: &Value) -> String {
    let mut details = Vec::new();
    if let Some(offset) = json_i64_arg(args, "offset") {
        details.push(format!("offset {offset}"));
    }
    if let Some(limit) = json_i64_arg(args, "limit") {
        details.push(format!("limit {limit}"));
    }
    append_details(format!("Read {path}"), details)
}

fn grep_command(pattern: &str, args: &Value) -> String {
    let mut details = Vec::new();
    if let Some(output_mode) = json_str_arg(args, "output_mode") {
        details.push(format!("mode {output_mode}"));
    }
    if let Some(head_limit) = json_i64_arg(args, "head_limit") {
        details.push(format!("head {head_limit}"));
    }
    if let Some(true) = json_bool_arg(args, "-n") {
        details.push("-n".to_string());
    }
    append_details(format!("Grep {pattern}"), details)
}

fn append_details(base: String, details: Vec<String>) -> String {
    if details.is_empty() {
        base
    } else {
        format!("{base} ({})", details.join(", "))
    }
}

fn json_i64_arg(args: &Value, key: &str) -> Option<i64> {
    args.get(key).and_then(|value| match value {
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_u64().and_then(|n| i64::try_from(n).ok())),
        Value::String(text) => text.parse::<i64>().ok(),
        _ => None,
    })
}

fn json_str_arg<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
}

fn json_bool_arg(args: &Value, key: &str) -> Option<bool> {
    args.get(key).and_then(|value| match value {
        Value::Bool(value) => Some(*value),
        Value::String(text) => match text.as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        },
        _ => None,
    })
}

/// Try to parse the streaming Edit/Write JSON and surface the partial
/// `FileUpdateChange` snapshot. Returns `None` if the buffer isn't yet a
/// valid JSON object — caller emits no notification in that case.
fn parse_partial_file_change(
    input_buf: &str,
) -> Option<Vec<alleycat_codex_proto::FileUpdateChange>> {
    let parsed: Value = serde_json::from_str(input_buf).ok()?;
    let path = parsed.get("file_path").or_else(|| parsed.get("path"))?;
    let path = path.as_str()?.to_string();
    // Use a generic FileUpdateChange::Update with the snapshot — the codex
    // proto's FileUpdateChange is shaped differently (path + diff) but we
    // surface what we have so the UI can render.
    let _ = path;
    // FileUpdateChange has a complex shape we don't fully know without
    // checking common.rs again; emit no partial for v1 and let the final
    // tool_result drive the FileChange item completion.
    None
}

fn stringify_tool_result_content(content: Option<&Value>) -> String {
    let Some(content) = content else {
        return String::new();
    };
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    if let Some(arr) = content.as_array() {
        let mut out = String::new();
        for entry in arr {
            if let Some(text) = entry.get("text").and_then(Value::as_str) {
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                out.push_str(text);
            }
        }
        return out;
    }
    content.to_string()
}

/// Pull the structured `(stdout, stderr, interrupted)` triple from a Bash
/// `tool_use_result`. Returns `(None, None, false)` when the field is absent
/// or doesn't carry the expected shape.
fn bash_extract_streams(tool_use_result: Option<&Value>) -> (Option<String>, Option<String>, bool) {
    let Some(value) = tool_use_result else {
        return (None, None, false);
    };
    let stdout = value
        .get("stdout")
        .and_then(Value::as_str)
        .map(str::to_string);
    let stderr = value
        .get("stderr")
        .and_then(Value::as_str)
        .map(str::to_string);
    let interrupted = value
        .get("interrupted")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    (stdout, stderr, interrupted)
}

fn mcp_result_split(
    inline_content: String,
    tool_use_result: Option<Value>,
    is_error: bool,
) -> (Option<Box<McpToolCallResult>>, Option<McpToolCallError>) {
    if is_error {
        let message = if !inline_content.is_empty() {
            inline_content
        } else {
            tool_use_result
                .as_ref()
                .map(|v| v.to_string())
                .unwrap_or_default()
        };
        return (
            None,
            Some(McpToolCallError {
                message,
                code: None,
                data: tool_use_result,
            }),
        );
    }
    let payload = McpToolCallResult {
        content: vec![json!({ "type": "text", "text": inline_content })],
        structured_content: tool_use_result,
        is_error: None,
        meta: None,
    };
    (Some(Box::new(payload)), None)
}

fn build_dynamic_content_items(
    inline_content: &str,
    tool_use_result: Option<Value>,
) -> Option<Vec<Value>> {
    if inline_content.is_empty() && tool_use_result.is_none() {
        return None;
    }
    let mut out = Vec::new();
    if !inline_content.is_empty() {
        out.push(json!({ "type": "text", "text": inline_content }));
    }
    if let Some(extra) = tool_use_result {
        out.push(extra);
    }
    Some(out)
}

fn parse_usage_breakdown(value: &Value) -> TokenUsageBreakdown {
    let input = value
        .get("input_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let cache_creation = value
        .get("cache_creation_input_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let cache_read = value
        .get("cache_read_input_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let output = value
        .get("output_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let cached_input = cache_creation + cache_read;
    TokenUsageBreakdown {
        total_tokens: input + cached_input + output,
        input_tokens: input,
        cached_input_tokens: cached_input,
        output_tokens: output,
        reasoning_output_tokens: 0,
    }
}

fn sum_breakdown(a: &TokenUsageBreakdown, b: &TokenUsageBreakdown) -> TokenUsageBreakdown {
    TokenUsageBreakdown {
        total_tokens: a.total_tokens + b.total_tokens,
        input_tokens: a.input_tokens + b.input_tokens,
        cached_input_tokens: a.cached_input_tokens + b.cached_input_tokens,
        output_tokens: a.output_tokens + b.output_tokens,
        reasoning_output_tokens: a.reasoning_output_tokens + b.reasoning_output_tokens,
    }
}

fn first_context_window(model_usage: &Value) -> Option<i64> {
    let obj = model_usage.as_object()?;
    obj.values()
        .find_map(|m| m.get("contextWindow").and_then(Value::as_i64))
}

/// Helper for `handlers/turn.rs`: derive a `TurnStatus`/`TurnError` pair from
/// the optional error string carried out of a result envelope.
pub fn turn_status_from_result(
    interrupted: bool,
    error_message: Option<&str>,
) -> (TurnStatus, Option<TurnError>) {
    if interrupted {
        return (TurnStatus::Interrupted, None);
    }
    if let Some(message) = error_message {
        (
            TurnStatus::Failed,
            Some(TurnError {
                message: message.to_string(),
                code: claude_error_code(message).map(str::to_string),
                codex_error_info: None,
                additional_details: None,
            }),
        )
    } else {
        (TurnStatus::Completed, None)
    }
}

/// Claude Code 把用户主动停止流式输出表示成 error result，但这不是运行故障。
/// 只匹配协议的稳定 terminal_reason 或完整内部标记，避免吞掉普通执行错误。
pub(crate) fn is_user_interrupted_result(
    result: &ResultEnvelope,
    interrupt_requested: bool,
) -> bool {
    let has_interrupt_sentinel = result
        .result
        .as_deref()
        .is_some_and(|message| message.trim() == "[Request interrupted by user]");
    let is_non_success = result.is_error || result.subtype != "success";

    (has_interrupt_sentinel && (is_non_success || interrupt_requested))
        || (interrupt_requested && result.terminal_reason.as_deref() == Some("aborted_streaming"))
}

pub(crate) const CLAUDE_AUTHENTICATION_REQUIRED_CODE: &str = "claude_authentication_required";

/// 只识别 Claude Code 已知的 OAuth 会话过期且刷新失败组合，不把工具、MCP、
/// 代理或第三方 OAuth 的普通认证失败误判为 Claude 登录失效。协议向客户端只
/// 暴露稳定 code；未同时包含两个权威片段时 fail closed，继续走通用错误提示。
pub(crate) fn is_claude_authentication_failure(message: &str) -> bool {
    let normalized = message.trim().to_ascii_lowercase();
    normalized.contains("oauth session expired") && normalized.contains("could not be refreshed")
}

fn claude_error_code(message: &str) -> Option<&'static str> {
    is_claude_authentication_failure(message).then_some(CLAUDE_AUTHENTICATION_REQUIRED_CODE)
}

fn tool_started_item(
    kind: &CodexToolKind,
    tool_name: &str,
    item_id: &str,
    args: &Value,
) -> ThreadItem {
    match kind {
        CodexToolKind::CommandExecution => ThreadItem::CommandExecution {
            id: item_id.to_string(),
            command: args
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            cwd: String::new(),
            process_id: None,
            source: Default::default(),
            status: CommandExecutionStatus::InProgress,
            command_actions: Vec::new(),
            aggregated_output: None,
            exit_code: None,
            duration_ms: None,
        },
        CodexToolKind::FileChange => ThreadItem::FileChange {
            id: item_id.to_string(),
            changes: synthesize_file_changes(tool_name, args),
            status: PatchApplyStatus::InProgress,
        },
        CodexToolKind::Mcp { server, tool } => ThreadItem::McpToolCall {
            id: item_id.to_string(),
            server: server.clone(),
            tool: tool.clone(),
            status: McpToolCallStatus::InProgress,
            arguments: args.clone(),
            mcp_app_resource_uri: None,
            result: None,
            error: None,
            duration_ms: None,
        },
        CodexToolKind::Dynamic { namespace, tool } => ThreadItem::DynamicToolCall {
            id: item_id.to_string(),
            namespace: namespace.clone(),
            tool: tool.clone(),
            arguments: args.clone(),
            status: DynamicToolCallStatus::InProgress,
            content_items: None,
            success: None,
            duration_ms: None,
        },
        CodexToolKind::PlanExit => ThreadItem::Plan {
            id: item_id.to_string(),
            text: args
                .get("plan")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        CodexToolKind::ExplorationRead
        | CodexToolKind::ExplorationSearch
        | CodexToolKind::ExplorationList => build_exploration_command_item(
            kind,
            tool_name,
            item_id,
            args,
            CommandExecutionStatus::InProgress,
            None,
        ),
        CodexToolKind::WebSearch => ThreadItem::WebSearch {
            id: item_id.to_string(),
            query: args
                .get("query")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            action: Some(serde_json::json!({"type": "search"})),
        },
        CodexToolKind::Subagent => build_subagent_item(
            item_id,
            // tool_started_item is only called for non-deferred kinds
            // (Subagent IS deferred, so this arm is unreachable in the
            // live-stream path). Provide a safe placeholder for the
            // disk-side helper which calls through this factory; the
            // disk path uses items.rs build_subagent_disk_item directly.
            "",
            args,
            CollabAgentToolCallStatus::InProgress,
            CollabAgentStatus::Running,
        ),
        // TodoUpdate is deferred and emits NO ItemStarted at all
        // (turn/plan/updated is the only carrier). This arm is
        // unreachable from the live path — kept to keep the match
        // exhaustive for callers that go through the factory directly.
        // RequestUserInput likewise is replaced by Section B.
        CodexToolKind::RequestUserInput | CodexToolKind::TodoUpdate => {
            ThreadItem::DynamicToolCall {
                id: item_id.to_string(),
                namespace: Some("claude".to_string()),
                tool: tool_name.to_string(),
                arguments: args.clone(),
                status: DynamicToolCallStatus::InProgress,
                content_items: None,
                success: None,
                duration_ms: None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pool::claude_protocol::SystemInit;
    use serde_json::json;

    fn state() -> EventTranslatorState {
        EventTranslatorState::new("th_1", "tu_1")
    }

    fn stream_event(event: RawAnthropicEvent) -> ClaudeOutbound {
        ClaudeOutbound::StreamEvent(StreamEventEnvelope {
            event,
            session_id: "s1".into(),
            parent_tool_use_id: None,
            uuid: "u1".into(),
            ttft_ms: None,
        })
    }

    fn stream_event_with_parent(event: RawAnthropicEvent, parent: &str) -> ClaudeOutbound {
        ClaudeOutbound::StreamEvent(StreamEventEnvelope {
            event,
            session_id: "s1".into(),
            parent_tool_use_id: Some(parent.into()),
            uuid: "u1".into(),
            ttft_ms: None,
        })
    }

    #[test]
    fn system_init_and_status_silent() {
        let mut s = state();
        let init = SystemInit {
            session_id: "s1".into(),
            cwd: "/tmp".into(),
            model: "haiku".into(),
            tools: vec![],
            mcp_servers: vec![],
            slash_commands: vec![],
            agents: vec![],
            skills: vec![],
            permission_mode: None,
            api_key_source: None,
            claude_code_version: None,
            output_style: None,
            uuid: None,
            extra: Default::default(),
        };
        assert!(
            s.translate(ClaudeOutbound::System(SystemEvent::Init(Box::new(init))))
                .is_empty()
        );
    }

    #[test]
    fn keep_alive_and_control_envelopes_silent() {
        let mut s = state();
        assert!(s.translate(ClaudeOutbound::KeepAlive).is_empty());
        assert!(
            s.translate(ClaudeOutbound::ControlRequest(json!({"request_id": "r1"})))
                .is_empty()
        );
        assert!(
            s.translate(ClaudeOutbound::ControlCancelRequest(
                crate::pool::claude_protocol::ControlCancelEnvelope {
                    request_id: "r1".into(),
                },
            ))
            .is_empty()
        );
        assert!(
            s.translate(ClaudeOutbound::ControlResponse(
                crate::pool::claude_protocol::ControlResponseEnvelope {
                    response: crate::pool::claude_protocol::ControlResponseInner::Success {
                        request_id: "r1".into(),
                        response: None,
                    },
                },
            ))
            .is_empty()
        );
        assert!(
            s.translate(ClaudeOutbound::StreamlinedText(json!({"text": "ok"})))
                .is_empty()
        );
        assert!(
            s.translate(ClaudeOutbound::StreamlinedToolUseSummary(
                json!({"tool": "Bash"})
            ))
            .is_empty()
        );
    }

    #[test]
    fn text_content_block_lifecycle_emits_agent_message() {
        let mut s = state();
        let started = s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 1,
            content_block: ContentBlock::Text {
                text: String::new(),
            },
        }));
        assert_eq!(started.len(), 1);
        match &started[0] {
            ServerNotification::ItemStarted(n) => match &n.item {
                ThreadItem::AgentMessage { id, text, .. } => {
                    assert!(!id.is_empty());
                    assert_eq!(text, "");
                    assert!(n.parent_item_id.is_none());
                }
                other => panic!("expected AgentMessage, got {other:?}"),
            },
            other => panic!("unexpected {other:?}"),
        }

        let delta = s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
            index: 1,
            delta: ContentBlockDelta::TextDelta { text: "Hey".into() },
        }));
        match &delta[0] {
            ServerNotification::AgentMessageDelta(n) => assert_eq!(n.delta, "Hey"),
            other => panic!("unexpected {other:?}"),
        }

        let stop = s.translate(stream_event(RawAnthropicEvent::ContentBlockStop {
            index: 1,
        }));
        match &stop[0] {
            ServerNotification::ItemCompleted(n) => match &n.item {
                ThreadItem::AgentMessage { text, .. } => assert_eq!(text, "Hey"),
                other => panic!("expected AgentMessage, got {other:?}"),
            },
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn thinking_block_lifecycle_emits_reasoning() {
        let mut s = state();
        let _ = s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::Thinking {
                thinking: String::new(),
                signature: None,
            },
        }));
        let delta = s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
            index: 0,
            delta: ContentBlockDelta::ThinkingDelta {
                thinking: "ponder".into(),
            },
        }));
        match &delta[0] {
            ServerNotification::ReasoningTextDelta(n) => assert_eq!(n.delta, "ponder"),
            other => panic!("unexpected {other:?}"),
        }
        // signature_delta is silent
        let sig = s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
            index: 0,
            delta: ContentBlockDelta::SignatureDelta {
                signature: "abc".into(),
            },
        }));
        assert!(sig.is_empty());

        let stop = s.translate(stream_event(RawAnthropicEvent::ContentBlockStop {
            index: 0,
        }));
        match &stop[0] {
            ServerNotification::ItemCompleted(n) => match &n.item {
                ThreadItem::Reasoning { content, .. } => {
                    assert_eq!(content, &vec!["ponder".to_string()]);
                }
                other => panic!("expected Reasoning, got {other:?}"),
            },
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn bash_full_lifecycle_streams_command_then_outputs_then_completes() {
        let mut s = state();
        // tool_use opens (Bash).
        let started = s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 1,
            content_block: ContentBlock::ToolUse {
                id: "toolu_1".into(),
                name: "Bash".into(),
                input: json!({}),
            },
        }));
        assert!(matches!(
            &started[0],
            ServerNotification::ItemStarted(n) if matches!(n.item, ThreadItem::CommandExecution{..})
        ));

        // input_json_delta deltas (split mid-string).
        for delta in [r#"{"command":""#, "echo ", "hi", r#"","desc":"x"}"#] {
            let _ = s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
                index: 1,
                delta: ContentBlockDelta::InputJsonDelta {
                    partial_json: delta.into(),
                },
            }));
        }
        // The streaming parser should have emitted at least one outputDelta
        // for the command itself.
        let mut command_chunks = Vec::new();
        for ev in s.translate(stream_event(RawAnthropicEvent::ContentBlockStop {
            index: 1,
        })) {
            if let ServerNotification::CommandExecutionOutputDelta(n) = ev {
                command_chunks.push(n.delta);
            }
        }
        // The block_stop trailing newline should have been emitted.
        let combined: String = command_chunks.into_iter().collect();
        assert!(combined.contains('\n'));

        // tool_result envelope.
        let user_env = ClaudeOutbound::User(UserEnvelope {
            message: json!({
                "role": "user",
                "content": [{
                    "tool_use_id": "toolu_1",
                    "type": "tool_result",
                    "content": "hi",
                    "is_error": false
                }]
            }),
            parent_tool_use_id: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            tool_use_result: None,
        });
        let completed = s.translate(user_env);
        assert!(completed.iter().any(|n| matches!(
            n,
            ServerNotification::ItemCompleted(c) if matches!(
                c.item,
                ThreadItem::CommandExecution {
                    status: CommandExecutionStatus::Completed,
                    ..
                }
            )
        )));
    }

    #[test]
    fn mcp_tool_lifecycle_emits_mcp_item() {
        let mut s = state();
        s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::ToolUse {
                id: "toolu_2".into(),
                name: "mcp__github__create_issue".into(),
                input: json!({"title": "bug"}),
            },
        }));
        let user_env = ClaudeOutbound::User(UserEnvelope {
            message: json!({
                "role": "user",
                "content": [{
                    "tool_use_id": "toolu_2",
                    "type": "tool_result",
                    "content": "{\"number\":1}",
                    "is_error": false
                }]
            }),
            parent_tool_use_id: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            tool_use_result: None,
        });
        let out = s.translate(user_env);
        let completed = out
            .into_iter()
            .find(|n| matches!(n, ServerNotification::ItemCompleted(_)))
            .expect("completion");
        let ServerNotification::ItemCompleted(c) = completed else {
            unreachable!()
        };
        match c.item {
            ThreadItem::McpToolCall {
                server,
                tool,
                status,
                ..
            } => {
                assert_eq!(server, "github");
                assert_eq!(tool, "create_issue");
                assert_eq!(status, McpToolCallStatus::Completed);
            }
            other => panic!("expected McpToolCall, got {other:?}"),
        }
    }

    #[test]
    fn unknown_tool_completes_as_dynamic_under_claude_namespace() {
        // `WebFetch` is intentionally not promoted to a canonical kind
        // (only WebSearch is); ToolSearch / TodoWrite are likewise out of
        // scope for the canonical mappings. They must still complete as
        // namespaced DynamicToolCall so the codex client can render them
        // and so wire drift on novel tool names stays visible.
        let mut s = state();
        s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::ToolUse {
                id: "toolu_3".into(),
                name: "WebFetch".into(),
                input: json!({"url": "https://example.com"}),
            },
        }));
        let user_env = ClaudeOutbound::User(UserEnvelope {
            message: json!({
                "role": "user",
                "content": [{
                    "tool_use_id": "toolu_3",
                    "type": "tool_result",
                    "content": "<html>...</html>"
                }]
            }),
            parent_tool_use_id: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            tool_use_result: None,
        });
        let out = s.translate(user_env);
        let completed = out
            .into_iter()
            .find(|n| matches!(n, ServerNotification::ItemCompleted(_)))
            .expect("completion");
        let ServerNotification::ItemCompleted(c) = completed else {
            unreachable!()
        };
        match c.item {
            ThreadItem::DynamicToolCall {
                namespace,
                tool,
                success,
                ..
            } => {
                assert_eq!(namespace.as_deref(), Some("claude"));
                assert_eq!(tool, "WebFetch");
                assert_eq!(success, Some(true));
            }
            other => panic!("expected DynamicToolCall, got {other:?}"),
        }
    }

    #[test]
    fn message_delta_usage_emits_thread_token_usage_updated() {
        let mut s = state();
        let evt = stream_event(RawAnthropicEvent::MessageDelta {
            delta: json!({"stop_reason": "end_turn"}),
            usage: json!({
                "input_tokens": 9,
                "cache_creation_input_tokens": 5974,
                "cache_read_input_tokens": 27442,
                "output_tokens": 79
            }),
            context_management: None,
        });
        let out = s.translate(evt);
        match &out[0] {
            ServerNotification::ThreadTokenUsageUpdated(n) => {
                assert_eq!(n.token_usage.last.input_tokens, 9);
                assert_eq!(n.token_usage.last.cached_input_tokens, 5974 + 27442);
                assert_eq!(n.token_usage.last.output_tokens, 79);
                assert_eq!(n.token_usage.total.input_tokens, 9);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn rate_limit_events_only_update_account_snapshot() {
        let mut s = state();
        let allowed = ClaudeOutbound::RateLimitEvent(RateLimitEnvelope {
            rate_limit_info: crate::pool::claude_protocol::RateLimitInfo {
                status: "allowed".into(),
                utilization: Some(0.57),
                resets_at: None,
                rate_limit_type: Some("five_hour".into()),
                overage_status: None,
                is_using_overage: None,
                extra: Default::default(),
            },
            uuid: "u1".into(),
            session_id: "s1".into(),
        });
        assert!(s.translate(allowed).is_empty());

        for status in ["allowed_warning", "rejected"] {
            let event = ClaudeOutbound::RateLimitEvent(RateLimitEnvelope {
                rate_limit_info: crate::pool::claude_protocol::RateLimitInfo {
                    status: status.into(),
                    utilization: Some(0.91),
                    resets_at: Some(123),
                    rate_limit_type: Some("five_hour".into()),
                    overage_status: None,
                    is_using_overage: None,
                    extra: Default::default(),
                },
                uuid: "u1".into(),
                session_id: "s1".into(),
            });
            assert!(s.translate(event).is_empty(), "status={status}");
        }
    }

    #[test]
    fn result_error_subtype_emits_error_notification() {
        let mut s = state();
        let result = ClaudeOutbound::Result(ResultEnvelope {
            subtype: "error_max_turns".into(),
            is_error: true,
            duration_ms: None,
            duration_api_ms: None,
            num_turns: None,
            result: Some("max turns exceeded".into()),
            stop_reason: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            total_cost_usd: None,
            usage: None,
            model_usage: None,
            permission_denials: vec![],
            terminal_reason: None,
            api_error_status: None,
            extra: Default::default(),
        });
        let out = s.translate(result);
        assert!(matches!(&out[0], ServerNotification::Error(_)));
    }

    #[test]
    fn user_interrupted_result_does_not_emit_error_notification() {
        let mut s = state();
        let result = ResultEnvelope {
            subtype: "error_during_execution".into(),
            is_error: true,
            duration_ms: None,
            duration_api_ms: None,
            num_turns: None,
            result: Some("[Request interrupted by user]".into()),
            stop_reason: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            total_cost_usd: None,
            usage: None,
            model_usage: None,
            permission_denials: vec![],
            terminal_reason: Some("aborted_streaming".into()),
            api_error_status: None,
            extra: Default::default(),
        };

        assert!(is_user_interrupted_result(&result, false));
        assert!(s.translate(ClaudeOutbound::Result(result)).is_empty());

        let successful_sentinel = ResultEnvelope {
            subtype: "success".into(),
            is_error: false,
            duration_ms: None,
            duration_api_ms: None,
            num_turns: None,
            result: Some("[Request interrupted by user]".into()),
            stop_reason: None,
            session_id: "s1".into(),
            uuid: "u-success".into(),
            total_cost_usd: None,
            usage: None,
            model_usage: None,
            permission_denials: vec![],
            terminal_reason: None,
            api_error_status: None,
            extra: Default::default(),
        };
        assert!(!is_user_interrupted_result(&successful_sentinel, false));
        assert!(is_user_interrupted_result(&successful_sentinel, true));

        let aborted_without_marker = ResultEnvelope {
            subtype: "error_during_execution".into(),
            is_error: true,
            duration_ms: None,
            duration_api_ms: None,
            num_turns: None,
            result: None,
            stop_reason: None,
            session_id: "s1".into(),
            uuid: "u2".into(),
            total_cost_usd: None,
            usage: None,
            model_usage: None,
            permission_denials: vec![],
            terminal_reason: Some("aborted_streaming".into()),
            api_error_status: None,
            extra: Default::default(),
        };
        assert!(!is_user_interrupted_result(&aborted_without_marker, false));
        let mut without_intent = state();
        assert!(matches!(
            &without_intent.translate(ClaudeOutbound::Result(aborted_without_marker.clone()))[0],
            ServerNotification::Error(_)
        ));
        let mut with_intent = state();
        with_intent.mark_user_interrupt_requested();
        assert!(is_user_interrupted_result(&aborted_without_marker, true));
        assert!(
            with_intent
                .translate(ClaudeOutbound::Result(aborted_without_marker))
                .is_empty()
        );
        assert_eq!(
            turn_status_from_result(true, Some("aborted_streaming")),
            (TurnStatus::Interrupted, None)
        );
    }

    #[test]
    fn oauth_expiry_emits_stable_authentication_code() {
        let mut s = state();
        let result = ClaudeOutbound::Result(ResultEnvelope {
            subtype: "error_during_execution".into(),
            is_error: true,
            duration_ms: None,
            duration_api_ms: None,
            num_turns: None,
            result: Some(
                "Failed to authenticate: OAuth session expired and could not be refreshed".into(),
            ),
            stop_reason: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            total_cost_usd: None,
            usage: None,
            model_usage: None,
            permission_denials: vec![],
            terminal_reason: None,
            api_error_status: None,
            extra: Default::default(),
        });

        let out = s.translate(result);
        let ServerNotification::Error(error) = &out[0] else {
            panic!("expected error notification");
        };
        assert_eq!(
            error.error.code.as_deref(),
            Some(CLAUDE_AUTHENTICATION_REQUIRED_CODE)
        );

        let (status, turn_error) = turn_status_from_result(
            false,
            Some("Failed to authenticate: OAuth session expired and could not be refreshed"),
        );
        assert_eq!(status, TurnStatus::Failed);
        assert_eq!(
            turn_error.and_then(|error| error.code).as_deref(),
            Some(CLAUDE_AUTHENTICATION_REQUIRED_CODE)
        );

        for unrelated_error in [
            "Invalid authentication credentials",
            "Failed to authenticate third-party tool request",
            "Failed to authenticate: OAuth provider rejected proxy request",
            "Failed to authenticate MCP OAuth token",
            "OAuth session expired",
            "Could not be refreshed after a third-party OAuth failure",
        ] {
            assert!(!is_claude_authentication_failure(unrelated_error));
            let (_, turn_error) = turn_status_from_result(false, Some(unrelated_error));
            assert_eq!(turn_error.and_then(|error| error.code), None);
        }
    }

    #[test]
    fn result_with_permission_denials_emits_one_error_per_denial() {
        let mut s = state();
        let result = ClaudeOutbound::Result(ResultEnvelope {
            subtype: "success".into(),
            is_error: false,
            duration_ms: None,
            duration_api_ms: None,
            num_turns: None,
            result: None,
            stop_reason: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            total_cost_usd: None,
            usage: None,
            model_usage: None,
            permission_denials: vec![
                json!({"tool":"Bash","reason":"denied"}),
                json!({"tool":"Edit","reason":"denied"}),
            ],
            terminal_reason: Some("completed".into()),
            api_error_status: None,
            extra: Default::default(),
        });
        let out = s.translate(result);
        let errors = out
            .iter()
            .filter(|n| matches!(n, ServerNotification::Error(_)))
            .count();
        assert_eq!(errors, 2);
    }

    #[test]
    fn subagent_event_known_parent_stamps_parent_item_id() {
        let mut s = state();
        // Open a Task tool with id = "task_parent".
        let _ = s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::ToolUse {
                id: "task_parent".into(),
                name: "Task".into(),
                input: json!({}),
            },
        }));
        // Now a subagent emits a text block.
        let started = s.translate(stream_event_with_parent(
            RawAnthropicEvent::ContentBlockStart {
                index: 1,
                content_block: ContentBlock::Text {
                    text: String::new(),
                },
            },
            "task_parent",
        ));
        match &started[0] {
            ServerNotification::ItemStarted(n) => {
                assert_eq!(n.parent_item_id.as_deref(), Some("task_parent"));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn subagent_event_unknown_parent_buffered_then_replayed_when_parent_arrives() {
        let mut s = state();
        // Emit subagent first — should be buffered (no notifications).
        let early = s.translate(stream_event_with_parent(
            RawAnthropicEvent::ContentBlockStart {
                index: 1,
                content_block: ContentBlock::Text {
                    text: String::new(),
                },
            },
            "task_late",
        ));
        assert!(early.is_empty());
        // Now the parent Task lands. Its content_block_start no longer
        // emits ItemStarted directly (Task is deferred to block_stop now
        // that Subagent is canonical-shaped); but the buffered subagent
        // event replays immediately because subagent_parents got
        // populated regardless. So we expect exactly the replayed
        // subagent ItemStarted{AgentMessage} with parent_item_id set.
        let now = s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::ToolUse {
                id: "task_late".into(),
                name: "Task".into(),
                input: json!({}),
            },
        }));
        let parent_stamp = now
            .iter()
            .filter_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .find(|n| matches!(&n.item, ThreadItem::AgentMessage { .. }))
            .expect("subagent message item");
        assert_eq!(parent_stamp.parent_item_id.as_deref(), Some("task_late"));
    }

    #[test]
    fn exit_plan_mode_emits_plan_item_after_block_stop_then_completes_on_success() {
        let mut s = state();
        // Tool open — must NOT emit a placeholder DynamicToolCall.
        let started = s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::ToolUse {
                id: "toolu_plan".into(),
                name: "ExitPlanMode".into(),
                input: json!({}),
            },
        }));
        assert!(
            started.is_empty(),
            "PlanExit must defer ItemStarted until input parses; got {started:?}"
        );

        // Stream the input JSON in chunks.
        for chunk in [r#"{"plan":""#, "Step 1\\n", "Step 2", r#""}"#] {
            let _ = s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
                index: 0,
                delta: ContentBlockDelta::InputJsonDelta {
                    partial_json: chunk.into(),
                },
            }));
        }

        // content_block_stop should now emit ItemStarted{Plan}.
        let stop = s.translate(stream_event(RawAnthropicEvent::ContentBlockStop {
            index: 0,
        }));
        let plan_started = stop
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("ItemStarted{Plan}");
        match &plan_started.item {
            ThreadItem::Plan { id, text } => {
                assert_eq!(id, "toolu_plan");
                assert_eq!(text, "Step 1\nStep 2");
            }
            other => panic!("expected Plan item, got {other:?}"),
        }

        // tool_result success → ItemCompleted{Plan}, no Warning.
        let completed = s.translate(ClaudeOutbound::User(UserEnvelope {
            message: json!({
                "role": "user",
                "content": [{
                    "tool_use_id": "toolu_plan",
                    "type": "tool_result",
                    "content": "approved",
                    "is_error": false
                }]
            }),
            parent_tool_use_id: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            tool_use_result: None,
        }));
        let has_completed_plan = completed.iter().any(|n| matches!(
            n,
            ServerNotification::ItemCompleted(c) if matches!(&c.item, ThreadItem::Plan { id, text } if id == "toolu_plan" && text == "Step 1\nStep 2")
        ));
        assert!(
            has_completed_plan,
            "expected ItemCompleted{{Plan}}; got {completed:?}"
        );
        assert!(
            !completed
                .iter()
                .any(|n| matches!(n, ServerNotification::Warning(_))),
            "no Warning on success"
        );
    }

    fn run_tool_lifecycle(
        s: &mut EventTranslatorState,
        tool_use_id: &str,
        name: &str,
        input_json: &str,
        result_content: &str,
        is_error: bool,
    ) -> Vec<ServerNotification> {
        let mut out = Vec::new();
        out.extend(
            s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
                index: 7,
                content_block: ContentBlock::ToolUse {
                    id: tool_use_id.into(),
                    name: name.into(),
                    input: json!({}),
                },
            })),
        );
        out.extend(
            s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
                index: 7,
                delta: ContentBlockDelta::InputJsonDelta {
                    partial_json: input_json.into(),
                },
            })),
        );
        out.extend(
            s.translate(stream_event(RawAnthropicEvent::ContentBlockStop {
                index: 7,
            })),
        );
        out.extend(s.translate(ClaudeOutbound::User(UserEnvelope {
            message: json!({
                "role": "user",
                "content": [{
                    "tool_use_id": tool_use_id,
                    "type": "tool_result",
                    "content": result_content,
                    "is_error": is_error,
                }]
            }),
            parent_tool_use_id: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            tool_use_result: None,
        })));
        out
    }

    #[test]
    fn read_tool_lifecycle_emits_command_execution_with_read_action() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_read",
            "Read",
            r#"{"file_path":"/tmp/x.txt"}"#,
            "hello world",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("ItemStarted{CommandExecution}");
        match &started.item {
            ThreadItem::CommandExecution {
                command,
                command_actions,
                status,
                ..
            } => {
                assert_eq!(command, "Read /tmp/x.txt");
                assert_eq!(command_actions[0]["type"], "read");
                assert_eq!(command_actions[0]["command"], "Read /tmp/x.txt");
                assert_eq!(command_actions[0]["name"], "x.txt");
                assert_eq!(command_actions[0]["path"], "/tmp/x.txt");
                assert_eq!(*status, CommandExecutionStatus::InProgress);
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .expect("ItemCompleted{CommandExecution}");
        match &completed.item {
            ThreadItem::CommandExecution {
                aggregated_output,
                status,
                ..
            } => {
                assert_eq!(aggregated_output.as_deref(), Some("hello world"));
                assert_eq!(*status, CommandExecutionStatus::Completed);
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
    }

    #[test]
    fn read_tool_lifecycle_preserves_offset_and_limit_in_command_text() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_read_range",
            "Read",
            r#"{"file_path":"/tmp/x.txt","offset":40,"limit":20}"#,
            "hello world",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("ItemStarted{CommandExecution}");
        match &started.item {
            ThreadItem::CommandExecution {
                command,
                command_actions,
                ..
            } => {
                assert_eq!(command, "Read /tmp/x.txt (offset 40, limit 20)");
                assert_eq!(
                    command_actions[0]["command"],
                    "Read /tmp/x.txt (offset 40, limit 20)"
                );
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
    }

    #[test]
    fn grep_tool_lifecycle_emits_search_action() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_grep",
            "Grep",
            r#"{"pattern":"foo","path":"src"}"#,
            "src/x.rs:1:foo\n",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("Grep ItemStarted");
        match &started.item {
            ThreadItem::CommandExecution {
                command,
                command_actions,
                ..
            } => {
                assert_eq!(command, "Grep foo");
                assert_eq!(command_actions[0]["type"], "search");
                assert_eq!(command_actions[0]["command"], "Grep foo");
                assert_eq!(command_actions[0]["query"], "foo");
                assert_eq!(command_actions[0]["path"], "src");
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
    }

    #[test]
    fn grep_tool_lifecycle_preserves_output_options_in_command_text() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_grep_options",
            "Grep",
            r#"{"pattern":"foo","path":"src","output_mode":"files_with_matches","head_limit":5,"-n":true}"#,
            "src/x.rs\n",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("Grep ItemStarted");
        match &started.item {
            ThreadItem::CommandExecution {
                command,
                command_actions,
                ..
            } => {
                assert_eq!(command, "Grep foo (mode files_with_matches, head 5, -n)");
                assert_eq!(
                    command_actions[0]["command"],
                    "Grep foo (mode files_with_matches, head 5, -n)"
                );
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
    }

    #[test]
    fn glob_tool_lifecycle_emits_list_files_action() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_glob",
            "Glob",
            r#"{"pattern":"*.rs"}"#,
            "src/lib.rs\nsrc/main.rs\n",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("Glob ItemStarted");
        match &started.item {
            ThreadItem::CommandExecution {
                command,
                command_actions,
                ..
            } => {
                assert_eq!(command, "Glob *.rs");
                assert_eq!(command_actions[0]["type"], "listFiles");
                assert_eq!(command_actions[0]["command"], "Glob *.rs");
                assert_eq!(command_actions[0]["pattern"], "*.rs");
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
    }

    #[test]
    fn web_search_tool_lifecycle_emits_web_search_item() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_web",
            "WebSearch",
            r#"{"query":"rust async"}"#,
            "{\"results\":[]}",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("WebSearch ItemStarted");
        match &started.item {
            ThreadItem::WebSearch { query, action, .. } => {
                assert_eq!(query, "rust async");
                assert_eq!(action.as_ref().unwrap()["type"], "search");
            }
            other => panic!("expected WebSearch, got {other:?}"),
        }
        assert!(out.iter().any(|n| matches!(
            n,
            ServerNotification::ItemCompleted(c) if matches!(&c.item, ThreadItem::WebSearch { .. })
        )));
    }

    #[test]
    fn write_tool_emits_filechange_with_addition_diff() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_w",
            "Write",
            r#"{"file_path":"/tmp/new.txt","content":"alpha\nbeta\n"}"#,
            "wrote 12 bytes",
            false,
        );
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .expect("Write ItemCompleted");
        match &completed.item {
            ThreadItem::FileChange {
                changes, status, ..
            } => {
                assert!(matches!(status, PatchApplyStatus::Completed));
                assert_eq!(changes.len(), 1);
                assert_eq!(changes[0].path, "/tmp/new.txt");
                assert!(matches!(changes[0].kind, PatchChangeKind::Add));
                assert!(changes[0].diff.starts_with("@@ -0,0 +1,2 @@"));
                assert!(changes[0].diff.contains("+alpha"));
                assert!(changes[0].diff.contains("+beta"));
            }
            other => panic!("expected FileChange, got {other:?}"),
        }
    }

    #[test]
    fn edit_tool_emits_filechange_with_hunk_diff() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_e",
            "Edit",
            r#"{"file_path":"/tmp/x.txt","old_string":"foo","new_string":"bar"}"#,
            "1 replacement",
            false,
        );
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .expect("Edit ItemCompleted");
        match &completed.item {
            ThreadItem::FileChange { changes, .. } => {
                assert_eq!(changes.len(), 1);
                assert_eq!(changes[0].path, "/tmp/x.txt");
                assert!(matches!(changes[0].kind, PatchChangeKind::Update { .. }));
                assert!(changes[0].diff.contains("-foo"));
                assert!(changes[0].diff.contains("+bar"));
            }
            other => panic!("expected FileChange, got {other:?}"),
        }
    }

    #[test]
    fn multi_edit_tool_concatenates_hunks() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_me",
            "MultiEdit",
            r#"{"file_path":"/x","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#,
            "2 replacements",
            false,
        );
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .unwrap();
        match &completed.item {
            ThreadItem::FileChange { changes, .. } => {
                assert_eq!(changes.len(), 1);
                assert!(changes[0].diff.contains("-a"));
                assert!(changes[0].diff.contains("+b"));
                assert!(changes[0].diff.contains("-c"));
                assert!(changes[0].diff.contains("+d"));
            }
            other => panic!("expected FileChange, got {other:?}"),
        }
    }

    #[test]
    fn task_tool_lifecycle_emits_collab_agent_tool_call() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_task",
            "Task",
            r#"{"prompt":"do thing","subagent_type":"Explore","description":"find files"}"#,
            "subagent done",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("Task ItemStarted");
        match &started.item {
            ThreadItem::CollabAgentToolCall {
                tool,
                status,
                sender_thread_id,
                receiver_thread_ids,
                prompt,
                agents_states,
                ..
            } => {
                assert!(matches!(
                    tool,
                    alleycat_codex_proto::CollabAgentTool::SpawnAgent
                ));
                assert!(matches!(status, CollabAgentToolCallStatus::InProgress));
                assert_eq!(sender_thread_id, "th_1");
                assert_eq!(
                    receiver_thread_ids,
                    &vec!["subagent-toolu_task".to_string()]
                );
                assert_eq!(prompt.as_deref(), Some("do thing"));
                let state = agents_states
                    .get("subagent-toolu_task")
                    .expect("agent state");
                assert!(matches!(state.status, CollabAgentStatus::Running));
                assert_eq!(state.message.as_deref(), Some("Explore: find files"));
            }
            other => panic!("expected CollabAgentToolCall, got {other:?}"),
        }
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .expect("Task ItemCompleted");
        match &completed.item {
            ThreadItem::CollabAgentToolCall {
                status,
                agents_states,
                ..
            } => {
                assert!(matches!(status, CollabAgentToolCallStatus::Completed));
                let state = agents_states.values().next().expect("agent state");
                assert!(matches!(state.status, CollabAgentStatus::Completed));
            }
            other => panic!("expected CollabAgentToolCall completion, got {other:?}"),
        }
    }

    #[test]
    fn agent_tool_lifecycle_preserves_team_name_and_background_in_state_message() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_agent",
            "Agent",
            r#"{"prompt":"do thing","name":"ios-reader","subagent_type":"Explore","description":"find files","team_name":"litter-ios","run_in_background":true}"#,
            "subagent done",
            false,
        );
        let started = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemStarted(n) => Some(n),
                _ => None,
            })
            .expect("Agent ItemStarted");
        match &started.item {
            ThreadItem::CollabAgentToolCall { agents_states, .. } => {
                let state = agents_states
                    .get("subagent-toolu_agent")
                    .expect("agent state");
                assert_eq!(
                    state.message.as_deref(),
                    Some("ios-reader · Explore: find files · team litter-ios · background")
                );
            }
            other => panic!("expected CollabAgentToolCall, got {other:?}"),
        }
    }

    #[test]
    fn task_tool_failure_marks_agent_state_errored() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_task_err",
            "Agent",
            r#"{"prompt":"x","subagent_type":"y"}"#,
            "agent crashed",
            true,
        );
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .expect("Agent ItemCompleted");
        match &completed.item {
            ThreadItem::CollabAgentToolCall {
                status,
                agents_states,
                ..
            } => {
                assert!(matches!(status, CollabAgentToolCallStatus::Failed));
                let state = agents_states.values().next().expect("agent state");
                assert!(matches!(state.status, CollabAgentStatus::Errored));
            }
            other => panic!("expected CollabAgentToolCall, got {other:?}"),
        }
    }

    #[test]
    fn ask_user_question_stream_events_emit_no_duplicate_request() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_ask",
            "AskUserQuestion",
            r#"{"questions":[{"header":"Pick","question":"Which one?","options":[{"label":"A","description":"first"},{"label":"B","description":"second"}],"multiSelect":false}]}"#,
            "",
            false,
        );
        assert!(
            out.iter().all(|n| !matches!(
                n,
                ServerNotification::ItemStarted(_)
                    | ServerNotification::ItemCompleted(_)
                    | ServerNotification::DynamicToolCallArgumentsDelta(_)
            )),
            "AskUserQuestion must not emit any UI notifications; got {out:?}"
        );
    }

    #[test]
    fn task_create_then_update_emits_turn_plan_updated_with_step_status_changes() {
        let mut s = state();
        // TaskCreate — input has subject; result returns the new id.
        let create_out = run_tool_lifecycle(
            &mut s,
            "toolu_tc",
            "TaskCreate",
            r#"{"subject":"write the plan","activeForm":"Writing the plan"}"#,
            r#"{"id":"task-1","subject":"write the plan","status":"pending"}"#,
            false,
        );
        let plan_after_create = create_out
            .iter()
            .find_map(|n| match n {
                ServerNotification::TurnPlanUpdated(n) => Some(n),
                _ => None,
            })
            .expect("TurnPlanUpdated after TaskCreate");
        assert_eq!(plan_after_create.plan.len(), 1);
        assert_eq!(plan_after_create.plan[0].step, "write the plan");
        assert!(matches!(
            plan_after_create.plan[0].status,
            TurnPlanStepStatus::Pending
        ));
        // Disk-side ItemStarted/Completed must NOT fire for TodoUpdate.
        assert!(
            !create_out.iter().any(|n| matches!(
                n,
                ServerNotification::ItemStarted(_) | ServerNotification::ItemCompleted(_)
            )),
            "TodoUpdate must not emit ThreadItem notifications; got {create_out:?}"
        );

        // TaskUpdate flips status to in_progress.
        let update_out = run_tool_lifecycle(
            &mut s,
            "toolu_tu",
            "TaskUpdate",
            r#"{"taskId":"task-1","status":"in_progress"}"#,
            "{}",
            false,
        );
        let plan_after_update = update_out
            .iter()
            .find_map(|n| match n {
                ServerNotification::TurnPlanUpdated(n) => Some(n),
                _ => None,
            })
            .expect("TurnPlanUpdated after TaskUpdate");
        assert_eq!(plan_after_update.plan.len(), 1);
        assert!(matches!(
            plan_after_update.plan[0].status,
            TurnPlanStepStatus::InProgress
        ));

        // Second TaskUpdate flips status to completed.
        let final_out = run_tool_lifecycle(
            &mut s,
            "toolu_tu2",
            "TaskUpdate",
            r#"{"taskId":"task-1","status":"completed"}"#,
            "{}",
            false,
        );
        let plan_final = final_out
            .iter()
            .find_map(|n| match n {
                ServerNotification::TurnPlanUpdated(n) => Some(n),
                _ => None,
            })
            .expect("TurnPlanUpdated after final TaskUpdate");
        assert!(matches!(
            plan_final.plan[0].status,
            TurnPlanStepStatus::Completed
        ));
    }

    #[test]
    fn task_update_with_unknown_id_emits_no_notification() {
        let mut s = state();
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_tu_orphan",
            "TaskUpdate",
            r#"{"taskId":"never-created","status":"completed"}"#,
            "{}",
            false,
        );
        assert!(
            !out.iter()
                .any(|n| matches!(n, ServerNotification::TurnPlanUpdated(_))),
            "unknown taskId must not trigger an emit"
        );
    }

    #[test]
    fn read_tool_caps_aggregated_output_at_256_kib() {
        let mut s = state();
        let big_body = "A".repeat(300 * 1024);
        let out = run_tool_lifecycle(
            &mut s,
            "toolu_read_big",
            "Read",
            r#"{"file_path":"/big.txt"}"#,
            &big_body,
            false,
        );
        let completed = out
            .iter()
            .find_map(|n| match n {
                ServerNotification::ItemCompleted(c) => Some(c),
                _ => None,
            })
            .expect("ItemCompleted");
        match &completed.item {
            ThreadItem::CommandExecution {
                aggregated_output, ..
            } => {
                let body = aggregated_output.as_deref().unwrap();
                assert!(
                    body.len() < 300 * 1024,
                    "expected truncated; got {}",
                    body.len()
                );
                assert!(body.ends_with("[truncated]"));
            }
            other => panic!("expected CommandExecution, got {other:?}"),
        }
    }

    #[test]
    fn exit_plan_mode_rejection_emits_completed_plan_plus_warning() {
        let mut s = state();
        s.translate(stream_event(RawAnthropicEvent::ContentBlockStart {
            index: 0,
            content_block: ContentBlock::ToolUse {
                id: "toolu_plan2".into(),
                name: "ExitPlanMode".into(),
                input: json!({}),
            },
        }));
        let _ = s.translate(stream_event(RawAnthropicEvent::ContentBlockDelta {
            index: 0,
            delta: ContentBlockDelta::InputJsonDelta {
                partial_json: r#"{"plan":"do thing"}"#.into(),
            },
        }));
        let _ = s.translate(stream_event(RawAnthropicEvent::ContentBlockStop {
            index: 0,
        }));

        let completed = s.translate(ClaudeOutbound::User(UserEnvelope {
            message: json!({
                "role": "user",
                "content": [{
                    "tool_use_id": "toolu_plan2",
                    "type": "tool_result",
                    "content": "user said no",
                    "is_error": true
                }]
            }),
            parent_tool_use_id: None,
            session_id: "s1".into(),
            uuid: "u1".into(),
            tool_use_result: None,
        }));
        // Plan still completes (the card persists).
        assert!(completed.iter().any(|n| matches!(
            n,
            ServerNotification::ItemCompleted(c) if matches!(&c.item, ThreadItem::Plan { .. })
        )));
        // Warning carries the rejection reason.
        let warn = completed
            .iter()
            .find_map(|n| match n {
                ServerNotification::Warning(w) => Some(w),
                _ => None,
            })
            .expect("Warning notification on rejection");
        assert!(
            warn.message.contains("user said no"),
            "got {:?}",
            warn.message
        );
    }
}
