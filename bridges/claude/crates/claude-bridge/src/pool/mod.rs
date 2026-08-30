//! `ClaudePool` — owns the set of live `claude -p` subprocesses and routes
//! codex thread ids to the right process.
//!
//! Same shape as `crates/pi-bridge/src/pool/`:
//!
//! - **One claude process per codex thread.** Claude binds an implicit
//!   per-process session via `--session-id`, so even when two codex threads
//!   share a `cwd`, each gets its own claude child.
//! - **Idle reaping.** A thread with no in-flight turn for the configured
//!   idle TTL is reaped: stdin is closed (claude exits cleanly, JSONL
//!   persists in `~/.claude/projects/<encoded-cwd>/<session_id>/`).
//! - **Bounded.** A capacity cap LRU-evicts the least-recently-active idle
//!   thread when a new acquire would exceed it. Active threads (turn in
//!   progress) are never evicted — over-cap acquires fail with
//!   [`PoolError::Capacity`] in that case.
//!
//! The bookkeeping lives in [`alleycat_bridge_core::pool::ProcessPool`]; this
//! module wraps it with claude-specific spawn config so callers don't have
//! to re-implement the eviction / capacity loop.

pub mod claude_protocol;
pub mod process;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::pool::ProcessPool;
pub use alleycat_bridge_core::pool::{
    DEFAULT_IDLE_TTL, DEFAULT_MAX_PROCESSES, PoolError, ProcessAdmission, ThreadId,
};
use alleycat_bridge_core::{LocalLauncher, ProcessLauncher};
use tokio::sync::Mutex;
use uuid::Uuid;

pub use claude_protocol::*;
pub use process::{
    ClaudeProcessError, ClaudeProcessHandle, ClaudeSpawnConfig, DEFAULT_INIT_TIMEOUT,
};

/// Pool-wide spawn policy. New fields go here so the per-thread
/// `acquire_*` signatures stay flat.
#[derive(Debug, Clone, Default)]
pub struct PoolPolicy {
    /// When true, every spawned claude gets `--dangerously-skip-permissions`
    /// `--dangerously-skip-permissions`. 0.2 起默认 false；此时 claude
    /// 使用 `--permission-prompt-tool stdio`，并且
    /// the bridge bridges every `can_use_tool` control_request to a codex
    /// `requestApproval` request on the connected client.
    pub bypass_permissions: bool,
}

/// Thread-safe pool of claude processes.
#[derive(Clone)]
pub struct ClaudePool {
    inner: ProcessPool<ClaudeProcessHandle>,
    claude_bin: PathBuf,
    policy: PoolPolicy,
    launcher: Arc<dyn ProcessLauncher>,
    /// 同一时刻只允许一个新进程完成“检查 + 启动 + 入池”，避免两个首轮消息
    /// 同时命中空池时为同一个 thread 重复启动 Claude。
    spawn_lock: Arc<Mutex<()>>,
}

impl std::fmt::Debug for ClaudePool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClaudePool")
            .field("claude_bin", &self.claude_bin)
            .field("policy", &self.policy)
            .finish_non_exhaustive()
    }
}

impl ClaudePool {
    /// Compat shim: build a pool that uses [`LocalLauncher`] and the default
    /// policy. Daemon callers retain the chained `.with_policy(...)` shape via
    /// [`Self::with_policy`].
    pub fn new(claude_bin: impl Into<PathBuf>) -> Self {
        Self::with_launcher(
            claude_bin,
            Arc::new(LocalLauncher) as Arc<dyn ProcessLauncher>,
            PoolPolicy::default(),
        )
    }

    pub fn with_limits(
        claude_bin: impl Into<PathBuf>,
        max_processes: usize,
        idle_ttl: Duration,
    ) -> Self {
        Self::with_launcher_and_limits(
            claude_bin,
            Arc::new(LocalLauncher) as Arc<dyn ProcessLauncher>,
            PoolPolicy::default(),
            max_processes,
            idle_ttl,
        )
    }

    /// Build a pool with an explicit [`ProcessLauncher`] and policy. Used by
    /// [`crate::bridge::ClaudeBridge`] (and Litter) to plug in a non-local
    /// launcher.
    pub fn with_launcher(
        claude_bin: impl Into<PathBuf>,
        launcher: Arc<dyn ProcessLauncher>,
        policy: PoolPolicy,
    ) -> Self {
        Self::with_launcher_and_limits(
            claude_bin,
            launcher,
            policy,
            DEFAULT_MAX_PROCESSES,
            DEFAULT_IDLE_TTL,
        )
    }

