//! Classify a claude tool name into the codex `ThreadItem` kind we should
//! emit. The mapping is:
//!
//! | claude tool name                                 | codex shape                                          |
//! |--------------------------------------------------|------------------------------------------------------|
//! | `Bash`                                           | `ThreadItem::CommandExecution`                       |
//! | `Edit` / `Write` / `MultiEdit` / `NotebookEdit`  | `ThreadItem::FileChange`                             |
//! | `mcp__<server>__<tool>`                          | `ThreadItem::McpToolCall`                            |
//! | `ExitPlanMode`                                   | `ThreadItem::Plan`                                   |
//! | `AskUserQuestion`                                | `item/tool/requestUserInput` (no item)               |
//! | `Task` / `Agent`                                 | `ThreadItem::CollabAgentToolCall`                    |
//! | `Read`                                           | `ThreadItem::CommandExecution` (read action)         |
//! | `Grep`                                           | `ThreadItem::CommandExecution` (search action)       |
//! | `Glob` / `LS`                                    | `ThreadItem::CommandExecution` (list_files action)   |
//! | `WebSearch`                                      | `DynamicToolCall { namespace:"claude" }`            |
//! | `TaskCreate` / `TaskUpdate`                      | `DynamicToolCall` + `turn/plan/updated`              |
//! | anything else (`WebFetch`, `TodoWrite`, `ToolSearch`, ...) | `DynamicToolCall { namespace:"claude", tool:name }` |
//!
//! Matching is case-sensitive — claude's tool names are PascalCase with stable
//! capitalization (`Bash`, not `bash`); a casing mismatch indicates a wire
//! drift we'd rather surface than silently rewrite.

/// Coarse codex item kind a given claude tool call should be promoted to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexToolKind {
    /// Claude `Bash` — codex `ThreadItem::CommandExecution`.
    CommandExecution,

    /// Claude `Edit`, `Write`, `MultiEdit`, `NotebookEdit` — codex
    /// `ThreadItem::FileChange`.
    FileChange,

    /// Claude MCP tool call (`mcp__<server>__<tool>`). The original name is
    /// split on the first `__` after the `mcp__` prefix.
    Mcp { server: String, tool: String },

    /// Claude `ExitPlanMode` — codex `ThreadItem::Plan`. Translator parses
    /// the `plan` argument before emitting.
    PlanExit,

    /// Claude `AskUserQuestion` — codex server→client request
    /// `item/tool/requestUserInput`. The bridge synthesizes the
    /// `tool_result` reply once the codex client answers.
    RequestUserInput,

    /// Claude `Task` / `Agent` — codex `ThreadItem::CollabAgentToolCall`.
    Subagent,

    /// Claude `Read` — codex `ThreadItem::CommandExecution` with a `read`
    /// command action.
    ExplorationRead,

    /// Claude `Grep` — codex `ThreadItem::CommandExecution` with a
    /// `search` command action.
    ExplorationSearch,

    /// Claude `Glob` / `LS` — codex `ThreadItem::CommandExecution` with a
    /// `list_files` command action.
    ExplorationList,

    /// Claude `WebSearch` — translated as `DynamicToolCall` because codex's
    /// dedicated `WebSearch` item has no result or status fields.
    WebSearch,

    /// Claude `TaskCreate` / `TaskUpdate` — a dynamic item preserves the raw
    /// call while `turn/plan/updated` keeps the live plan UI current.
    TodoUpdate,

    /// Anything else. `namespace` is always `Some("claude")` so codex clients
    /// can group claude-emitted dynamic tool calls under a single bucket.
    Dynamic {
        namespace: Option<String>,
        tool: String,
    },
}

const FILE_CHANGE_TOOLS: &[&str] = &["Edit", "Write", "MultiEdit", "NotebookEdit"];

/// Classify the claude `name` field of a `tool_use` content block into a
/// codex item kind.
pub fn classify(tool_name: &str) -> CodexToolKind {
    if tool_name == "Bash" {
        return CodexToolKind::CommandExecution;
    }
    if FILE_CHANGE_TOOLS.contains(&tool_name) {
        return CodexToolKind::FileChange;
    }
    if let Some((server, tool)) = split_mcp(tool_name) {
        return CodexToolKind::Mcp {
            server: server.to_string(),
            tool: tool.to_string(),
        };
    }
    match tool_name {
        "ExitPlanMode" => CodexToolKind::PlanExit,
        "AskUserQuestion" => CodexToolKind::RequestUserInput,
        "Task" | "Agent" => CodexToolKind::Subagent,
        "Read" => CodexToolKind::ExplorationRead,
        "Grep" => CodexToolKind::ExplorationSearch,
        "Glob" | "LS" => CodexToolKind::ExplorationList,
        "WebSearch" => CodexToolKind::WebSearch,
        "TaskCreate" | "TaskUpdate" => CodexToolKind::TodoUpdate,
        _ => CodexToolKind::Dynamic {
            namespace: Some("claude".to_string()),
            tool: tool_name.to_string(),
        },
    }
}

