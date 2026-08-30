//! Generic process-pool bookkeeping for bridges that follow the
//! one-process-per-thread + LRU-evict + idle-reap pattern.
//!
//! Used by `crates/claude-bridge/src/pool/` and `crates/pi-bridge/src/pool/`,
//! which were previously near-identical copies. The vendor-specific spawn
//! step (binary path, command-line arguments, init handshake) stays in the
//! bridge crate; this module only owns the table of live handles, the
//! cwd→threads index, and the capacity/eviction policy.
//!
//! Usage shape:
//! ```text
//! 1. Bridge wraps `ProcessPool<MyHandle>` plus its own spawn config.
//! 2. acquire_for_new_thread:
//!      let thread_id = uuid::Uuid::now_v7().to_string();
//!      pool.ensure_capacity_for(&thread_id).await?;
//!      let handle = MyHandle::spawn(...).await?;
//!      pool.track_new(thread_id.clone(), cwd, Arc::new(handle)).await?;
//! 3. get/mark_active/mark_idle/release delegate straight through.
//! ```

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use thiserror::Error;
use tokio::sync::Mutex;

/// Codex thread identifier as it appears on the wire (UUID-shaped string).
/// Matches the type alias each bridge already exports — kept alphabetic-cheap
/// rather than newtyped so callers thread the raw string through to handlers
/// without an extra wrapper.
pub type ThreadId = String;

/// Bounded pool default — 16 concurrent processes per bridge. Generous enough
/// for typical workflows, low enough that a runaway client can't exhaust
/// system resources.
pub const DEFAULT_MAX_PROCESSES: usize = 16;

/// Idle reap interval default — 10 minutes.
pub const DEFAULT_IDLE_TTL: Duration = Duration::from_secs(10 * 60);

/// Trait that every pool member implements. The pool needs to be able to
/// shut a handle down cleanly when the entry is reaped or evicted; the rest
/// (stdin/stdout, control requests, etc.) is owned by the bridge.
pub trait PoolMember: Send + Sync {
    /// Send EOF / signal the underlying child process and wait for it to
    /// exit. The pool calls this on reap and eviction.
    fn shutdown(&self) -> impl std::future::Future<Output = ()> + Send;
}

#[derive(Debug, Error)]
pub enum PoolError {
    #[error("pool is at capacity ({0} processes); no idle thread to evict")]
    Capacity(usize),

    #[error("thread {0} already exists in the pool")]
    DuplicateThread(ThreadId),

    #[error(transparent)]
    Spawn(#[from] anyhow::Error),
}

/// Per-thread bookkeeping the pool keeps alongside each handle.
struct PoolEntry<H> {
    handle: Arc<H>,
    cwd: PathBuf,
    last_active: Instant,
    /// True while a turn is being driven through this thread. The reaper
    /// never evicts threads with `active=true` regardless of TTL.
    active: bool,
    /// 正在准入、但尚未正式进入 active turn 的调用数。runtime override 等 await
    /// 必须由 reservation 覆盖；否则容量回收会把正在准入的子进程当成 idle 关闭。
    admissions: Arc<AtomicUsize>,
}

impl<H> PoolEntry<H> {
    /// 仅约束自动回收（idle reaping / LRU eviction）。显式的 `release` 与
    /// `release_if_same` 有意不看这个标志：它们的调用方已经确认进程不可用
    /// （例如 handle 已退出），此时保留 reservation 只会把坏进程留在池里。
    ///
    /// 副作用：池满且所有 idle 进程都处于准入期时，`ensure_capacity_for`
    /// 会返回 `PoolError::Capacity` 而不是淘汰其中一个。reservation 只覆盖
    /// turn 准入这一小段，正常情况极短；这是为了不误杀而接受的取舍。
    fn is_evictable(&self) -> bool {
        !self.active && self.admissions.load(Ordering::Acquire) == 0
    }
}

/// Keeps a tracked process out of idle reaping/LRU eviction while a caller is
/// still admitting work. The synchronous `Drop` is intentional: cancellation
/// may drop a `turn/start` future at any await point, where async cleanup would
/// otherwise be easy to miss.
#[derive(Debug)]
#[must_use = "dropping the admission immediately makes the process evictable again"]
pub struct ProcessAdmission {
    admissions: Arc<AtomicUsize>,
}

impl Drop for ProcessAdmission {
    fn drop(&mut self) {
        let previous = self.admissions.fetch_sub(1, Ordering::AcqRel);
        debug_assert!(previous > 0, "process admission counter underflow");
    }
}

struct PoolInner<H> {
    processes: HashMap<ThreadId, PoolEntry<H>>,
    by_cwd: HashMap<PathBuf, HashSet<ThreadId>>,
    max_processes: usize,
    idle_ttl: Duration,
}

impl<H> PoolInner<H> {
    fn insert(&mut self, thread_id: ThreadId, entry: PoolEntry<H>) {
        self.by_cwd
            .entry(entry.cwd.clone())
            .or_default()
            .insert(thread_id.clone());
        self.processes.insert(thread_id, entry);
    }

