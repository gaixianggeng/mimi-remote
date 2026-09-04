//! Walk `~/.claude/projects/<encoded-cwd>/<session_id>.jsonl` and produce
//! [`ClaudeSessionInfo`] records for hydration into the bridge index.
//!
//! Encoded-cwd convention (per the live wire `system/init.cwd` matching what
//! claude writes on disk): the cwd is mangled into a directory name by
//! replacing `/` with `-` and dropping the leading separator. For example,
//! cwd `/Users/sigkitten/dev/alleycat` becomes
//! `-Users-sigkitten-dev-alleycat`.
//!
//! Each `<session_id>.jsonl` is tolerated permissively: we read the first real
//! user message for `first_message`, skipping Claude CLI metadata, local
//! commands, and tool-result-only records. Files without a real user message,
//! or that fail to open or parse, are skipped quietly.
//!
//! Claude 自己会把会话标题写进同一份 transcript（`custom-title` / `ai-title`
//! 记录），桌面端列表显示的就是它。扫描时一并读出来当作 `title`，Mimi 不需要
//! 再生成一次标题。

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::fs;

use crate::translate::items::is_internal_user_text;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClaudeSessionInfo {
    /// Absolute path to the JSONL file.
    pub path: PathBuf,
    /// Session id (== filename stem; stable across the session lifetime).
    pub session_id: String,
    /// Working directory the session was bound to. Empty when the JSONL
    /// header is missing (very old sessions).
    pub cwd: String,
    pub created: DateTime<Utc>,
    pub modified: DateTime<Utc>,
    pub first_message: String,
    /// Claude 写在 transcript 里的会话标题；`custom-title` 优先于 `ai-title`。
    /// 旧会话没有这两种记录时为 `None`，列表继续回退到首条用户消息。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

/// 标题记录的两种 `type`。同一文件每次 checkpoint 都会追加当前值，取最后一条。
const CUSTOM_TITLE_TYPE: &str = "custom-title";
const AI_TITLE_TYPE: &str = "ai-title";

/// 标题被截断的上限。Claude 写的都是短标题，异常长的值更可能是坏记录，
/// 不能让它撑坏列表行。
const MAX_TITLE_CHARS: usize = 120;

/// 一条标题记录的字节上限，用于跳过大行的预筛。真实记录不到 200 字节，
/// 这里留足余量。
const MAX_TITLE_RECORD_BYTES: usize = 4096;

/// `~/.claude/projects/`. Honors `CLAUDE_PROJECTS_DIR` for tests.
pub fn claude_projects_dir() -> Option<PathBuf> {
    if let Ok(env_dir) = std::env::var("CLAUDE_PROJECTS_DIR") {
        return Some(expand_tilde(&env_dir));
    }
    let home = directories::UserDirs::new()?.home_dir().to_path_buf();
    Some(home.join(".claude").join("projects"))
}

fn expand_tilde(input: &str) -> PathBuf {
    if input == "~" {
        if let Some(home) = directories::UserDirs::new() {
            return home.home_dir().to_path_buf();
        }
    }
    if let Some(rest) = input.strip_prefix("~/") {
        if let Some(home) = directories::UserDirs::new() {
            return home.home_dir().join(rest);
        }
    }
    PathBuf::from(input)
}

/// Walk every encoded-cwd subdirectory of `~/.claude/projects/` and return
/// every parseable session.
pub async fn list_all() -> Vec<ClaudeSessionInfo> {
    let Some(root) = claude_projects_dir() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut read_dir = match fs::read_dir(&root).await {
        Ok(rd) => rd,
        Err(_) => return out,
    };
    while let Ok(Some(entry)) = read_dir.next_entry().await {
        if entry
            .file_type()
            .await
            .map(|ft| ft.is_dir())
            .unwrap_or(false)
        {
            out.extend(list_sessions_from_dir(&entry.path()).await);
        }
    }
    out
}

/// Read every `*.jsonl` in `dir`. Each parses into a `ClaudeSessionInfo`;
/// unparseable files are skipped quietly.
pub async fn list_sessions_from_dir(dir: &Path) -> Vec<ClaudeSessionInfo> {
    let mut out = Vec::new();
    let mut read_dir = match fs::read_dir(dir).await {
        Ok(rd) => rd,
        Err(_) => return out,
    };
    while let Ok(Some(entry)) = read_dir.next_entry().await {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        if let Some(info) = build_session_info(&path).await {
            out.push(info);
        }
    }
    out
}

async fn build_session_info(path: &Path) -> Option<ClaudeSessionInfo> {
    let session_id = path.file_stem()?.to_string_lossy().to_string();
    let metadata = fs::metadata(path).await.ok()?;
    let modified: DateTime<Utc> = metadata
        .modified()
        .ok()
        .and_then(|t| {
            DateTime::<Utc>::from_timestamp(
                t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64,
                0,
            )
        })
        .unwrap_or_else(Utc::now);
    let created: DateTime<Utc> = metadata
        .created()
        .ok()
        .and_then(|t| {
            DateTime::<Utc>::from_timestamp(
                t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64,
                0,
            )
        })
        .unwrap_or(modified);

    let text = fs::read_to_string(path).await.ok()?;
    let mut cwd = String::new();
    let mut first_message: Option<String> = None;
    let mut found_real_user_message = false;
    let mut first_message_ts: Option<DateTime<Utc>> = None;
    let mut custom_title: Option<String> = None;
    let mut ai_title: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // 头部信息（cwd + 首条消息）通常在前几行就齐了，但标题记录一直追加到
        // 文件末尾。补齐头部后只对可能是标题的行做 JSON 解析：transcript 动辄
        // 上万行，逐行解析比子串预筛贵一个量级。
        let header_done = !cwd.is_empty() && first_message.is_some();
        let title_candidate = looks_like_title_record(trimmed);
        if header_done && !title_candidate {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if title_candidate {
            match title_record(&value) {
                Some(TitleRecord::Custom(title)) => custom_title = Some(title),
                Some(TitleRecord::Ai(title)) => ai_title = Some(title),
                None => {}
            }
        }
        if header_done {
            continue;
        }
        if cwd.is_empty() {
            if let Some(c) = value.get("cwd").and_then(|v| v.as_str()) {
                cwd = c.to_string();
            }
        }
        if first_message.is_none() {
            if let Some(message) = first_real_user_message(&value) {
                if !found_real_user_message {
                    found_real_user_message = true;
                    if let Some(ts) = value
                        .get("timestamp")
                        .and_then(|v| v.as_str())
                        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                    {
                        first_message_ts = Some(ts.with_timezone(&Utc));
                    }
                }
                if let RealUserMessage::Titled(preview) = message {
                    first_message = Some(preview);
                }
            }
        }
    }

    let created = first_message_ts.unwrap_or(created);
    if !found_real_user_message {
        return None;
    }
    Some(ClaudeSessionInfo {
        path: path.to_path_buf(),
        session_id,
        cwd,
        created,
        modified,
        first_message: first_message.unwrap_or_default(),
        // 用户或桌面端设定的 `custom-title` 压过自动生成的 `ai-title`，
        // 与 Claude 自己的列表一致。
        title: custom_title.or(ai_title),
    })
}

enum TitleRecord {
    Custom(String),
    Ai(String),
}

/// 便宜的预筛：只有出现过标题记录类型字面量的行才值得整行 JSON 解析。
/// 普通消息里恰好出现同样文本时最多多解析一行，`title_record` 会再判一次类型。
///
/// 长度先行是因为 transcript 的字节数几乎都集中在少数几行超大的助手输出和附件
/// 上；标题记录只有几十字节，先按长度筛掉大行，扫描整份历史的成本才不会
/// 随对话体积增长。
fn looks_like_title_record(line: &str) -> bool {
    line.len() <= MAX_TITLE_RECORD_BYTES
        && (line.contains(CUSTOM_TITLE_TYPE) || line.contains(AI_TITLE_TYPE))
}

fn title_record(value: &Value) -> Option<TitleRecord> {
    match value.get("type").and_then(Value::as_str)? {
        CUSTOM_TITLE_TYPE => {
            title_text(value, "customTitle", "custom_title").map(TitleRecord::Custom)
        }
        AI_TITLE_TYPE => title_text(value, "aiTitle", "ai_title").map(TitleRecord::Ai),
        _ => None,
    }
}

/// 标题只取首个非空行并裁到 [`MAX_TITLE_CHARS`]；空标题按“没有标题”处理，
/// 否则列表会显示一行空白而不是回退到首条用户消息。
fn title_text(value: &Value, camel_key: &str, snake_key: &str) -> Option<String> {
    let raw = value
        .get(camel_key)
        .or_else(|| value.get(snake_key))
        .and_then(Value::as_str)?;
    let line = raw.lines().map(str::trim).find(|line| !line.is_empty())?;
    let title: String = line.chars().take(MAX_TITLE_CHARS).collect();
    let title = title.trim();
    (!title.is_empty()).then(|| title.to_string())
}

/// 提取会话标题时只认真实用户文本。Claude 会把 `/model` 等本地命令、
/// caveat 元消息和工具结果都写成顶层 `type=user`，不能据此直接判断用户发过消息。
fn first_real_user_message(value: &Value) -> Option<RealUserMessage> {
    if value.get("type").and_then(Value::as_str) != Some("user") {
        return None;
    }
    let is_meta = value
        .get("isMeta")
        .or_else(|| value.get("is_meta"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if is_meta {
        return None;
    }

    let content = value.get("message")?.get("content")?;
    if let Some(text) = content.as_str() {
        return real_message_preview(text).map(RealUserMessage::Titled);
    }
    let entries = content.as_array()?;
    for entry in entries {
        if entry.get("type").and_then(Value::as_str) == Some("text") {
            if let Some(preview) = entry
                .get("text")
                .and_then(Value::as_str)
                .and_then(real_message_preview)
            {
                return Some(RealUserMessage::Titled(preview));
            }
        }
    }

    // 图片等非文本输入是真实会话，只是没有可用标题；纯 tool_result 仍视为内部记录。
    entries
        .iter()
        .any(|entry| {
            matches!(
                entry.get("type").and_then(Value::as_str),
                Some("image" | "image_url" | "document")
            )
        })
        .then_some(RealUserMessage::Untitled)
}

enum RealUserMessage {
    Titled(String),
    Untitled,
}

fn real_message_preview(text: &str) -> Option<String> {
    if is_internal_user_text(text) {
        return None;
    }
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    #[tokio::test]
    async fn lists_session_with_first_user_message_and_cwd() {
        let dir = TempDir::new().unwrap();
        let cwd_dir = dir.path().join("-private-tmp");
        std::fs::create_dir_all(&cwd_dir).unwrap();
        let session_path = cwd_dir.join("abc-123.jsonl");
        let mut f = std::fs::File::create(&session_path).unwrap();
        writeln!(
            f,
            "{}",
            r#"{"type":"permission-mode","sessionId":"abc-123","permissionMode":"bypassPermissions"}"#
        )
        .unwrap();
        writeln!(
            f,
            "{}",
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":"hello world"},"timestamp":"2026-04-27T10:00:00Z"}"#
        )
        .unwrap();
        drop(f);

        let sessions = list_sessions_from_dir(&cwd_dir).await;
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "abc-123");
        assert_eq!(sessions[0].cwd, "/private/tmp");
        assert_eq!(sessions[0].first_message, "hello world");
    }

    #[tokio::test]
    async fn reads_claude_title_written_after_the_first_message() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("titled.jsonl");
        let records = [
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":"帮我看下会话列表"},"timestamp":"2026-09-04T10:00:00Z"}"#,
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好的"}]}}"#,
            r#"{"type":"ai-title","aiTitle":"旧的自动标题","sessionId":"titled"}"#,
            r#"{"type":"custom-title","customTitle":"旧的自定义标题","sessionId":"titled"}"#,
            r#"{"type":"ai-title","aiTitle":"最新自动标题","sessionId":"titled"}"#,
            r#"{"type":"custom-title","customTitle":"最新自定义标题","sessionId":"titled"}"#,
        ];
        std::fs::write(&path, records.join("\n")).unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        assert_eq!(sessions.len(), 1);
        // 标题记录整份 transcript 一路追加，取最后一条；custom 压过 ai。
        assert_eq!(sessions[0].title.as_deref(), Some("最新自定义标题"));
        assert_eq!(sessions[0].first_message, "帮我看下会话列表");
    }

    #[tokio::test]
    async fn falls_back_to_ai_title_and_ignores_blank_titles() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("ai-only.jsonl");
        let records = [
            r#"{"type":"custom-title","customTitle":"   ","sessionId":"ai-only"}"#,
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":"hello"},"timestamp":"2026-09-04T10:00:00Z"}"#,
            r#"{"type":"ai-title","aiTitle":"自动标题","sessionId":"ai-only"}"#,
        ];
        std::fs::write(&path, records.join("\n")).unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].title.as_deref(), Some("自动标题"));
    }

    #[tokio::test]
    async fn leaves_title_empty_when_transcript_has_none() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("untitled.jsonl");
        std::fs::write(
            &path,
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":"hello"},"timestamp":"2026-09-04T10:00:00Z"}"#,
        )
        .unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        assert_eq!(sessions.len(), 1);
        assert!(sessions[0].title.is_none());
    }

    #[tokio::test]
    async fn ignores_title_text_inside_ordinary_messages() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("mentions-title.jsonl");
        let records = [
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":"custom-title 这个记录该怎么读"},"timestamp":"2026-09-04T10:00:00Z"}"#,
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ai-title 是自动生成的"}]}}"#,
        ];
        std::fs::write(&path, records.join("\n")).unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        assert_eq!(sessions.len(), 1);
        assert!(sessions[0].title.is_none());
    }

    #[tokio::test]
    async fn truncates_overlong_title_to_one_line() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("long-title.jsonl");
        let long = "标".repeat(MAX_TITLE_CHARS + 40);
        let records = [
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":"hello"},"timestamp":"2026-09-04T10:00:00Z"}"#.to_string(),
            format!(r#"{{"type":"custom-title","customTitle":"{long}\n第二行","sessionId":"long-title"}}"#),
        ];
        std::fs::write(&path, records.join("\n")).unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        let title = sessions[0].title.as_deref().unwrap();
        assert_eq!(title.chars().count(), MAX_TITLE_CHARS);
        assert!(!title.contains('\n'));
    }

    #[tokio::test]
    async fn skips_non_jsonl_files() {
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join("notes.txt"), "hi").unwrap();
        let sessions = list_sessions_from_dir(dir.path()).await;
        assert!(sessions.is_empty());
    }

    #[tokio::test]
    async fn missing_dir_returns_empty_not_error() {
        let sessions = list_sessions_from_dir(Path::new("/nonexistent/missing")).await;
        assert!(sessions.is_empty());
    }

    #[tokio::test]
    async fn handles_jsonl_with_no_user_message() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("only-meta.jsonl");
        std::fs::write(
            &path,
            r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}