    pub fn with_launcher_and_limits(
        claude_bin: impl Into<PathBuf>,
        launcher: Arc<dyn ProcessLauncher>,
        policy: PoolPolicy,
        max_processes: usize,
        idle_ttl: Duration,
    ) -> Self {
        Self {
            inner: ProcessPool::new(max_processes, idle_ttl),
            claude_bin: claude_bin.into(),
            policy,
            launcher,
            spawn_lock: Arc::new(Mutex::new(())),
        }
    }

    /// Snapshot the current policy. Cheap copy.
    pub fn policy(&self) -> PoolPolicy {
        self.policy.clone()
    }

    /// Path of the claude binary this pool spawns.
    pub fn claude_bin(&self) -> &Path {
        &self.claude_bin
    }

    /// Spawn a fresh claude process for a brand-new codex thread, mint a
    /// thread id, and return both. The handler is responsible for
    /// `wait_for_init` before sending the first user envelope.
    pub async fn acquire_for_new_thread(
        &self,
        cwd: impl AsRef<Path>,
        model: Option<String>,
        append_system_prompt: Option<String>,
    ) -> Result<(ThreadId, Arc<ClaudeProcessHandle>), PoolError> {
        let thread_id = Uuid::now_v7().to_string();
        let handle = self
            .spawn_with_capacity_check(
                thread_id.clone(),
                cwd.as_ref(),
                false,
                model,
                None,
                None,
                append_system_prompt,
            )
            .await?;
        Ok((thread_id, handle))
    }

    /// Get or spawn a claude process bound to `cwd` for an explicit
    /// `thread_id`, e.g. when resuming a thread that already exists in the
    /// bridge index. Concurrent acquires for the same thread converge on the
    /// first process that enters the pool.
    pub async fn acquire_for_resume(
        &self,
        thread_id: ThreadId,
        cwd: impl AsRef<Path>,
        model: Option<String>,
        append_system_prompt: Option<String>,
    ) -> Result<Arc<ClaudeProcessHandle>, PoolError> {
        self.spawn_with_capacity_check(
            thread_id,
            cwd.as_ref(),
            true,
            model,
            None,
            None,
            append_system_prompt,
        )
        .await
    }

    /// Reserved counterpart of [`Self::acquire_for_resume`], for callers that
    /// resume a thread and then immediately await a control request on it.
    ///
    /// 预热型调用（拿到就丢弃 handle）应继续用不保留的版本，让进程正常参与
    /// 回收；只有在取得进程后还要 await 的路径才需要 reservation。
    pub async fn acquire_for_resume_with_admission(
        &self,
        thread_id: ThreadId,
        cwd: impl AsRef<Path>,
        model: Option<String>,
        append_system_prompt: Option<String>,
    ) -> Result<(Arc<ClaudeProcessHandle>, ProcessAdmission), PoolError> {
        self.spawn_with_capacity_check_and_admission(
            thread_id,
            cwd.as_ref(),
            true,
            model,
            None,
            None,
            append_system_prompt,
        )
        .await
    }

    /// Get or lazily spawn the process needed by a lazily-created thread,
    /// atomically reserving it for turn admission. `resume` selects
    /// `--resume` for an existing transcript and `--session-id` for a
    /// brand-new thread.
    ///
    /// 只提供带 reservation 的版本：turn/start 是唯一调用方，不保留的变体
    /// 会让准入窗口重新暴露给并发回收。
    pub async fn acquire_for_thread_with_admission(
        &self,
        thread_id: ThreadId,
        cwd: impl AsRef<Path>,
        resume: bool,
        model: Option<String>,
        effort_level: Option<String>,
        permission_mode: Option<String>,
        append_system_prompt: Option<String>,
    ) -> Result<(Arc<ClaudeProcessHandle>, ProcessAdmission), PoolError> {
        self.spawn_with_capacity_check_and_admission(
            thread_id,
            cwd.as_ref(),
            resume,
            model,
            effort_level,
            permission_mode,
            append_system_prompt,
        )
        .await
    }

    /// Borrow a claude process for a one-shot, connection-scoped query
    /// (`mcpServerStatus/list`, `skills/list`). Reuses an existing process
    /// when one matches `cwd`; otherwise picks the LRU thread-bound process;
    /// otherwise spawns a fresh process tagged with a synthetic
    /// `utility_<uuid>` thread id. The synthetic handle rides the normal
    /// idle TTL.
    pub async fn acquire_utility(
        &self,
        cwd: Option<&Path>,
    ) -> Result<Arc<ClaudeProcessHandle>, PoolError> {
        if let Some(handle) = self.inner.try_reuse_for_utility(cwd).await {
            if !handle.has_exited() {
                return Ok(handle);
            }
            self.inner
                .release_if_same(handle.thread_id(), &handle)
                .await;
        }
        let cwd = cwd
            .map(Path::to_path_buf)
            .or_else(|| std::env::current_dir().ok())
            .unwrap_or_else(|| PathBuf::from("."));
        let synthetic_id = format!("utility_{}", Uuid::now_v7());
        self.spawn_with_capacity_check(synthetic_id, &cwd, false, None, None, None, None)
            .await
    }