    fn remove(&mut self, thread_id: &str) -> Option<PoolEntry<H>> {
        let entry = self.processes.remove(thread_id)?;
        if let Some(set) = self.by_cwd.get_mut(&entry.cwd) {
            set.remove(thread_id);
            if set.is_empty() {
                self.by_cwd.remove(&entry.cwd);
            }
        }
        Some(entry)
    }

    /// Pick the least-recently-active *idle* thread for eviction. Returns
    /// `None` when every thread currently has a turn in flight.
    fn pick_lru_idle(&self) -> Option<ThreadId> {
        self.processes
            .iter()
            .filter(|(_, e)| e.is_evictable())
            .min_by_key(|(_, e)| e.last_active)
            .map(|(id, _)| id.clone())
    }

    fn collect_expired(&self, now: Instant) -> Vec<ThreadId> {
        self.processes
            .iter()
            .filter(|(_, e)| e.is_evictable() && now.duration_since(e.last_active) >= self.idle_ttl)
            .map(|(id, _)| id.clone())
            .collect()
    }
}

/// Generic process pool. Each `H` instance is the bridge's per-thread handle
/// type (e.g. `ClaudeProcessHandle`, `PiProcessHandle`).
pub struct ProcessPool<H: PoolMember> {
    inner: Arc<Mutex<PoolInner<H>>>,
}

impl<H: PoolMember> Clone for ProcessPool<H> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl<H: PoolMember + 'static> ProcessPool<H> {
    pub fn new(max_processes: usize, idle_ttl: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(PoolInner {
                processes: HashMap::new(),
                by_cwd: HashMap::new(),
                max_processes: max_processes.max(1),
                idle_ttl,
            })),
        }
    }

    /// Look up a tracked process by thread id, refreshing its `last_active`
    /// so the reaper won't pick it up immediately.
    pub async fn get(&self, thread_id: &str) -> Option<Arc<H>> {
        let mut inner = self.inner.lock().await;
        let entry = inner.processes.get_mut(thread_id)?;
        entry.last_active = Instant::now();
        Some(entry.handle.clone())
    }

    /// Atomically look up a process and reserve it before releasing the pool
    /// lock. Capacity eviction therefore cannot slip between lookup and the
    /// caller's first awaited admission step.
    pub async fn get_with_admission(&self, thread_id: &str) -> Option<(Arc<H>, ProcessAdmission)> {
        let mut inner = self.inner.lock().await;
        let entry = inner.processes.get_mut(thread_id)?;
        entry.last_active = Instant::now();
        entry.admissions.fetch_add(1, Ordering::AcqRel);
        Some((
            entry.handle.clone(),
            ProcessAdmission {
                admissions: Arc::clone(&entry.admissions),
            },
        ))
    }

    /// Mark a thread as currently driving a turn. Active threads are not
    /// eligible for LRU eviction or idle reaping until [`Self::mark_idle`].
    pub async fn mark_active(&self, thread_id: &str) {
        let mut inner = self.inner.lock().await;
        if let Some(entry) = inner.processes.get_mut(thread_id) {
            entry.active = true;
            entry.last_active = Instant::now();
        }
    }

    /// Inverse of [`Self::mark_active`]; refreshes `last_active`.
    pub async fn mark_idle(&self, thread_id: &str) {
        let mut inner = self.inner.lock().await;
        if let Some(entry) = inner.processes.get_mut(thread_id) {
            entry.active = false;
            entry.last_active = Instant::now();
        }
    }

    /// Explicitly release a thread's handle. Sends shutdown and reaps.
    ///
    /// 与自动回收不同，这里不检查 admission reservation：调用方已经确认进程
    /// 不可用，保留 reservation 只会把坏进程留在池里。
    pub async fn release(&self, thread_id: &str) {
        let entry = {
            let mut inner = self.inner.lock().await;
            inner.remove(thread_id)
        };
        if let Some(entry) = entry {
            entry.handle.shutdown().await;
        }
    }

    /// Release only when `thread_id` still points at `expected`.
    ///
    /// 异常退出的旧 driver 可能晚于新进程结束清理。按 `Arc` 实例比较后再删除，
    /// 避免旧 driver 把同一 thread 刚冷恢复出来的新进程误删。
    pub async fn release_if_same(&self, thread_id: &str, expected: &Arc<H>) -> bool {
        let entry = {
            let mut inner = self.inner.lock().await;
            let matches = inner
                .processes
                .get(thread_id)
                .is_some_and(|entry| Arc::ptr_eq(&entry.handle, expected));
            matches.then(|| inner.remove(thread_id)).flatten()
        };
        if let Some(entry) = entry {
            entry.handle.shutdown().await;
            true
        } else {
            false
        }
    }

    pub async fn loaded_thread_ids(&self) -> Vec<ThreadId> {
        self.inner.lock().await.processes.keys().cloned().collect()
    }

    pub async fn threads_for_cwd(&self, cwd: &Path) -> Vec<ThreadId> {
        self.inner
            .lock()
            .await
            .by_cwd
            .get(cwd)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default()
    }

    pub async fn len(&self) -> usize {
        self.inner.lock().await.processes.len()
    }

    pub async fn is_empty(&self) -> bool {
        self.inner.lock().await.processes.is_empty()
    }

    /// Sweep idle threads whose `last_active` is older than `idle_ttl`.
    /// Returns the thread ids that were reaped.
    pub async fn reap_idle(&self) -> Vec<ThreadId> {
        let now = Instant::now();
        let expired_entries: Vec<(ThreadId, PoolEntry<H>)> = {
            let mut inner = self.inner.lock().await;
            // 判定与 remove 必须在同一把锁内完成。若先收集 id 再重锁，期间新到的
            // admission/active 标记仍会被旧快照无条件删除。
            let expired = inner.collect_expired(now);
            expired
                .into_iter()
                .filter_map(|id| inner.remove(&id).map(|entry| (id, entry)))
                .collect()
        };
        let mut reaped = Vec::with_capacity(expired_entries.len());
        for (id, entry) in expired_entries {
            entry.handle.shutdown().await;
            reaped.push(id);
        }
        reaped
    }

    /// Try to find an existing handle the caller can reuse for a one-shot
    /// utility query. Strategy:
    /// 1. cwd-scoped reuse (any tracked thread bound to `cwd`),
    /// 2. cwd-agnostic reuse (LRU thread-bound process),
    /// 3. None — caller should spawn a fresh handle.
    pub async fn try_reuse_for_utility(&self, cwd: Option<&Path>) -> Option<Arc<H>> {
        let inner = self.inner.lock().await;
        let cwd_handle = cwd.and_then(|target| {
            inner
                .by_cwd
                .get(target)
                .and_then(|set| set.iter().next())
                .and_then(|id| inner.processes.get(id))
                .map(|e| e.handle.clone())
        });
        if let Some(handle) = cwd_handle {
            return Some(handle);
        }
        inner
            .processes
            .iter()
            .min_by_key(|(_, e)| e.last_active)
            .map(|(_, e)| e.handle.clone())
    }

    /// Reap idle entries and, if needed, evict the LRU idle thread to make
    /// room for one new spawn. Returns `Capacity` if every tracked thread
    /// is currently active. The pool is unchanged on success — callers must
    /// follow up with [`Self::track_new`] once the spawn completes.
    pub async fn ensure_capacity_for(&self, thread_id: &str) -> Result<(), PoolError> {
        {
            let inner = self.inner.lock().await;
            if inner.processes.contains_key(thread_id) {
                return Err(PoolError::DuplicateThread(thread_id.to_string()));
            }
        }
        self.reap_idle().await;
        loop {
            let evicted = {
                let mut inner = self.inner.lock().await;
                if inner.processes.len() < inner.max_processes {
                    return Ok(());
                }
                let Some(victim) = inner.pick_lru_idle() else {
                    return Err(PoolError::Capacity(inner.max_processes));
                };
                // 与 reap_idle 相同，最后一次 eligibility 判定和 remove 不能跨锁。
                inner.remove(&victim)
            };
            if let Some(entry) = evicted {
                entry.handle.shutdown().await;
            }
        }
    }

    /// Register a freshly-spawned handle in the pool. Returns
    /// `DuplicateThread` if a race added a handle for `thread_id` first; the
    /// caller is responsible for shutting the new handle down in that case.
    pub async fn track_new(
        &self,
        thread_id: ThreadId,
        cwd: PathBuf,
        handle: Arc<H>,
    ) -> Result<(), PoolError> {
        let mut inner = self.inner.lock().await;
        if inner.processes.contains_key(&thread_id) {
            return Err(PoolError::DuplicateThread(thread_id));
        }
        inner.insert(
            thread_id,
            PoolEntry {
                handle,
                cwd,
                last_active: Instant::now(),
                active: false,
                admissions: Arc::new(AtomicUsize::new(0)),
            },
        );
        Ok(())
    }

    /// Register a freshly spawned process and return its first admission as a
    /// single atomic pool operation. The new entry is never observable as idle
    /// between `track_new` and the caller receiving its handle.
    pub async fn track_new_with_admission(
        &self,
        thread_id: ThreadId,
        cwd: PathBuf,
        handle: Arc<H>,
    ) -> Result<ProcessAdmission, PoolError> {
        let mut inner = self.inner.lock().await;
        if inner.processes.contains_key(&thread_id) {
            return Err(PoolError::DuplicateThread(thread_id));
        }
        let admissions = Arc::new(AtomicUsize::new(1));
        inner.insert(
            thread_id,
            PoolEntry {
                handle,
                cwd,
                last_active: Instant::now(),
                active: false,
                admissions: Arc::clone(&admissions),
            },
        );
        Ok(ProcessAdmission { admissions })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Fake handle that just tracks how many times shutdown has been called.
    struct FakeHandle {
        shutdowns: Arc<AtomicUsize>,
    }

    impl FakeHandle {
        fn new() -> (Arc<Self>, Arc<AtomicUsize>) {
            let shutdowns = Arc::new(AtomicUsize::new(0));
            (
                Arc::new(Self {
                    shutdowns: shutdowns.clone(),
                }),
                shutdowns,
            )
        }
    }

    impl PoolMember for FakeHandle {
        async fn shutdown(&self) {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn pool(max: usize, ttl: Duration) -> ProcessPool<FakeHandle> {
        ProcessPool::new(max, ttl)
    }

    async fn track(
        pool: &ProcessPool<FakeHandle>,
        id: &str,
        cwd: &str,
    ) -> (Arc<FakeHandle>, Arc<AtomicUsize>) {
        let (handle, counter) = FakeHandle::new();
        pool.track_new(id.into(), PathBuf::from(cwd), handle.clone())
            .await
            .expect("track_new");
        (handle, counter)
    }

    /// 把某个条目的 `last_active` 往前拨，用于跨过 idle TTL。
    async fn backdate(pool: &ProcessPool<FakeHandle>, id: &str, by: Duration) {
        let mut inner = pool.inner.lock().await;
        let entry = inner.processes.get_mut(id).expect("tracked process");
        entry.last_active = Instant::now() - by;
    }

    #[tokio::test]
    async fn track_get_release_roundtrip() {
        let p = pool(4, Duration::from_secs(60));
        let (h, counter) = track(&p, "t1", "/a").await;
        let fetched = p.get("t1").await.expect("get");
        assert!(Arc::ptr_eq(&fetched, &h));
        assert_eq!(p.len().await, 1);
        p.release("t1").await;
        assert_eq!(counter.load(Ordering::SeqCst), 1);
        assert!(p.is_empty().await);
    }

    #[tokio::test]
    async fn duplicate_track_errors() {
        let p = pool(4, Duration::from_secs(60));
        track(&p, "t1", "/a").await;
        let (handle2, _) = FakeHandle::new();
        let err = p
            .track_new("t1".into(), PathBuf::from("/a"), handle2)
            .await
            .unwrap_err();
        assert!(matches!(err, PoolError::DuplicateThread(_)));
    }

    #[tokio::test]
    async fn release_if_same_never_removes_replacement() {
        let p = pool(4, Duration::from_secs(60));
        let (old, old_shutdowns) = track(&p, "t1", "/a").await;
        let (unrelated, _) = FakeHandle::new();

        assert!(!p.release_if_same("t1", &unrelated).await);
        assert!(Arc::ptr_eq(&p.get("t1").await.expect("old remains"), &old));
        assert_eq!(old_shutdowns.load(Ordering::SeqCst), 0);

        assert!(p.release_if_same("t1", &old).await);
        assert!(p.get("t1").await.is_none());
        assert_eq!(old_shutdowns.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn reap_idle_drops_old_inactive_only() {
        let p = pool(8, Duration::from_millis(50));
        track(&p, "young".into(), "/a").await;
        track(&p, "old_active".into(), "/b").await;
        p.mark_active("old_active").await;
        // Backdate "old_active" and "old_inactive" by hand via insert-with-age.
        let (h, _) = FakeHandle::new();
        {
            let mut inner = p.inner.lock().await;
            inner.insert(
                "old_inactive".into(),
                PoolEntry {
                    handle: h,
                    cwd: PathBuf::from("/c"),
                    last_active: Instant::now() - Duration::from_secs(60),
                    active: false,
                    admissions: Arc::new(AtomicUsize::new(0)),
                },
            );
        }
        // active threads aren't reaped; young threads aren't reaped.
        let reaped = p.reap_idle().await;
        assert_eq!(reaped, vec!["old_inactive".to_string()]);
        assert!(p.get("young").await.is_some());
        assert!(p.get("old_active").await.is_some());
    }

    #[tokio::test]
    async fn ensure_capacity_evicts_lru_idle() {
        let p = pool(2, Duration::from_secs(60));
        track(&p, "lru", "/a").await;
        // Backdate lru by manually rewriting last_active.
        {
            let mut inner = p.inner.lock().await;
            if let Some(e) = inner.processes.get_mut("lru") {
                e.last_active = Instant::now() - Duration::from_secs(120);
            }
        }
        track(&p, "fresh", "/b").await;
        assert_eq!(p.len().await, 2);
        // Pool is at cap; ensure_capacity_for("new") should evict "lru".
        p.ensure_capacity_for("new").await.expect("space");
        assert_eq!(p.len().await, 1);
        assert!(p.get("lru").await.is_none());
        assert!(p.get("fresh").await.is_some());
    }

    #[tokio::test]
    async fn ensure_capacity_errors_when_all_active() {
        let p = pool(2, Duration::from_secs(60));
        track(&p, "a", "/a").await;
        track(&p, "b", "/b").await;
        p.mark_active("a").await;
        p.mark_active("b").await;
        let err = p.ensure_capacity_for("c").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(2)));
    }

    #[tokio::test]
    async fn ensure_capacity_errors_on_existing_id() {
        let p = pool(2, Duration::from_secs(60));
        track(&p, "x", "/a").await;
        let err = p.ensure_capacity_for("x").await.unwrap_err();
        assert!(matches!(err, PoolError::DuplicateThread(_)));
    }

    #[tokio::test]
    async fn try_reuse_for_utility_prefers_cwd_match() {
        let p = pool(8, Duration::from_secs(60));
        let (a_handle, _) = track(&p, "a", "/repo").await;
        track(&p, "b", "/other").await;
        let h = p
            .try_reuse_for_utility(Some(Path::new("/repo")))
            .await
            .expect("reuse");
        assert!(Arc::ptr_eq(&h, &a_handle));
    }

    #[tokio::test]
    async fn try_reuse_for_utility_falls_back_to_lru() {
        let p = pool(8, Duration::from_secs(60));
        let (older_handle, _) = track(&p, "older", "/x").await;
        // Backdate the first entry so it becomes the LRU pick.
        {
            let mut inner = p.inner.lock().await;
            if let Some(e) = inner.processes.get_mut("older") {
                e.last_active = Instant::now() - Duration::from_secs(60);
            }
        }
        track(&p, "newer", "/y").await;
        let h = p.try_reuse_for_utility(None).await.expect("reuse");
        assert!(Arc::ptr_eq(&h, &older_handle));
    }

    #[tokio::test]
    async fn try_reuse_for_utility_returns_none_when_empty() {
        let p = pool(2, Duration::from_secs(60));
        assert!(p.try_reuse_for_utility(None).await.is_none());
    }

    #[tokio::test]
    async fn mark_active_blocks_lru_eviction() {
        let p = pool(1, Duration::from_secs(60));
        track(&p, "only", "/a").await;
        p.mark_active("only").await;
        let err = p.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));
        p.mark_idle("only").await;
        // Now the LRU pick is allowed.
        p.ensure_capacity_for("new").await.expect("ok");
    }

    #[tokio::test]
    async fn process_admission_blocks_lru_eviction_until_drop() {
        let p = pool(1, Duration::from_secs(60));
        track(&p, "only", "/a").await;

        let (_, admission) = p.get_with_admission("only").await.expect("tracked process");
        let err = p.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));
        assert!(p.get("only").await.is_some());

        drop(admission);
        p.ensure_capacity_for("new")
            .await
            .expect("evict after drop");
        assert!(p.get("only").await.is_none());
    }

    #[tokio::test]
    async fn overlapping_admissions_release_independently() {
        let p = pool(1, Duration::from_secs(60));
        track(&p, "only", "/a").await;

        let (_, first) = p.get_with_admission("only").await.expect("first admission");
        let (_, second) = p
            .get_with_admission("only")
            .await
            .expect("second admission");

        drop(first);
        let err = p.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));

        drop(second);
        p.ensure_capacity_for("new")
            .await
            .expect("evictable after final admission drops");
        assert!(p.get("only").await.is_none());
    }

    #[tokio::test]
    async fn process_admission_blocks_idle_reaping_until_drop() {
        let p = pool(4, Duration::from_secs(30));
        track(&p, "stale", "/a").await;

        let (_, admission) = p
            .get_with_admission("stale")
            .await
            .expect("tracked process");
        // 准入会刷新 last_active，回填到 TTL 之外，才能验证是 reservation
        // 而不是时间戳挡住了回收。
        backdate(&p, "stale", Duration::from_secs(60)).await;

        assert!(p.reap_idle().await.is_empty());
        assert_eq!(p.len().await, 1);

        drop(admission);
        assert_eq!(p.reap_idle().await, vec!["stale".to_string()]);
        assert!(p.is_empty().await);
    }

    /// 取消发生在 `turn/start` 的 await 点上：future 被丢弃时 `Drop` 必须
    /// 归还 reservation，否则该进程会永久退出回收候选集。
    #[tokio::test]
    async fn cancelled_admission_future_does_not_leak_reservation() {
        let p = Arc::new(pool(1, Duration::from_secs(60)));
        track(&p, "only", "/a").await;

        let (tx, rx) = tokio::sync::oneshot::channel();
        let pool_handle = Arc::clone(&p);
        let admitting = tokio::spawn(async move {
            let (_handle, _admission) = pool_handle
                .get_with_admission("only")
                .await
                .expect("tracked process");
            tx.send(()).expect("signal admission taken");
            // 代表 apply_runtime_overrides：取消就发生在这里。
            std::future::pending::<()>().await;
        });
        rx.await.expect("admission taken");

        let err = p.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));

        admitting.abort();
        assert!(admitting.await.unwrap_err().is_cancelled());

        p.ensure_capacity_for("new")
            .await
            .expect("evictable again after cancellation");
        assert!(p.get("only").await.is_none());
    }

    #[tokio::test]
    async fn fresh_process_is_reserved_at_registration() {
        let p = pool(1, Duration::from_secs(60));
        let (handle, _) = FakeHandle::new();
        let admission = p
            .track_new_with_admission("only".into(), PathBuf::from("/a"), handle)
            .await
            .expect("track and reserve");

        let err = p.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));
        drop(admission);
        p.ensure_capacity_for("new")
            .await
            .expect("evict after drop");
    }

    #[tokio::test]
    async fn threads_for_cwd_indexes_correctly() {
        let p = pool(8, Duration::from_secs(60));
        track(&p, "t1", "/x").await;
        track(&p, "t2", "/x").await;
        track(&p, "t3", "/y").await;
        let mut x = p.threads_for_cwd(Path::new("/x")).await;
        x.sort();
        assert_eq!(x, vec!["t1".to_string(), "t2".to_string()]);
        assert_eq!(
            p.threads_for_cwd(Path::new("/y")).await,
            vec!["t3".to_string()]
        );
        p.release("t1").await;
        assert_eq!(
            p.threads_for_cwd(Path::new("/x")).await,
            vec!["t2".to_string()]
        );
    }
}