"#,
        )
        .unwrap();
        let sessions = list_sessions_from_dir(dir.path()).await;
        assert!(sessions.is_empty());
    }

    #[tokio::test]
    async fn skips_internal_user_records_before_first_real_message() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("internal-before-real.jsonl");
        let records = [
            r#"{"type":"user","isMeta":true,"cwd":"/private/tmp","message":{"role":"user","content":"<local-command-caveat>internal</local-command-caveat>"},"timestamp":"2026-07-17T05:11:50Z"}"#,
            r#"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>sonnet</command-args>"},"timestamp":"2026-07-17T05:11:51Z"}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"done"}]},"timestamp":"2026-07-17T05:11:52Z"}"#,
            r#"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"},"timestamp":"2026-07-17T05:11:52.500Z"}"#,
            r#"{"type":"user","message":{"role":"user","content":"\n  真正的用户消息\n第二行"},"timestamp":"2026-07-17T05:11:53Z"}"#,
        ];
        std::fs::write(&path, records.join("\n")).unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].first_message, "真正的用户消息");
        assert_eq!(
            sessions[0].created,
            DateTime::parse_from_rfc3339("2026-07-17T05:11:53Z")
                .unwrap()
                .with_timezone(&Utc)
        );
    }

    #[tokio::test]
    async fn skips_session_with_only_internal_user_records() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("internal-only.jsonl");
        let records = [
            r#"{"type":"user","isMeta":true,"cwd":"/private/tmp","message":{"role":"user","content":"metadata"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>done</local-command-stdout>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"done"}]}}"#,
        ];
        std::fs::write(&path, records.join("\n")).unwrap();

        assert!(list_sessions_from_dir(dir.path()).await.is_empty());
    }

    #[tokio::test]
    async fn keeps_image_only_user_session_without_inventing_a_title() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("image-only.jsonl");
        std::fs::write(
            &path,
            r#"{"type":"user","cwd":"/private/tmp","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]},"timestamp":"2026-07-17T05:11:53Z"}"#,
        )
        .unwrap();

        let sessions = list_sessions_from_dir(dir.path()).await;

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "image-only");
        assert!(sessions[0].first_message.is_empty());
    }
}