    /// Look up the claude process that owns `thread_id`, refreshing its
    /// last-active timestamp so the reaper won't pick it up immediately.
    /// Dead handles are synchronously removed and reaped instead of being
    /// handed back to interrupt/resume paths.
    pub async fn get(&self, thread_id: &str) -> Option<Arc<ClaudeProcessHandle>> {
        let handle = self.inner.get(thread_id).await?;
        if !handle.has_exited() {
            return Some(handle);
        }
        self.inner.release_if_same(thread_id, &handle).await;
        None
    }

    /// Lookup + admission reservation in one pool critical section. This is
    /// the turn-start counterpart of [`Self::get`].
    pub async fn get_with_admission(
        &self,
        thread_id: &str,
    ) -> Option<(Arc<ClaudeProcessHandle>, ProcessAdmission)> {
        let (handle, admission) = self.inner.get_with_admission(thread_id).await?;
        if !handle.has_exited() {
            return Some((handle, admission));
        }
        drop(admission);
        self.inner.release_if_same(thread_id, &handle).await;
        None
    }

    /// Mark a thread as currently driving a turn (or any other long-running
    /// operation). Active threads are not eligible for LRU eviction or idle
    /// reaping until [`Self::mark_idle`] is called.
    pub async fn mark_active(&self, thread_id: &str) {
        self.inner.mark_active(thread_id).await
    }

    /// Inverse of [`Self::mark_active`]; refreshes `last_active`.
    pub async fn mark_idle(&self, thread_id: &str) {
        self.inner.mark_idle(thread_id).await
    }

    /// Explicitly release a thread's claude process (e.g. user closed the
    /// thread). Sends EOF on stdin and reaps the child. No-op if the
    /// thread isn't in the pool.
    pub async fn release(&self, thread_id: &str) {
        self.inner.release(thread_id).await
    }

    /// Remove and reap a specific process generation without risking a newer
    /// process that has already been installed for the same thread id.
    pub async fn release_if_same(
        &self,
        thread_id: &str,
        expected: &Arc<ClaudeProcessHandle>,
    ) -> bool {
        self.inner.release_if_same(thread_id, expected).await
    }

    /// All thread ids currently tracked by the pool.
    pub async fn loaded_thread_ids(&self) -> Vec<ThreadId> {
        self.inner.loaded_thread_ids().await
    }

    /// Thread ids running in the given `cwd`.
    pub async fn threads_for_cwd(&self, cwd: impl AsRef<Path>) -> Vec<ThreadId> {
        self.inner.threads_for_cwd(cwd.as_ref()).await
    }

    /// Count of live claude processes (== number of tracked threads).
    pub async fn len(&self) -> usize {
        self.inner.len().await
    }

    /// Returns true when the pool has no live processes.
    pub async fn is_empty(&self) -> bool {
        self.inner.is_empty().await
    }

    /// Sweep idle threads whose `last_active` is older than `idle_ttl`.
    /// Returns the thread ids that were reaped. Callers may run this on a
    /// timer; it's also called opportunistically before each new acquire.
    pub async fn reap_idle(&self) -> Vec<ThreadId> {
        self.inner.reap_idle().await
    }

    /// Spawn `claude -p ...` for the given thread/cwd/config. Performs
    /// idle-reaping and at-cap LRU eviction first; bails with
    /// [`PoolError::Capacity`] only if every tracked thread is currently
    /// active.
    ///
    /// 非 turn 路径不需要准入窗口保护，拿到 handle 后立刻释放 reservation。
    async fn spawn_with_capacity_check(
        &self,
        thread_id: ThreadId,
        cwd: &Path,
        resume: bool,
        model: Option<String>,
        effort_level: Option<String>,
        permission_mode: Option<String>,
        append_system_prompt: Option<String>,
    ) -> Result<Arc<ClaudeProcessHandle>, PoolError> {
        let (handle, admission) = self
            .spawn_with_capacity_check_and_admission(
                thread_id,
                cwd,
                resume,
                model,
                effort_level,
                permission_mode,
                append_system_prompt,
            )
            .await?;
        drop(admission);
        Ok(handle)
    }

