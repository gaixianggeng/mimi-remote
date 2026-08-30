//! Bridge-side thread index.
//!
//! Wraps `bridge_core::ThreadIndex<ClaudeSessionRef>` and provides claude-
//! specific glue: hydration from `~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`,
//! conversion of an [`IndexEntry`] into a wire `Thread`, and a [`ClaudeHydrator`]
//! used by the bridge to absorb pre-existing JSONL transcripts at startup.
//!
//! On-disk JSON layout is wire-compatible with the pre-refactor shape: each
//! row has the same `claudeSessionPath` / `claudeSessionId` fields at the top
//! level (via `#[serde(flatten)]` on [`ClaudeSessionRef`]).

pub mod claude_session_scan;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

pub use claude_session_scan::{ClaudeSessionInfo, claude_projects_dir, list_all};

use alleycat_bridge_core::Hydrator;
pub use alleycat_bridge_core::{
    IndexEntry as CoreIndexEntry, ListFilter, ListPage, ListSort, ThreadIndex as CoreThreadIndex,
};
use alleycat_codex_proto::{SessionSource, Thread, ThreadSourceKind, ThreadStatus};

use crate::translate::items::is_internal_user_text;

/// 同一 bridge 进程内两次显式历史扫描的最小间隔。
///
/// 扫描只由 `refreshHistory` 首屏请求触发；冷却窗口继续保护用户快速重复点击和多连接竞态。
pub const DEFAULT_HISTORY_REFRESH_INTERVAL: Duration = Duration::from_secs(2);

/// Bridge CLI version string baked into `Thread.cli_version`.
pub const CLI_VERSION: &str = concat!("alleycat-claude-bridge/", env!("CARGO_PKG_VERSION"));

/// Claude-specific metadata for an [`IndexEntry`]. Flattens into the row's top
/// level so the on-disk shape matches the pre-refactor `claudeSessionPath` /
/// `claudeSessionId` keys exactly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeSessionRef {
    /// Absolute path to the on-disk JSONL transcript (typically
    /// `~/.claude/projects/<encoded-cwd>/<thread_id>.jsonl`).
    pub claude_session_path: PathBuf,
    /// Claude session id (== `thread_id` in v1).
    pub claude_session_id: String,
}

/// Bridge-local alias so handler code reads `IndexEntry` instead of the
/// generic `bridge_core::IndexEntry<ClaudeSessionRef>`.
pub type IndexEntry = CoreIndexEntry<ClaudeSessionRef>;

/// Convert a [`ClaudeSessionInfo`] into a fresh index row.
pub fn entry_from_claude(info: &ClaudeSessionInfo) -> IndexEntry {
    IndexEntry {
        thread_id: info.session_id.clone(),
        cwd: info.cwd.clone(),
        created_at: info.created.timestamp_millis(),
        updated_at: info.modified.timestamp_millis(),
        archived: false,
        name: None,
        preview: info.first_message.clone(),
        forked_from_id: None,
        model_provider: "anthropic".to_string(),
        source: ThreadSourceKind::AppServer,
        metadata: ClaudeSessionRef {
            claude_session_path: info.path.clone(),
            claude_session_id: info.session_id.clone(),
        },
    }
}

/// Render an index row as a wire `Thread`.
pub fn entry_to_thread(entry: &IndexEntry) -> Thread {
    Thread {
        id: entry.thread_id.clone(),
        session_id: entry.metadata.claude_session_id.clone(),
        forked_from_id: entry.forked_from_id.clone(),
        preview: entry.preview.clone(),
        ephemeral: false,
        model_provider: entry.model_provider.clone(),
        created_at: entry.created_at,
        updated_at: entry.updated_at,
        status: ThreadStatus::NotLoaded,
        path: Some(
            entry
                .metadata
                .claude_session_path
                .to_string_lossy()
                .into_owned(),
        ),
        cwd: entry.cwd.clone(),
        cli_version: CLI_VERSION.to_string(),
        source: source_kind_to_session_source(entry.source),
        thread_source: None,
        agent_nickname: None,
        agent_role: None,
        git_info: alleycat_bridge_core::git_info_for_cwd(&entry.cwd),
        name: entry.name.clone(),
        turns: Vec::new(),
    }
}