/// Split a claude MCP tool name `mcp__<server>__<tool>` into its parts. The
/// first `__` after the `mcp__` prefix is the server boundary; everything
/// after is the tool (which itself can contain `_` or `__`).
fn split_mcp(tool_name: &str) -> Option<(&str, &str)> {
    let rest = tool_name.strip_prefix("mcp__")?;
    let (server, tool) = rest.split_once("__")?;
    if server.is_empty() || tool.is_empty() {
        return None;
    }
    Some((server, tool))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bash_is_command_execution() {
        assert_eq!(classify("Bash"), CodexToolKind::CommandExecution);
    }

    #[test]
    fn file_mutating_tools_are_file_change() {
        for name in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
            assert_eq!(classify(name), CodexToolKind::FileChange, "{name}");
        }
    }

    #[test]
    fn exit_plan_mode_is_plan_exit() {
        assert_eq!(classify("ExitPlanMode"), CodexToolKind::PlanExit);
    }

    #[test]
    fn ask_user_question_is_request_user_input() {
        assert_eq!(classify("AskUserQuestion"), CodexToolKind::RequestUserInput);
    }

    #[test]
    fn task_and_agent_are_subagent() {
        assert_eq!(classify("Task"), CodexToolKind::Subagent);
        assert_eq!(classify("Agent"), CodexToolKind::Subagent);
    }

    #[test]
    fn read_is_exploration_read() {
        assert_eq!(classify("Read"), CodexToolKind::ExplorationRead);
    }

    #[test]
    fn grep_is_exploration_search() {
        assert_eq!(classify("Grep"), CodexToolKind::ExplorationSearch);
    }

    #[test]
    fn glob_and_ls_are_exploration_list() {
        assert_eq!(classify("Glob"), CodexToolKind::ExplorationList);
        assert_eq!(classify("LS"), CodexToolKind::ExplorationList);
    }

    #[test]
    fn web_search_is_web_search() {
        assert_eq!(classify("WebSearch"), CodexToolKind::WebSearch);
    }

    #[test]
    fn task_create_and_update_are_todo_update() {
        assert_eq!(classify("TaskCreate"), CodexToolKind::TodoUpdate);
        assert_eq!(classify("TaskUpdate"), CodexToolKind::TodoUpdate);
    }

    #[test]
    fn unknown_tools_are_dynamic_under_claude_namespace() {
        // WebFetch is intentionally Dynamic per plan (not really a search);
        // TodoWrite is a separate older bulk-write API not covered by
        // TodoUpdate; ToolSearch and TodoRead/anything novel falls through.
        for name in [
            "WebFetch",
            "TodoWrite",
            "ToolSearch",
            "EnterPlanMode",
            "Skill",
        ] {
            match classify(name) {
                CodexToolKind::Dynamic { namespace, tool } => {
                    assert_eq!(namespace.as_deref(), Some("claude"), "{name}");
                    assert_eq!(tool, name);
                }
                other => panic!("expected Dynamic for {name}, got {other:?}"),
            }
        }
    }

    #[test]
    fn mcp_with_double_underscore_separates_server_and_tool() {
        assert_eq!(
            classify("mcp__claude_ai_Google_Drive__authenticate"),
            CodexToolKind::Mcp {
                server: "claude_ai_Google_Drive".into(),
                tool: "authenticate".into(),
            }
        );
    }

    #[test]
    fn mcp_tool_keeps_inner_underscores() {
        assert_eq!(
            classify("mcp__github__list_issues"),
            CodexToolKind::Mcp {
                server: "github".into(),
                tool: "list_issues".into(),
            }
        );
    }

    #[test]
    fn malformed_mcp_falls_through_to_dynamic() {
        // No second `__` after mcp__, or empty halves.
        for name in ["mcp__foo", "mcp____foo", "mcp__foo__"] {
            match classify(name) {
                CodexToolKind::Dynamic { tool, .. } => assert_eq!(tool, name),
                other => panic!("expected Dynamic for {name:?}, got {other:?}"),
            }
        }
    }

    #[test]
    fn non_mcp_underscore_name_is_dynamic_not_mcp() {
        // Looks vaguely like the MCP convention but lacks the `mcp__` prefix.
        match classify("github__create_issue") {
            CodexToolKind::Dynamic { namespace, tool } => {
                assert_eq!(namespace.as_deref(), Some("claude"));
                assert_eq!(tool, "github__create_issue");
            }
            other => panic!("expected Dynamic, got {other:?}"),
        }
    }

    #[test]
    fn case_sensitive_match() {
        // `bash` (lowercase) is not claude's `Bash`. Surface as dynamic so a
        // wire drift surfaces rather than silently rewriting.
        match classify("bash") {
            CodexToolKind::Dynamic { tool, .. } => assert_eq!(tool, "bash"),
            other => panic!("expected Dynamic, got {other:?}"),
        }
    }
}
