//! Read a claude on-disk transcript JSONL file and translate it into
//! `Vec<Turn>` of `Vec<ThreadItem>`.
//!
//! Wire vs disk discrepancies (per the wire-corrections addendum):
//! - The on-disk lines for one assistant message are split across multiple
//!   JSONL records that share `message.id`; we merge by id before emitting
//!   codex items.
//! - The structured tool-result lives at top level under either
//!   `tool_use_result` (live wire) or `toolUseResult` (camelCase, on-disk).
//!   `OnDiskRecord::tool_use_result` accepts both via `serde(alias)`.
//!
//! Turn boundaries: each top-level `user` message anchors a new turn; every
//! assistant + tool-result record between two `user` records belongs to the
//! preceding turn.

use std::collections::HashMap;
use std::path::Path;

use anyhow::Result;
use serde::Deserialize;
use serde_json::Value;
use tokio::fs;

use alleycat_codex_proto::{
    CollabAgentState, CollabAgentStatus, CollabAgentTool, CollabAgentToolCallStatus,
    CommandExecutionStatus, DynamicToolCallStatus, McpToolCallError, McpToolCallResult,
    McpToolCallStatus, PatchApplyStatus, ThreadItem, Turn, TurnStatus, UserInput,
};

use crate::translate::tool_call::{CodexToolKind, classify};