fn source_kind_to_session_source(kind: ThreadSourceKind) -> SessionSource {
    match kind {
        ThreadSourceKind::Cli => SessionSource::Cli,
        ThreadSourceKind::VsCode => SessionSource::VsCode,
        ThreadSourceKind::Exec => SessionSource::Exec,
        ThreadSourceKind::AppServer => SessionSource::AppServer,
        _ => SessionSource::AppServer,
    }
}

/// Hydrator that walks `~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`
/// and produces fresh index rows for each session it finds.
pub struct ClaudeHydrator {
    /// Override directory; `None` uses [`claude_projects_dir`].
    pub override_dir: Option<PathBuf>,
}

impl ClaudeHydrator {
    pub fn new() -> Self {
        Self { override_dir: None }
    }

    pub fn with_override_dir(dir: PathBuf) -> Self {
        Self {
            override_dir: Some(dir),
        }
    }
}

impl Default for ClaudeHydrator {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryRefreshResult {
    Refreshed { inserted: usize },
    RateLimited,
}

/// 运行期显式历史扫描器。
///
/// `gate` 在扫描期间保持锁定，既让多个连接共享同一冷却窗口，也避免同时遍历
/// `~/.claude/projects`。这里只把新 session ID 写入索引，不覆盖已有名称、归档等用户状态。
pub struct ClaudeHistoryRefresher {
    index: Arc<CoreThreadIndex<ClaudeSessionRef>>,
    hydrator: ClaudeHydrator,
    min_interval: Duration,
    gate: tokio::sync::Mutex<Option<tokio::time::Instant>>,
}

impl ClaudeHistoryRefresher {
    pub fn new(index: Arc<CoreThreadIndex<ClaudeSessionRef>>, hydrator: ClaudeHydrator) -> Self {
        Self::with_interval(index, hydrator, DEFAULT_HISTORY_REFRESH_INTERVAL)
    }

    pub fn with_interval(
        index: Arc<CoreThreadIndex<ClaudeSessionRef>>,
        hydrator: ClaudeHydrator,
        min_interval: Duration,
    ) -> Self {
        Self {
            index,
            hydrator,
            min_interval,
            gate: tokio::sync::Mutex::new(None),
        }
    }