    /// Reserved variant used by `turn/start`. A freshly tracked handle enters
    /// the table with its first reservation already held, so no idle window is
    /// observable between spawn and runtime override.
    async fn spawn_with_capacity_check_and_admission(
        &self,
        thread_id: ThreadId,
        cwd: &Path,
        resume: bool,
        model: Option<String>,
        effort_level: Option<String>,
        permission_mode: Option<String>,
        append_system_prompt: Option<String>,
    ) -> Result<(Arc<ClaudeProcessHandle>, ProcessAdmission), PoolError> {
        let _spawn_guard = self.spawn_lock.lock().await;
        if let Some(reserved) = self.get_with_admission(&thread_id).await {
            return Ok(reserved);
        }

        self.inner.ensure_capacity_for(&thread_id).await?;

        let config = ClaudeSpawnConfig {
            thread_id: thread_id.clone(),
            cwd: cwd.to_path_buf(),
            claude_bin: self.claude_bin.clone(),
            model,
            effort_level,
            permission_mode,
            append_system_prompt,
            resume,
            bypass_permissions: self.policy.bypass_permissions,
        };
        let handle = ClaudeProcessHandle::launch_with(Arc::clone(&self.launcher), config)
            .await
            .map_err(PoolError::Spawn)?;
        let handle = Arc::new(handle);
        match self
            .inner
            .track_new_with_admission(thread_id, cwd.to_path_buf(), handle.clone())
            .await
        {
            Ok(admission) => Ok((handle, admission)),
            Err(err) => {
                // Race: another acquire raced us. Drop the new handle.
                handle.shutdown().await;
                Err(err)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_claude_pool(max: usize, ttl: Duration) -> ClaudePool {
        // Use a path that doesn't exist; we never call spawn in these tests
        // — they exercise only the bookkeeping helpers via direct access.
        ClaudePool::with_launcher_and_limits(
            PathBuf::from("/usr/bin/false"),
            Arc::new(LocalLauncher) as Arc<dyn ProcessLauncher>,
            PoolPolicy::default(),
            max,
            ttl,
        )
    }

    async fn track_dummy(pool: &ClaudePool, id: &str, cwd: &str) -> Arc<ClaudeProcessHandle> {
        let (writer_tx, _writer_rx) = tokio::sync::mpsc::unbounded_channel();
        let (events_tx, _) = tokio::sync::broadcast::channel(1);
        let handle = ClaudeProcessHandle::__test_dangling(writer_tx, events_tx, PathBuf::from(cwd));
        let handle = Arc::new(handle);
        pool.inner
            .track_new(id.into(), PathBuf::from(cwd), handle.clone())
            .await
            .expect("track");
        handle
    }

    #[tokio::test]
    async fn loaded_thread_ids_and_len() {
        let pool = fake_claude_pool(8, Duration::from_secs(60));
        assert_eq!(pool.len().await, 0);
        assert!(pool.is_empty().await);
        track_dummy(&pool, "alpha", "/a").await;
        track_dummy(&pool, "beta", "/b").await;
        assert_eq!(pool.len().await, 2);
        let mut ids = pool.loaded_thread_ids().await;
        ids.sort();
        assert_eq!(ids, vec!["alpha".to_string(), "beta".to_string()]);
    }

    #[tokio::test]
    async fn threads_for_cwd_indexes_correctly() {
        let pool = fake_claude_pool(8, Duration::from_secs(60));
        track_dummy(&pool, "t1", "/x").await;
        track_dummy(&pool, "t2", "/x").await;
        track_dummy(&pool, "t3", "/y").await;
        let mut x = pool.threads_for_cwd("/x").await;
        x.sort();
        assert_eq!(x, vec!["t1".to_string(), "t2".to_string()]);
        assert_eq!(pool.threads_for_cwd("/y").await, vec!["t3".to_string()]);
    }

    #[tokio::test]
    async fn mark_active_blocks_lru_pick_via_ensure_capacity() {
        let pool = fake_claude_pool(1, Duration::from_secs(60));
        track_dummy(&pool, "only", "/a").await;
        pool.mark_active("only").await;
        let err = pool.inner.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));
        pool.mark_idle("only").await;
        pool.inner.ensure_capacity_for("new").await.expect("ok");
    }

    #[tokio::test]
    async fn acquire_utility_reuses_cwd_match_when_present() {
        let pool = fake_claude_pool(8, Duration::from_secs(60));
        let target_handle = track_dummy(&pool, "t1", "/repo").await;
        track_dummy(&pool, "t2", "/other").await;
        // Use try_reuse directly because acquire_utility would attempt a
        // spawn fallback when no reuse is found, and these dummy handles
        // can't actually be relaunched.
        let handle = pool
            .inner
            .try_reuse_for_utility(Some(Path::new("/repo")))
            .await
            .expect("utility");
        assert!(Arc::ptr_eq(&handle, &target_handle));
    }
}