/// Read the JSONL transcript at `path` and convert it into per-turn codex
/// items. Lines that fail to parse are skipped with a warning so a single
/// malformed record can't poison the listing.
pub async fn messages_to_turns(path: &Path) -> Result<Vec<Turn>> {
    let text = match fs::read_to_string(path).await {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    Ok(messages_text_to_turns(&text))
}

/// Convert already-read JSONL transcript text into per-turn codex items.
/// Embedders with remote launchers use this after fetching the transcript over
/// their transport instead of reading from the bridge process filesystem.
pub fn messages_text_to_turns(text: &str) -> Vec<Turn> {
    let records = parse_jsonl(text);
    records_to_turns(&records)
}

/// Walk the on-disk transcript and return the per-record `uuid` of every
/// "real" user message, in chronological order. Tool-result-only user records
/// (where the message content is exclusively `tool_result` blocks) are
/// skipped — those don't anchor a codex turn and would mis-bias rollback
/// counts. Used by `handle_thread_rollback` to compute the
/// `user_message_id` argument for `control_request{rewind_files}`.
pub async fn list_user_message_ids(path: &Path) -> Result<Vec<String>> {
    let text = match fs::read_to_string(path).await {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    Ok(list_user_message_ids_from_text(&text))
}

/// Return user-message ids from already-read JSONL transcript text.
pub fn list_user_message_ids_from_text(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for record in parse_jsonl(text) {
        if record.record_type != "user" {
            continue;
        }
        if record.is_meta {
            continue;
        }
        let Some(uuid) = record.uuid.as_deref() else {
            continue;
        };
        let Some(message) = &record.message else {
            continue;
        };
        let content = message.get("content").unwrap_or(&Value::Null);
        if is_internal_user_content(content) {
            continue;
        }
        // Skip tool-result-only user records (these are claude's tool loop
        // feeding results back, not a fresh user turn).
        let is_tool_result_only = content.as_array().is_some_and(|arr| {
            !arr.is_empty()
                && arr
                    .iter()
                    .all(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
        });
        if is_tool_result_only {
            continue;
        }
        out.push(uuid.to_string());
    }
    out
}

/// Walk the on-disk transcript and return the most recent assistant
/// `message.model` value (e.g. `"claude-opus-4-7"`). Used as a fallback when
/// answering `thread/resume` / `thread/fork` against a thread the bridge
/// process hasn't run yet — claude only emits `system/init` (which carries
/// the live model) once the first user message arrives on stdin, so without
/// this fallback the response model would be empty until the user types
/// anything. Returns `None` for transcripts with no assistant records.
pub async fn last_assistant_model(path: &Path) -> Result<Option<String>> {
    let text = match fs::read_to_string(path).await {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    Ok(last_assistant_model_from_text(&text))
}

/// Variant for transports that already fetched the transcript text (remote
/// launcher path).
pub fn last_assistant_model_from_text(text: &str) -> Option<String> {
    parse_jsonl(text).into_iter().rev().find_map(|record| {
        if record.record_type != "assistant" {
            return None;
        }
        record
            .message
            .as_ref()?
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_string)
    })
}

/// Stable test seam. `messages_to_turns` calls this after reading.
pub fn parse_jsonl(text: &str) -> Vec<OnDiskRecord> {
    let mut out = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<OnDiskRecord>(trimmed) {
            Ok(record) => out.push(record),
            Err(err) => {
                tracing::warn!(?err, "skipping unparseable claude jsonl record");
            }
        }
    }
    out
}

/// Group by `message.id` (assistant) / `uuid` (user) and fold into Turns.
pub fn records_to_turns(records: &[OnDiskRecord]) -> Vec<Turn> {
    let mut builder = TurnBuilder::default();
    for record in records {
        match record.classify() {
            ClassifiedRecord::User {
                ts,
                content,
                prompt_id,
            } => {
                builder.flush_assistants();
                if let Some(true) = builder.try_fold_tool_results(&content, &record.tool_use_result)
                {
                    builder.current_completed_at = Some(ts);
                    if prompt_id.is_some() {
                        builder.current_prompt_id = prompt_id;
                    }
                    continue;
                }
                builder.push_turn();
                builder.tool_call_index.clear();
                builder.current_prompt_id = prompt_id;
                builder.current_started_at = Some(ts);
                builder.current_completed_at = Some(ts);
                let turn_index = builder.turns.len();
                builder
                    .current_items
                    .push(user_message_to_item(&content, ts, turn_index));
            }
            ClassifiedRecord::MetaUser { ts, prompt_id } => {
                // 附件尺寸等内部 meta record 会复用当前 promptId，仍属于当前 turn。
                // ScheduleWakeup 的重新唤醒会生成新的 promptId，才是真正的自主 turn。
                if prompt_id.is_some() && prompt_id == builder.current_prompt_id {
                    continue;
                }
                // ScheduleWakeup/后台继续等隐藏 user record 不应显示成用户消息，但它
                // 确实开启了一个自主 turn。先收口上一轮，避免延迟回复并入旧 turn。
                builder.flush_assistants();
                builder.push_turn();
                builder.tool_call_index.clear();
                builder.current_prompt_id = prompt_id;
                builder.current_started_at = Some(ts);
                builder.current_completed_at = Some(ts);
            }
            ClassifiedRecord::AssistantBlocks { id, ts, blocks } => {
                builder.append_assistant_blocks(id, ts, blocks);
            }
            ClassifiedRecord::Skip => {}
        }
    }
    builder.finish()
}

/// Owns the cross-record state for [`records_to_turns`]. Replaces the previous
/// 5-mutable-reference function-threading shape with a single self-borrow.
#[derive(Default)]
struct TurnBuilder {
    turns: Vec<Turn>,
    current_items: Vec<ThreadItem>,
    current_started_at: Option<i64>,
    current_completed_at: Option<i64>,
    current_prompt_id: Option<String>,
    assistant_chunks: HashMap<String, MergedAssistant>,
    assistant_order: Vec<String>,
    tool_call_index: HashMap<String, usize>,
}

impl TurnBuilder {
    fn flush_assistants(&mut self) {
        for id in self.assistant_order.drain(..) {
            let Some(merged) = self.assistant_chunks.remove(&id) else {
                continue;
            };
            self.current_completed_at = self.current_completed_at.max(Some(merged.timestamp));
            for item in merged.into_items(&mut self.tool_call_index, self.current_items.len()) {
                self.current_items.push(item);
            }
        }
    }

    fn try_fold_tool_results(
        &mut self,
        content: &Value,
        tool_use_result: &Option<Value>,
    ) -> Option<bool> {
        fold_tool_results_into_calls(
            content,
            tool_use_result,
            &mut self.current_items,
            &self.tool_call_index,
        )
    }

    fn append_assistant_blocks(&mut self, id: String, ts: i64, blocks: Vec<Value>) {
        let entry = self
            .assistant_chunks
            .entry(id.clone())
            .or_insert_with(|| MergedAssistant {
                message_id: id.clone(),
                timestamp: ts,
                blocks: Vec::new(),
            });
        if !self.assistant_order.contains(&id) {
            self.assistant_order.push(id);
        }
        entry.timestamp = entry.timestamp.max(ts);
        entry.blocks.extend(blocks);
    }

    fn push_turn(&mut self) {
        if self.current_items.is_empty() {
            return;
        }
        self.turns.push(Turn {
            id: format!("turn_{}", self.turns.len()),
            items: std::mem::take(&mut self.current_items),
            items_view: alleycat_codex_proto::default_items_view(),
            status: TurnStatus::Completed,
            error: None,
            started_at: self.current_started_at.take(),
            completed_at: self.current_completed_at.take(),
            duration_ms: None,
        });
    }

    fn finish(mut self) -> Vec<Turn> {
        self.flush_assistants();
        self.push_turn();
        self.turns
    }
}

fn user_message_to_item(content: &Value, ts: i64, turn_index: usize) -> ThreadItem {
    let inputs = match content {
        Value::String(s) => vec![UserInput::Text {
            text: s.clone(),
            text_elements: Vec::new(),
        }],
        Value::Array(arr) => arr
            .iter()
            .filter_map(|entry| {
                let block_type = entry.get("type").and_then(Value::as_str)?;
                match block_type {
                    "text" => Some(UserInput::Text {
                        text: entry
                            .get("text")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        text_elements: Vec::new(),
                    }),
                    "image" => entry
                        .get("source")
                        .and_then(image_source_to_data_url)
                        .map(|url| UserInput::Image { url }),
                    _ => None,
                }
            })
            .collect(),
        _ => Vec::new(),
    };
    ThreadItem::UserMessage {
        id: format!("user_{turn_index}_{ts}"),
        content: inputs,
        // Claude JSONL 不保存 App 生成的 clientUserMessageId；服务重启后的旧历史
        // 由 iOS 的受限语义兜底合并，运行中的 live cache 则会保留该稳定 ID。
        client_id: None,
    }
}

/// Coerce a claude `tool_use_result` value into one or more codex
/// `DynamicToolCallOutputContentItem` shapes. Codex's enum is internally
/// tagged on `type` with two variants, `inputText` and `inputImage`; raw
/// strings (e.g. claude's "user rejected this tool use" canned message),
/// objects shaped like anthropic content blocks, arrays of those, and
/// arbitrary structured payloads all need to land as one of those two
/// shapes — otherwise litter's typed deserializer rejects the whole
/// `thread/resume` response.
pub(crate) fn normalize_dynamic_tool_call_output(value: &Value) -> Vec<Value> {
    match value {
        Value::String(s) => vec![serde_json::json!({"type": "inputText", "text": s})],
        Value::Array(arr) => arr
            .iter()
            .flat_map(normalize_dynamic_tool_call_output)
            .collect(),
        Value::Object(obj) => {
            // Anthropic-style text block: `{type: "text", text: "..."}`.
            if obj.get("type").and_then(Value::as_str) == Some("text") {
                if let Some(text) = obj.get("text").and_then(Value::as_str) {
                    return vec![serde_json::json!({"type": "inputText", "text": text})];
                }
            }
            // Anthropic-style image block: `{type: "image", source: {...}}`.
            if obj.get("type").and_then(Value::as_str) == Some("image") {
                if let Some(url) = obj.get("source").and_then(image_source_to_data_url) {
                    return vec![serde_json::json!({"type": "inputImage", "imageUrl": url})];
                }
            }
            // Already-codex-shaped: pass through unchanged.
            if matches!(
                obj.get("type").and_then(Value::as_str),
                Some("inputText" | "inputImage")
            ) {
                return vec![Value::Object(obj.clone())];
            }
            // Unknown structured payload — stringify it so the client at
            // least sees something rather than silently dropping it.
            vec![serde_json::json!({
                "type": "inputText",
                "text": serde_json::to_string(value).unwrap_or_default(),
            })]
        }
        Value::Null => Vec::new(),
        other => vec![serde_json::json!({"type": "inputText", "text": other.to_string()})],
    }
}

fn image_source_to_data_url(source: &Value) -> Option<String> {
    let media_type = source.get("media_type").and_then(Value::as_str)?;
    let data = source.get("data").and_then(Value::as_str)?;
    Some(format!("data:{media_type};base64,{data}"))
}

/// Claude Code 把 `/model` 等本地命令以顶层 `user` 记录写入 transcript，
/// 但这些记录只服务 CLI 自身，不能在移动端伪装成用户发送的对话消息。
/// 这里只识别完整的保留标签包装，避免误删普通文本中对标签的讨论。
fn is_internal_user_content(content: &Value) -> bool {
    let Some(text) = content.as_str() else {
        return false;
    };
    is_internal_user_text(text)
}

/// Claude CLI 内部命令和中断标记会伪装成 user 文本；索引扫描和历史翻译必须
/// 复用同一判定，避免污染会话标题、用户气泡和 turn 锚点。
pub(crate) fn is_internal_user_text(text: &str) -> bool {
    let text = text.trim();
    text == "[Request interrupted by user]"
        || is_complete_reserved_tag(text, "local-command-caveat")
        || is_complete_reserved_tag(text, "local-command-stdout")
        || is_complete_reserved_tag(text, "local-command-stderr")
        || (text.starts_with("<command-name>")
            && text.contains("</command-name>")
            && text.contains("<command-message>")
            && text.contains("</command-message>")
            && text.contains("<command-args>")
            && text.ends_with("</command-args>"))
}

fn is_complete_reserved_tag(text: &str, tag: &str) -> bool {
    text.starts_with(&format!("<{tag}>")) && text.ends_with(&format!("</{tag}>"))
}

/// If `content` is a single `tool_result` block (no human text), fold the
/// result into the matching open tool call and return `Some(true)`. Otherwise
/// return `Some(false)` (real user message) or `None` (no recognizable shape).
fn fold_tool_results_into_calls(
    content: &Value,
    tool_use_result: &Option<Value>,
    items: &mut [ThreadItem],
    tool_call_index: &HashMap<String, usize>,
) -> Option<bool> {
    let arr = content.as_array()?;
    let all_tool_results = arr
        .iter()
        .all(|e| e.get("type").and_then(Value::as_str) == Some("tool_result"));
    if !all_tool_results {
        return Some(false);
    }
    for entry in arr {
        let Some(tool_use_id) = entry.get("tool_use_id").and_then(Value::as_str) else {
            continue;
        };
        let Some(idx) = tool_call_index.get(tool_use_id).copied() else {
            continue;
        };
        let is_error = entry
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let inline = entry
            .get("content")
            .map(stringify_content)
            .unwrap_or_default();
        complete_tool_item(&mut items[idx], inline, tool_use_result.as_ref(), is_error);
    }
    Some(true)
}

fn stringify_content(content: &Value) -> String {
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

fn complete_tool_item(
    item: &mut ThreadItem,
    inline: String,
    tool_use_result: Option<&Value>,
    is_error: bool,
) {
    match item {
        ThreadItem::CommandExecution {
            status,
            aggregated_output,
            ..
        } => {
            let stdout = tool_use_result
                .and_then(|v| v.get("stdout"))
                .and_then(Value::as_str)
                .map(str::to_string);
            let stderr = tool_use_result
                .and_then(|v| v.get("stderr"))
                .and_then(Value::as_str)
                .map(str::to_string);
            let interrupted = tool_use_result
                .and_then(|v| v.get("interrupted"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let mut combined = stdout.unwrap_or(inline);
            if let Some(stderr) = stderr {
                if !stderr.is_empty() {
                    if !combined.is_empty() && !combined.ends_with('\n') {
                        combined.push('\n');
                    }
                    combined.push_str("[stderr] ");
                    combined.push_str(&stderr);
                }
            }
            *aggregated_output = Some(cap_aggregated_output_disk(combined));
            *status = if is_error || interrupted {
                CommandExecutionStatus::Failed
            } else {
                CommandExecutionStatus::Completed
            };
        }
        ThreadItem::FileChange { status, .. } => {
            *status = if is_error {
                PatchApplyStatus::Failed
            } else {
                PatchApplyStatus::Completed
            };
        }
        ThreadItem::McpToolCall {
            status,
            result,
            error,
            ..
        } => {
            if is_error {
                *status = McpToolCallStatus::Failed;
                *error = Some(McpToolCallError {
                    message: inline,
                    code: None,
                    data: tool_use_result.cloned(),
                });
            } else {
                *status = McpToolCallStatus::Completed;
                *result = Some(Box::new(McpToolCallResult {
                    content: vec![serde_json::json!({"type": "text", "text": inline})],
                    structured_content: tool_use_result.cloned(),
                    is_error: None,
                    meta: None,
                }));
            }
        }
        ThreadItem::CollabAgentToolCall {
            status,
            agents_states,
            ..
        } => {
            if is_error {
                *status = CollabAgentToolCallStatus::Failed;
                for state in agents_states.values_mut() {
                    state.status = CollabAgentStatus::Errored;
                }
            }
        }
        ThreadItem::DynamicToolCall {
            status,
            content_items,
            success,
            ..
        } => {
            *status = if is_error {
                DynamicToolCallStatus::Failed
            } else {
                DynamicToolCallStatus::Completed
            };
            *success = Some(!is_error);
            // `DynamicToolCallOutputContentItem` is an internally-tagged enum
            // on the codex side: `{"type":"inputText","text":...}` or
            // `{"type":"inputImage","imageUrl":...}`. Bare strings (which
            // claude returns when the user rejects a tool use) and arbitrary
            // structured `tool_use_result` payloads need to be normalized
            // into that shape or the codex client errors on `thread/resume`.
            let mut items = Vec::new();
            if !inline.is_empty() {
                items.push(serde_json::json!({"type": "inputText", "text": inline}));
            }
            if let Some(extra) = tool_use_result {
                items.extend(normalize_dynamic_tool_call_output(extra));
            }
            if !items.is_empty() {
                *content_items = Some(items);
            }
        }
        _ => {}
    }
}

/// Bookkeeping for an assistant message split across multiple JSONL lines.
#[derive(Debug)]
struct MergedAssistant {
    message_id: String,
    timestamp: i64,
    blocks: Vec<Value>,
}

impl MergedAssistant {
    fn into_items(
        self,
        tool_call_index: &mut HashMap<String, usize>,
        existing_items_len: usize,
    ) -> Vec<ThreadItem> {
        let mut out = Vec::new();
        let mut text_acc = String::new();
        let mut thinking_acc: Vec<String> = Vec::new();
        let mut tool_items = Vec::new();
        for block in &self.blocks {
            let Some(t) = block.get("type").and_then(Value::as_str) else {
                continue;
            };
            match t {
                "text" => {
                    if let Some(s) = block.get("text").and_then(Value::as_str) {
                        text_acc.push_str(s);
                    }
                }
                "thinking" => {
                    if let Some(s) = block.get("thinking").and_then(Value::as_str) {
                        thinking_acc.push(s.to_string());
                    }
                }
                "tool_use" => {
                    let id = block
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    let name = block.get("name").and_then(Value::as_str).unwrap_or("");
                    let input = block.get("input").cloned().unwrap_or(Value::Null);
                    let kind = classify(name);
                    if let Some(item) = tool_call_to_item(&kind, name, id.clone(), input) {
                        tool_items.push((id, item));
                    }
                }
                _ => {}
            }
        }
        // Final order: reasoning (if any) → agent message (if any) → tool_use items.
        if !thinking_acc.is_empty() {
            out.push(ThreadItem::Reasoning {
                id: format!("reasoning_{}", self.message_id),
                summary: Vec::new(),
                content: thinking_acc,
            });
        }
        if !text_acc.is_empty() {
            out.push(ThreadItem::AgentMessage {
                id: format!("assistant_{}", self.message_id),
                text: text_acc,
                phase: Some(serde_json::Value::String("final_answer".into())),
                memory_citation: None,
            });
        }
        for (tool_use_id, item) in tool_items {
            tool_call_index.insert(tool_use_id, existing_items_len + out.len());
            out.push(item);
        }
        out
    }
}

fn tool_call_to_item(
    kind: &CodexToolKind,
    tool_name: &str,
    id: String,
    args: Value,
) -> Option<ThreadItem> {
    Some(match kind {
        CodexToolKind::CommandExecution => ThreadItem::CommandExecution {
            id,
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
            id,
            changes: crate::translate::events::synthesize_file_changes(tool_name, &args),
            status: PatchApplyStatus::InProgress,
        },
        CodexToolKind::Mcp { server, tool } => ThreadItem::McpToolCall {
            id,
            server: server.clone(),
            tool: tool.clone(),
            status: McpToolCallStatus::InProgress,
            arguments: args,
            mcp_app_resource_uri: None,
            result: None,
            error: None,
            duration_ms: None,
        },
        CodexToolKind::Dynamic { namespace, tool } => ThreadItem::DynamicToolCall {
            id,
            namespace: namespace.clone(),
            tool: tool.clone(),
            arguments: args,
            status: DynamicToolCallStatus::InProgress,
            content_items: None,
            success: None,
            duration_ms: None,
        },
        CodexToolKind::PlanExit => ThreadItem::Plan {
            id,
            text: args
                .get("plan")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        CodexToolKind::ExplorationRead
        | CodexToolKind::ExplorationSearch
        | CodexToolKind::ExplorationList => build_exploration_disk_item(kind, tool_name, id, &args),
        CodexToolKind::WebSearch => ThreadItem::WebSearch {
            id,
            query: args
                .get("query")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            action: Some(serde_json::json!({"type": "search"})),
        },
        CodexToolKind::Subagent => build_subagent_disk_item(id, &args),
        // TaskCreate / TaskUpdate / AskUserQuestion produce no
        // ThreadItem on disk replay — the live notification streams
        // (turn/plan/updated and item/tool/requestUserInput) carry the
        // user-facing data; the surrounding UserMessage / AgentMessage
        // records already preserve the question + answer text.
        CodexToolKind::TodoUpdate | CodexToolKind::RequestUserInput => return None,
    })
}

/// Cap a CommandExecution body before writing it into a disk-replayed
/// `aggregated_output`. Mirrors `events.rs::cap_aggregated_output` so
/// live-stream and replay land at the same size.
const EXPLORATION_OUTPUT_CAP_DISK: usize = 256 * 1024;

fn cap_aggregated_output_disk(mut text: String) -> String {
    if text.len() <= EXPLORATION_OUTPUT_CAP_DISK {
        return text;
    }
    let mut idx = EXPLORATION_OUTPUT_CAP_DISK;
    while idx > 0 && !text.is_char_boundary(idx) {
        idx -= 1;
    }
    text.truncate(idx);
    text.push_str("\n... [truncated]");
    text
}

/// Disk-side counterpart of `build_subagent_item` in events.rs. Disk
/// replay shows the subagent as already completed (we don't have live
/// state here), so emit `CollabAgentToolCallStatus::Completed` with
/// `CollabAgentStatus::Completed`. The `sender_thread_id` is left blank
/// — the live emission path stamps it from translator state, but disk
/// replay doesn't know which thread the record belongs to from this
/// helper. Callers higher up in the on-disk pipeline that need a real
/// sender id should patch it after the fact.
fn build_subagent_disk_item(id: String, args: &Value) -> ThreadItem {
    let prompt = args
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::to_string);
    let label = subagent_label(args);
    let receiver_id = format!("subagent-{id}");
    let mut agents_states = HashMap::new();
    agents_states.insert(
        receiver_id.clone(),
        CollabAgentState {
            status: CollabAgentStatus::Completed,
            message: if label.is_empty() { None } else { Some(label) },
        },
    );
    ThreadItem::CollabAgentToolCall {
        id,
        tool: CollabAgentTool::SpawnAgent,
        status: CollabAgentToolCallStatus::Completed,
        sender_thread_id: String::new(),
        receiver_thread_ids: vec![receiver_id],
        prompt,
        model: None,
        reasoning_effort: None,
        agents_states,
    }
}

/// Disk-side counterpart of `build_exploration_command_item` in events.rs.
/// Mirrors the same command/command_actions shape so live-stream and disk
/// replay produce identical items.
fn build_exploration_disk_item(
    kind: &CodexToolKind,
    tool_name: &str,
    id: String,
    args: &Value,
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
        id,
        command,
        cwd: String::new(),
        process_id: None,
        source: Default::default(),
        status: CommandExecutionStatus::InProgress,
        command_actions,
        aggregated_output: None,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OnDiskRecord {
    #[serde(rename = "type", default)]
    pub record_type: String,
    #[serde(default)]
    pub message: Option<Value>,
    /// Live wire field name — accepted alongside the camelCase on-disk
    /// `toolUseResult` via serde alias.
    #[serde(default, alias = "toolUseResult", alias = "tool_use_result")]
    pub tool_use_result: Option<Value>,
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub uuid: Option<String>,
    /// 同一 Claude prompt 产生的普通 user/tool-result/meta 记录共享该 id；
    /// ScheduleWakeup 重新唤醒时会换新 id，可据此区分自主 turn 与附件元数据。
    #[serde(default)]
    pub prompt_id: Option<String>,
    /// Claude Code 标记的内部提示，例如 local-command caveat。
    #[serde(default)]
    pub is_meta: bool,
    /// 工具/Skill 注入的 meta user record 仍属于当前 turn；没有来源 tool id
    /// 的 meta user record 才代表后台自主 turn 的隐藏触发边界。
    #[serde(
        default,
        rename = "sourceToolUseID",
        alias = "sourceToolUseId",
        alias = "source_tool_use_id"
    )]
    pub source_tool_use_id: Option<String>,
}

enum ClassifiedRecord {
    User {
        ts: i64,
        content: Value,
        prompt_id: Option<String>,
    },
    MetaUser {
        ts: i64,
        prompt_id: Option<String>,
    },
    AssistantBlocks {
        id: String,
        ts: i64,
        blocks: Vec<Value>,
    },
    Skip,
}

impl OnDiskRecord {
    fn classify(&self) -> ClassifiedRecord {
        let ts = self
            .timestamp
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.timestamp_millis())
            .unwrap_or(0);
        match self.record_type.as_str() {
            "user" => {
                let Some(message) = &self.message else {
                    return ClassifiedRecord::Skip;
                };
                let content = message.get("content").cloned().unwrap_or(Value::Null);
                if is_internal_user_content(&content) {
                    return ClassifiedRecord::Skip;
                }
                if self.is_meta {
                    return if self.source_tool_use_id.is_some() {
                        ClassifiedRecord::Skip
                    } else {
                        ClassifiedRecord::MetaUser {
                            ts,
                            prompt_id: self.prompt_id.clone(),
                        }
                    };
                }
                ClassifiedRecord::User {
                    ts,
                    content,
                    prompt_id: self.prompt_id.clone(),
                }
            }
            "assistant" => {
                let Some(message) = &self.message else {
                    return ClassifiedRecord::Skip;
                };
                let id = message
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let blocks = message
                    .get("content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                ClassifiedRecord::AssistantBlocks { id, ts, blocks }
            }
            // Permission mode notices, file-history snapshots, attachments,
            // bridge_status announcements: not part of the codex turn shape.
            _ => ClassifiedRecord::Skip,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn record(value: Value) -> OnDiskRecord {
        serde_json::from_value(value).expect("parse")
    }

    #[test]
    fn last_assistant_model_picks_most_recent_assistant_record() {
        let text = [
            json!({
                "type": "user",
                "message": {"role": "user", "content": "hi"},
                "uuid": "u1"
            }),
            json!({
                "type": "assistant",
                "message": {"id": "m1", "model": "claude-sonnet-4-6", "content": []}
            }),
            json!({
                "type": "user",
                "message": {"role": "user", "content": "again"},
                "uuid": "u2"
            }),
            json!({
                "type": "assistant",
                "message": {"id": "m2", "model": "claude-opus-4-7", "content": []}
            }),
        ]
        .iter()
        .map(|v| v.to_string())
        .collect::<Vec<_>>()
        .join("\n");

        assert_eq!(
            last_assistant_model_from_text(&text).as_deref(),
            Some("claude-opus-4-7"),
        );
    }

    #[test]
    fn last_assistant_model_returns_none_when_no_assistant_records() {
        let text = json!({
            "type": "user",
            "message": {"role": "user", "content": "hi"},
            "uuid": "u1"
        })
        .to_string();
        assert!(last_assistant_model_from_text(&text).is_none());
    }

    #[test]
    fn user_message_string_content_anchors_a_turn() {
        let records = vec![record(json!({
            "type": "user",
            "message": {"role": "user", "content": "hello"},
            "timestamp": "2026-04-27T10:00:00Z",
            "uuid": "u1"
        }))];
        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].items.len(), 1);
        match &turns[0].items[0] {
            ThreadItem::UserMessage { content, .. } => match &content[0] {
                UserInput::Text { text, .. } => assert_eq!(text, "hello"),
                other => panic!("expected text, got {other:?}"),
            },
            other => panic!("expected UserMessage, got {other:?}"),
        }
    }

    #[test]
    fn local_command_records_do_not_anchor_turns() {
        let records = vec![
            record(json!({
                "type": "user",
                "isMeta": true,
                "message": {
                    "role": "user",
                    "content": "<local-command-caveat>internal</local-command-caveat>"
                },
                "timestamp": "2026-07-17T05:11:52.109Z",
                "uuid": "meta"
            })),
            record(json!({
                "type": "user",
                "message": {
                    "role": "user",
                    "content": "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>sonnet</command-args>"
                },
                "timestamp": "2026-07-17T05:11:52.109Z",
                "uuid": "command"
            })),
            record(json!({
                "type": "user",
                "message": {
                    "role": "user",
                    "content": "<local-command-stdout>Set model to sonnet</local-command-stdout>"
                },
                "timestamp": "2026-07-17T05:11:52.109Z",
                "uuid": "stdout"
            })),
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "真正的用户消息"},
                "timestamp": "2026-07-17T05:11:52.573Z",
                "uuid": "real"
            })),
        ];

        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].items.len(), 1);
        match &turns[0].items[0] {
            ThreadItem::UserMessage { content, .. } => match &content[0] {
                UserInput::Text { text, .. } => assert_eq!(text, "真正的用户消息"),
                other => panic!("expected text, got {other:?}"),
            },
            other => panic!("expected UserMessage, got {other:?}"),
        }
    }

    #[test]
    fn user_interrupt_marker_is_not_a_user_turn() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "[Request interrupted by user]"},
                "timestamp": "2026-07-17T05:11:52.109Z",
                "uuid": "interrupt"
            })),
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "继续"},
                "timestamp": "2026-07-17T05:11:53.109Z",
                "uuid": "real"
            })),
        ];

        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        assert!(matches!(
            &turns[0].items[0],
            ThreadItem::UserMessage { content, .. }
                if matches!(&content[0], UserInput::Text { text, .. } if text == "继续")
        ));

        let text = [
            json!({
                "type": "user",
                "message": {"role": "user", "content": "[Request interrupted by user]"},
                "uuid": "interrupt"
            }),
            json!({
                "type": "user",
                "message": {"role": "user", "content": "继续"},
                "uuid": "real"
            }),
        ]
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
        assert_eq!(list_user_message_ids_from_text(&text), vec!["real"]);
    }

    #[test]
    fn hidden_scheduled_wakeup_starts_an_autonomous_turn() {
        let records = vec![
            record(json!({
                "type": "user",
                "promptId": "prompt-original",
                "message": {"role": "user", "content": "五分钟后回复我"},
                "timestamp": "2026-07-26T14:02:00Z",
                "uuid": "user-1"
            })),
            record(json!({
                "type": "assistant",
                "message": {
                    "id": "ack",
                    "content": [{"type": "text", "text": "好的，已经排程"}]
                },
                "timestamp": "2026-07-26T14:02:01Z"
            })),
            record(json!({
                "type": "user",
                "isMeta": true,
                "promptId": "prompt-wakeup",
                "message": {"role": "user", "content": "Scheduled wakeup fired"},
                "timestamp": "2026-07-26T14:06:06Z",
                "uuid": "autonomous-trigger"
            })),
            record(json!({
                "type": "assistant",
                "message": {
                    "id": "delayed",
                    "content": [{"type": "text", "text": "⏰ 五分钟到了，当前时间 14:06:06"}]
                },
                "timestamp": "2026-07-26T14:06:08Z"
            })),
        ];

        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 2);
        assert!(
            turns[0]
                .items
                .iter()
                .any(|item| matches!(item, ThreadItem::UserMessage { .. }))
        );
        assert!(
            !turns[1]
                .items
                .iter()
                .any(|item| matches!(item, ThreadItem::UserMessage { .. }))
        );
        assert!(turns[1].items.iter().any(
            |item| matches!(item, ThreadItem::AgentMessage { text, .. } if text.contains("14:06:06"))
        ));
    }

    #[test]
    fn image_metadata_with_same_prompt_id_does_not_split_turn() {
        let records = vec![
            record(json!({
                "type": "user",
                "promptId": "prompt-with-image",
                "message": {"role": "user", "content": "看下这张图"},
                "timestamp": "2026-07-26T14:02:00Z",
                "uuid": "user-1"
            })),
            record(json!({
                "type": "user",
                "isMeta": true,
                "promptId": "prompt-with-image",
                "message": {
                    "role": "user",
                    "content": "[Image: original 2048x1536, displayed at 1024x768]"
                },
                "timestamp": "2026-07-26T14:02:00Z",
                "uuid": "image-dimensions"
            })),
            record(json!({
                "type": "assistant",
                "message": {
                    "id": "answer",
                    "content": [{"type": "text", "text": "图片已收到"}]
                },
                "timestamp": "2026-07-26T14:02:02Z"
            })),
        ];

        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        assert_eq!(
            turns[0]
                .items
                .iter()
                .filter(|item| matches!(item, ThreadItem::UserMessage { .. }))
                .count(),
            1
        );
        assert!(turns[0].items.iter().any(
            |item| matches!(item, ThreadItem::AgentMessage { text, .. } if text == "图片已收到")
        ));
    }

    #[test]
    fn tool_sourced_meta_record_does_not_split_the_current_turn() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "执行 Skill"},
                "timestamp": "2026-07-26T14:02:00Z",
                "uuid": "user-1"
            })),
            record(json!({
                "type": "user",
                "isMeta": true,
                "sourceToolUseID": "toolu_1",
                "message": {"role": "user", "content": "Skill 内部上下文"},
                "timestamp": "2026-07-26T14:02:01Z",
                "uuid": "skill-context"
            })),
            record(json!({
                "type": "assistant",
                "message": {
                    "id": "answer",
                    "content": [{"type": "text", "text": "执行完成"}]
                },
                "timestamp": "2026-07-26T14:02:02Z"
            })),
        ];

        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        assert_eq!(
            turns[0]
                .items
                .iter()
                .filter(|item| matches!(item, ThreadItem::UserMessage { .. }))
                .count(),
            1
        );
    }

    #[test]
    fn rollback_user_ids_ignore_local_command_records() {
        let text = [
            json!({
                "type": "user",
                "isMeta": true,
                "message": {"role": "user", "content": "metadata"},
                "uuid": "meta"
            }),
            json!({
                "type": "user",
                "message": {
                    "role": "user",
                    "content": "<local-command-stdout>done</local-command-stdout>"
                },
                "uuid": "local"
            }),
            json!({
                "type": "user",
                "message": {"role": "user", "content": "real"},
                "uuid": "real"
            }),
        ]
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");

        assert_eq!(list_user_message_ids_from_text(&text), vec!["real"]);
    }

    #[test]
    fn assistant_blocks_split_across_lines_merged_by_message_id() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "q"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:01Z",
                "message": {
                    "id": "msg_1",
                    "content": [{"type": "thinking", "thinking": "ponder"}]
                }
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:02Z",
                "message": {
                    "id": "msg_1",
                    "content": [{"type": "text", "text": "answer"}]
                }
            })),
        ];
        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        let kinds: Vec<_> = turns[0]
            .items
            .iter()
            .map(|i| match i {
                ThreadItem::UserMessage { .. } => "user",
                ThreadItem::AgentMessage { .. } => "agent",
                ThreadItem::Reasoning { .. } => "reasoning",
                _ => "other",
            })
            .collect();
        assert!(kinds.contains(&"agent"));
        assert!(kinds.contains(&"reasoning"));
    }

    #[test]
    fn tool_use_then_tool_result_completes_command_execution() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "ls"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:01Z",
                "message": {
                    "id": "msg_1",
                    "content": [{
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "Bash",
                        "input": {"command": "ls"}
                    }]
                }
            })),
            record(json!({
                "type": "user",
                "timestamp": "2026-04-27T10:00:02Z",
                "message": {
                    "role": "user",
                    "content": [{
                        "tool_use_id": "toolu_1",
                        "type": "tool_result",
                        "content": "file1\nfile2"
                    }]
                },
                "toolUseResult": {
                    "stdout": "file1\nfile2",
                    "stderr": "",
                    "interrupted": false,
                    "isImage": false,
                    "noOutputExpected": false
                }
            })),
        ];
        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        let exec = turns[0]
            .items
            .iter()
            .find(|i| matches!(i, ThreadItem::CommandExecution { .. }))
            .expect("CommandExecution");
        match exec {
            ThreadItem::CommandExecution {
                command,
                status,
                aggregated_output,
                ..
            } => {
                assert_eq!(command, "ls");
                assert_eq!(*status, CommandExecutionStatus::Completed);
                assert_eq!(aggregated_output.as_deref(), Some("file1\nfile2"));
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn unmatched_tool_use_stays_in_progress() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "ls"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:01Z",
                "message": {
                    "id": "msg_1",
                    "content": [{
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "Bash",
                        "input": {"command": "ls"}
                    }]
                }
            })),
        ];
        let turns = records_to_turns(&records);
        let item = turns[0]
            .items
            .iter()
            .find(|i| matches!(i, ThreadItem::CommandExecution { .. }))
            .expect("CommandExecution");
        let ThreadItem::CommandExecution { status, .. } = item else {
            unreachable!()
        };
        assert_eq!(*status, CommandExecutionStatus::InProgress);
    }

    #[test]
    fn camel_case_and_snake_case_tool_use_result_both_parse() {
        let snake: OnDiskRecord = serde_json::from_value(json!({
            "type": "user",
            "message": {"role": "user", "content": "x"},
            "tool_use_result": {"stdout": "snake"}
        }))
        .unwrap();
        let camel: OnDiskRecord = serde_json::from_value(json!({
            "type": "user",
            "message": {"role": "user", "content": "x"},
            "toolUseResult": {"stdout": "camel"}
        }))
        .unwrap();
        assert!(snake.tool_use_result.is_some());
        assert!(camel.tool_use_result.is_some());
    }

    #[test]
    fn skip_record_types_silently_ignored() {
        let records = vec![
            record(json!({
                "type": "permission-mode",
                "permissionMode": "bypassPermissions"
            })),
            record(json!({
                "type": "file-history-snapshot",
                "messageId": "x"
            })),
            record(json!({
                "type": "attachment"
            })),
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "real"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
        ];
        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].items.len(), 1);
    }

    #[test]
    fn multiple_user_messages_split_into_multiple_turns() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "first"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:01Z",
                "message": {
                    "id": "msg_1",
                    "content": [{"type": "text", "text": "ack1"}]
                }
            })),
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "second"},
                "timestamp": "2026-04-27T10:00:02Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:03Z",
                "message": {
                    "id": "msg_2",
                    "content": [{"type": "text", "text": "ack2"}]
                }
            })),
        ];
        let turns = records_to_turns(&records);
        assert_eq!(turns.len(), 2);
    }

    #[test]
    fn normalize_dynamic_tool_call_output_wraps_bare_string() {
        // Claude returns a bare string when the user rejects a tool use;
        // codex's `DynamicToolCallOutputContentItem` requires the tagged
        // `inputText` shape or `thread/resume` deserialization fails on
        // the litter side.
        let out = normalize_dynamic_tool_call_output(&json!(
            "Error: The user doesn't want to proceed with this tool use."
        ));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["type"], "inputText");
        assert!(
            out[0]["text"]
                .as_str()
                .unwrap()
                .starts_with("Error: The user doesn't want to proceed")
        );
    }

    #[test]
    fn normalize_dynamic_tool_call_output_passes_through_input_text() {
        let out = normalize_dynamic_tool_call_output(&json!({
            "type": "inputText",
            "text": "already shaped"
        }));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["type"], "inputText");
        assert_eq!(out[0]["text"], "already shaped");
    }

    #[test]
    fn normalize_dynamic_tool_call_output_converts_anthropic_text_block() {
        let out = normalize_dynamic_tool_call_output(&json!({
            "type": "text",
            "text": "hello from anthropic"
        }));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["type"], "inputText");
        assert_eq!(out[0]["text"], "hello from anthropic");
    }

    #[test]
    fn normalize_dynamic_tool_call_output_converts_anthropic_image_block() {
        let out = normalize_dynamic_tool_call_output(&json!({
            "type": "image",
            "source": {
                "media_type": "image/png",
                "data": "AAA"
            }
        }));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["type"], "inputImage");
        assert_eq!(out[0]["imageUrl"], "data:image/png;base64,AAA");
    }

    #[test]
    fn normalize_dynamic_tool_call_output_flattens_arrays() {
        let out = normalize_dynamic_tool_call_output(&json!([
            "first",
            {"type": "text", "text": "second"},
            {"type": "inputText", "text": "third"}
        ]));
        assert_eq!(out.len(), 3);
        assert_eq!(out[0]["text"], "first");
        assert_eq!(out[1]["text"], "second");
        assert_eq!(out[2]["text"], "third");
        assert!(out.iter().all(|v| v["type"] == "inputText"));
    }

    #[test]
    fn normalize_dynamic_tool_call_output_stringifies_unknown_objects() {
        let out = normalize_dynamic_tool_call_output(&json!({
            "stdout": "ok",
            "stderr": ""
        }));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["type"], "inputText");
        assert!(out[0]["text"].as_str().unwrap().contains("stdout"));
    }

    #[test]
    fn normalize_dynamic_tool_call_output_drops_null() {
        let out = normalize_dynamic_tool_call_output(&json!(null));
        assert!(out.is_empty());
    }

    #[test]
    fn disk_exploration_items_preserve_claude_read_and_grep_options_in_command_text() {
        let read = build_exploration_disk_item(
            &CodexToolKind::ExplorationRead,
            "Read",
            "read-1".to_string(),
            &json!({"file_path":"/tmp/x.txt","offset":40,"limit":20}),
        );
        match read {
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

        let grep = build_exploration_disk_item(
            &CodexToolKind::ExplorationSearch,
            "Grep",
            "grep-1".to_string(),
            &json!({"pattern":"foo","path":"src","output_mode":"files_with_matches","head_limit":5,"-n":true}),
        );
        match grep {
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
    fn disk_subagent_item_preserves_agent_name_team_and_background() {
        let item = build_subagent_disk_item(
            "agent-1".to_string(),
            &json!({
                "prompt": "do thing",
                "name": "ios-reader",
                "subagent_type": "Explore",
                "description": "find files",
                "team_name": "litter-ios",
                "run_in_background": true
            }),
        );
        match item {
            ThreadItem::CollabAgentToolCall { agents_states, .. } => {
                let state = agents_states.get("subagent-agent-1").expect("agent state");
                assert_eq!(
                    state.message.as_deref(),
                    Some("ios-reader · Explore: find files · team litter-ios · background")
                );
            }
            other => panic!("expected CollabAgentToolCall, got {other:?}"),
        }
    }

    #[test]
    fn task_create_and_update_produce_no_disk_items() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "make a plan"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:01Z",
                "message": {
                    "id": "msg_t",
                    "content": [{
                        "type": "tool_use",
                        "id": "toolu_create",
                        "name": "TaskCreate",
                        "input": {"subject": "step one"}
                    }]
                }
            })),
            record(json!({
                "type": "user",
                "timestamp": "2026-04-27T10:00:02Z",
                "message": {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "toolu_create",
                        "content": "{\"id\": \"task-1\"}",
                        "is_error": false
                    }]
                }
            })),
        ];
        let turns = records_to_turns(&records);
        // Replay must NOT produce a phantom DynamicToolCall card for
        // TaskCreate. The only ThreadItem in the turn is the user
        // anchor message.
        let non_user_items: Vec<_> = turns
            .iter()
            .flat_map(|t| t.items.iter())
            .filter(|i| !matches!(i, ThreadItem::UserMessage { .. }))
            .collect();
        assert!(
            non_user_items.is_empty(),
            "TaskCreate must produce no disk item; got {:?}",
            non_user_items
        );
    }

    #[test]
    fn exit_plan_mode_disk_record_emits_plan_thread_item() {
        let records = vec![
            record(json!({
                "type": "user",
                "message": {"role": "user", "content": "what's the plan?"},
                "timestamp": "2026-04-27T10:00:00Z"
            })),
            record(json!({
                "type": "assistant",
                "timestamp": "2026-04-27T10:00:01Z",
                "message": {
                    "id": "msg_p",
                    "content": [{
                        "type": "tool_use",
                        "id": "toolu_plan",
                        "name": "ExitPlanMode",
                        "input": {"plan": "1. do this\n2. do that"}
                    }]
                }
            })),
            record(json!({
                "type": "user",
                "timestamp": "2026-04-27T10:00:02Z",
                "message": {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "toolu_plan",
                        "content": "approved",
                        "is_error": false
                    }]
                }
            })),
        ];
        let turns = records_to_turns(&records);
        let plan = turns
            .iter()
            .flat_map(|t| t.items.iter())
            .find_map(|i| match i {
                ThreadItem::Plan { id, text } => Some((id.clone(), text.clone())),
                _ => None,
            })
            .expect("plan item in disk replay");
        assert_eq!(plan.0, "toolu_plan");
        assert_eq!(plan.1, "1. do this\n2. do that");
    }
}