    pub async fn refresh_if_due(&self) -> Result<HistoryRefreshResult> {
        let mut last_finished_at = self.gate.lock().await;
        let now = tokio::time::Instant::now();
        if last_finished_at.is_some_and(|last| now.duration_since(last) < self.min_interval) {
            return Ok(HistoryRefreshResult::RateLimited);
        }

        let refresh_result = async {
            let scanned = self.hydrator.scan().await?;
            self.index.hydrate_entries(scanned).await
        }
        .await;
        // 成功和失败都从整轮扫描与落盘结束时进入冷却，避免慢磁盘
        // 缩短实际冷却窗口，也避免坏目录被快速重复扫描。
        *last_finished_at = Some(tokio::time::Instant::now());
        let inserted = refresh_result?;
        Ok(HistoryRefreshResult::Refreshed { inserted })
    }
}

#[async_trait]
impl Hydrator<ClaudeSessionRef> for ClaudeHydrator {
    async fn scan(&self) -> Result<Vec<IndexEntry>> {
        let scanned = match self.override_dir.as_deref() {
            Some(dir) => claude_session_scan::list_sessions_from_dir(dir).await,
            None => list_all().await,
        };
        Ok(scanned.iter().map(entry_from_claude).collect())
    }
}

/// Convenience: open the index at `<codex_home>/threads.json` and hydrate from
/// `~/.claude/projects/`.
pub async fn open_and_hydrate(codex_home: &Path) -> Result<Arc<CoreThreadIndex<ClaudeSessionRef>>> {
    let path = codex_home.join("threads.json");
    let hydrator = ClaudeHydrator::new();
    open_index_and_hydrate(path, &hydrator).await
}

/// 打开 Claude 索引时清理旧版本留下的空 preview 和本地命令标题，再用同一份扫描结果补齐。
/// 空 preview 只有在扫描结果也证明它不是真实会话时才删除，避免误伤纯图片会话。
pub async fn open_index_and_hydrate(
    path: PathBuf,
    hydrator: &ClaudeHydrator,
) -> Result<Arc<CoreThreadIndex<ClaudeSessionRef>>> {
    let index = CoreThreadIndex::<ClaudeSessionRef>::open_at(path).await?;
    let scanned = hydrator.scan().await?;
    let scanned_by_id: std::collections::HashMap<&str, &IndexEntry> = scanned
        .iter()
        .map(|entry| (entry.thread_id.as_str(), entry))
        .collect();
    let mut invalid_ids = Vec::new();
    let mut repaired_entries = Vec::new();
    for mut entry in index.snapshot().await {
        let preview = entry.preview.trim();
        let Some(fresh) = scanned_by_id.get(entry.thread_id.as_str()) else {
            if preview.is_empty() || is_legacy_invalid_preview(preview) {
                invalid_ids.push(entry.thread_id);
            }
            continue;
        };
        if is_legacy_invalid_preview(preview) {
            // 只替换扫描产生的字段，保留用户设置的名称、归档和分叉关系。
            entry.preview.clone_from(&fresh.preview);
            entry.cwd.clone_from(&fresh.cwd);
            entry.updated_at = fresh.updated_at;
            entry.metadata.clone_from(&fresh.metadata);
            repaired_entries.push(entry);
        }
    }
    let removed = index.remove_many(&invalid_ids).await?;
    let repaired = index.upsert_many(repaired_entries).await?;
    if removed > 0 || repaired > 0 {
        tracing::info!(
            removed,
            repaired,
            "repaired legacy Claude thread index rows"
        );
    }
    index.hydrate_entries(scanned).await?;
    Ok(index)
}

fn is_legacy_invalid_preview(preview: &str) -> bool {
    let preview = preview.trim();
    let truncated_internal_prefix = [
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<local-command-stderr>",
        "<command-name>",
    ]
    .iter()
    .any(|prefix| preview.starts_with(prefix));
    preview == "(no messages)" || truncated_internal_prefix || is_internal_user_text(preview)
}

/// Compat shim. Today's daemon calls
/// `alleycat_claude_bridge::index::ThreadIndex::open_and_hydrate(&codex_home)`
/// and assigns the result to an `Arc<dyn ThreadIndexHandle<ClaudeSessionRef>>`.
/// The shim preserves the spelling so the daemon keeps compiling — it forwards
/// to the Claude-specific cleanup + hydration flow.
pub struct ThreadIndex;

impl ThreadIndex {
    pub async fn open_and_hydrate(
        codex_home: &Path,
    ) -> Result<Arc<CoreThreadIndex<ClaudeSessionRef>>> {
        open_and_hydrate(codex_home).await
    }

    pub async fn open(codex_home: &Path) -> Result<Arc<CoreThreadIndex<ClaudeSessionRef>>> {
        CoreThreadIndex::open_at(codex_home.join("threads.json")).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn entry(id: &str, cwd: &str, created: i64, updated: i64, archived: bool) -> IndexEntry {
        IndexEntry {
            thread_id: id.to_string(),
            cwd: cwd.to_string(),
            created_at: created,
            updated_at: updated,
            archived,
            name: None,
            preview: format!("preview {id}"),
            forked_from_id: None,
            model_provider: "anthropic".into(),
            source: ThreadSourceKind::AppServer,
            metadata: ClaudeSessionRef {
                claude_session_path: PathBuf::from(format!("/sessions/{id}.jsonl")),
                claude_session_id: id.to_string(),
            },
        }
    }

    #[tokio::test]
    async fn insert_then_lookup_roundtrips_through_disk() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("threads.json");
        let index = CoreThreadIndex::<ClaudeSessionRef>::open_at(path.clone())
            .await
            .unwrap();
        index
            .insert(entry("a", "/work", 100, 200, false))
            .await
            .unwrap();
        let row = index.lookup("a").await.unwrap();
        assert_eq!(row.cwd, "/work");

        drop(index);
        let reopened = CoreThreadIndex::<ClaudeSessionRef>::open_at(path)
            .await
            .unwrap();
        assert_eq!(
            reopened
                .lookup("a")
                .await
                .unwrap()
                .metadata
                .claude_session_id,
            "a"
        );
    }

    #[tokio::test]
    async fn on_disk_shape_uses_flat_camel_case_keys() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("threads.json");
        let index = CoreThreadIndex::<ClaudeSessionRef>::open_at(path.clone())
            .await
            .unwrap();
        index
            .insert(entry("abc", "/w", 100, 200, false))
            .await
            .unwrap();
        let raw = std::fs::read_to_string(&path).unwrap();
        // Both legacy keys must appear at the row's top level.
        assert!(raw.contains("\"claudeSessionPath\""), "raw={raw}");
        assert!(raw.contains("\"claudeSessionId\""), "raw={raw}");
        assert!(raw.contains("\"threadId\""), "raw={raw}");
    }

    #[tokio::test]
    async fn startup_repairs_legacy_internal_titles_and_drops_empty_rows() {
        let dir = TempDir::new().unwrap();
        let projects_dir = dir.path().join("projects");
        std::fs::create_dir_all(&projects_dir).unwrap();
        std::fs::write(
            projects_dir.join("dirty.jsonl"),
            [
                r#"{"type":"user","isMeta":true,"cwd":"/work","message":{"role":"user","content":"<local-command-caveat>internal</local-command-caveat>"},"timestamp":"2026-07-17T05:11:50Z"}"#,
                r#"{"type":"user","cwd":"/work","message":{"role":"user","content":"真实标题"},"timestamp":"2026-07-17T05:11:53Z"}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        std::fs::write(
            projects_dir.join("empty.jsonl"),
            r#"{"type":"user","isMeta":true,"cwd":"/work","message":{"role":"user","content":"metadata"}}"#,
        )
        .unwrap();
        std::fs::write(
            projects_dir.join("image-only.jsonl"),
            r#"{"type":"user","cwd":"/work","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}}"#,
        )
        .unwrap();

        let index_path = dir.path().join("threads.json");
        let legacy = CoreThreadIndex::<ClaudeSessionRef>::open_at(index_path.clone())
            .await
            .unwrap();
        let mut dirty = entry("dirty", "/work", 100, 200, false);
        // 旧扫描器只保存第一行，多行 caveat 的索引标题没有闭合标签。
        dirty.preview = "<local-command-caveat>Caveat: generated by local command".into();
        dirty.name = Some("用户命名".into());
        dirty.archived = true;
        legacy.insert(dirty).await.unwrap();
        let mut empty = entry("empty", "/work", 100, 200, false);
        empty.preview = "(no messages)".into();
        legacy.insert(empty).await.unwrap();
        let mut abandoned = entry("abandoned", "/work", 100, 200, false);
        abandoned.preview = String::new();
        legacy.insert(abandoned).await.unwrap();
        let mut image_only = entry("image-only", "/work", 100, 200, false);
        image_only.preview = String::new();
        legacy.insert(image_only).await.unwrap();
        legacy
            .insert(entry("remote-clean", "/remote", 100, 200, false))
            .await
            .unwrap();
        drop(legacy);

        let hydrator = ClaudeHydrator::with_override_dir(projects_dir);
        let repaired = open_index_and_hydrate(index_path, &hydrator).await.unwrap();

        let repaired_dirty = repaired.lookup("dirty").await.unwrap();
        assert_eq!(repaired_dirty.preview, "真实标题");
        assert_eq!(repaired_dirty.name.as_deref(), Some("用户命名"));
        assert!(repaired_dirty.archived);
        assert!(repaired.lookup("empty").await.is_none());
        assert!(repaired.lookup("abandoned").await.is_none());
        assert!(
            repaired.lookup("image-only").await.is_some(),
            "纯图片用户输入是真实会话，不能因标题为空而清理"
        );
        assert!(
            repaired.lookup("remote-clean").await.is_some(),
            "扫描目录不可见的正常远端索引不能被顺带清空"
        );
    }
}
