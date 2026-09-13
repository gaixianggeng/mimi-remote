//! `thread/takeover`：结束正持有某会话的本机 Claude 进程（终端 `claude`、Claude 桌面
//! 内置 Claude Code），让 bridge 以同一个 session id 续聊。
//!
//! 实测 Claude Code 2.1.270：交互式进程收到 SIGINT 后，无论空闲还是正在生成都会
//! 立即干净退出并删除 `~/.claude/sessions/<pid>.json`；SIGTERM 只作兜底。被打断的
//! 会话用同 id `--resume` 单链续上（CLI 自己会补一对 "Continue from where you left
//! off" / "No response requested"）。
//!
//! 发信号的前提缺一不可：登记了该 sessionId、pid 存活、不是进程池子进程、进程启动
//! 时间与登记 `startedAt` 吻合（防 pid 被别的进程复用）。任一持有方核实不了就整体
//! 拒绝，一个信号都不发。持有方退出后再扫一次登记：出现新 pid 认领同一 session
//! （宿主自动重启）时报 `holder_respawned` 且不再发信号，杜绝杀进程循环。

use std::collections::HashSet;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::foreign_session::{
    ForeignSessionOwner, ForeignSessionRegistry, ProcessSignal, pid_is_alive,
    process_start_epoch_secs, signal_pid,
};

/// 进程启动时间与登记 `startedAt` 允许的最大偏差。CLI 在自身初始化后才写登记，
/// 实测相差约 2 秒。
const START_TIME_TOLERANCE: Duration = Duration::from_secs(10);
const POLL_INTERVAL: Duration = Duration::from_millis(200);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TakeoverTimeouts {
    /// SIGINT 后等待持有方退出的时间。
    pub interrupt_grace: Duration,
    /// SIGTERM 后等待持有方退出的时间。
    pub terminate_grace: Duration,
    /// 持有方退出后观察是否有新进程认领同一 session 的时间。
    pub respawn_grace: Duration,
}

impl Default for TakeoverTimeouts {
    fn default() -> Self {
        Self {
            interrupt_grace: Duration::from_secs(5),
            terminate_grace: Duration::from_secs(5),
            respawn_grace: Duration::from_secs(1),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TakeoverOutcome {
    /// 没有别处持有方（或探测策略关闭）：等价于普通 resume。
    NoHolder,
    /// 持有方全部退出，最后一次用的是哪个信号。
    Released {
        holders: Vec<ForeignSessionOwner>,
        signal: ProcessSignal,
    },
}

impl TakeoverOutcome {
    /// 回给客户端的摘要：是否真的结束了别人、结束了谁、用了什么信号。
    pub fn to_json(&self) -> Value {
        match self {
            TakeoverOutcome::NoHolder => serde_json::json!({ "released": false }),
            TakeoverOutcome::Released { holders, signal } => serde_json::json!({
                "released": true,
                "holder": holders.first().map(ForeignSessionOwner::to_json),
                "signal": signal.as_str(),
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TakeoverError {
    #[error("holder pid {} cannot be verified against its session registration", .0.pid)]
    HolderUnverified(ForeignSessionOwner),
    #[error("failed to signal holder pid {}: {message}", holder.pid)]
    SignalFailed {
        holder: ForeignSessionOwner,
        message: String,
    },
    #[error("holder pid {} did not exit after SIGINT and SIGTERM", .0.pid)]
    Timeout(ForeignSessionOwner),
    #[error("a new process (pid {}) claimed the session after the holder exited", .0.pid)]
    Respawned(ForeignSessionOwner),
}

impl TakeoverError {
    pub fn reason(&self) -> &'static str {
        match self {
            TakeoverError::HolderUnverified(_) => "holder_unverified",
            TakeoverError::SignalFailed { .. } => "signal_failed",
            TakeoverError::Timeout(_) => "takeover_timeout",
            TakeoverError::Respawned(_) => "holder_respawned",
        }
    }

    /// 只有超时值得原样重试：持有方可能只是退出得慢。其余情况重试只会重复发信号
    /// 或再次拒绝。
    pub fn retryable(&self) -> bool {
        matches!(self, TakeoverError::Timeout(_))
    }

    pub fn holder(&self) -> &ForeignSessionOwner {
        match self {
            TakeoverError::HolderUnverified(holder)
            | TakeoverError::Timeout(holder)
            | TakeoverError::Respawned(holder) => holder,
            TakeoverError::SignalFailed { holder, .. } => holder,
        }
    }
}

/// 结束 `session_id` 的所有别处持有方并等待它们退出。不动进程池子进程。
pub async fn release_foreign_holders(
    registry: &ForeignSessionRegistry,
    session_id: &str,
    own_pids: &HashSet<u32>,
    timeouts: &TakeoverTimeouts,
) -> Result<TakeoverOutcome, TakeoverError> {
    let holders = registry.holders_of(session_id, own_pids).await;
    if holders.is_empty() {
        return Ok(TakeoverOutcome::NoHolder);
    }
    // 先全部核实再发信号：任一核实不了就一个都不动。
    for holder in &holders {
        verify_holder(holder)?;
    }

    let mut signal = ProcessSignal::Interrupt;
    for holder in &holders {
        send(holder, signal)?;
    }
    let mut survivors = wait_for_exit(&holders, timeouts.interrupt_grace).await;
    if !survivors.is_empty() {
        signal = ProcessSignal::Terminate;
        for holder in &survivors {
            send(holder, signal)?;
        }
        survivors = wait_for_exit(&survivors, timeouts.terminate_grace).await;
    }
    if let Some(holder) = survivors.into_iter().next() {
        return Err(TakeoverError::Timeout(holder));
    }

    // 宿主（比如桌面 App）可能自动重启一个新进程接回同一个 session；那时不能再杀，
    // 否则就是一个杀进程循环。只报告，让用户决定。
    tokio::time::sleep(timeouts.respawn_grace).await;
    let known: HashSet<u32> = holders.iter().map(|holder| holder.pid).collect();
    if let Some(newcomer) = registry
        .holders_of(session_id, own_pids)
        .await
        .into_iter()
        .find(|holder| !known.contains(&holder.pid))
    {
        return Err(TakeoverError::Respawned(newcomer));
    }
    Ok(TakeoverOutcome::Released { holders, signal })
}

/// 登记文件是 Claude 进程自己写的，进程崩溃时可能残留；pid 之后被别的程序复用就会
/// 误杀无关进程。这里要求内核记录的进程启动时间与登记里的 `startedAt` 吻合。
fn verify_holder(holder: &ForeignSessionOwner) -> Result<(), TakeoverError> {
    if holder.pid <= 1 || holder.pid == std::process::id() {
        return Err(TakeoverError::HolderUnverified(holder.clone()));
    }
    let (Some(registered_ms), Some(actual_secs)) =
        (holder.started_at_ms, process_start_epoch_secs(holder.pid))
    else {
        return Err(TakeoverError::HolderUnverified(holder.clone()));
    };
    let registered = Duration::from_millis(registered_ms);
    let actual = Duration::from_secs(actual_secs);
    let skew = if registered > actual {
        registered - actual
    } else {
        actual - registered
    };
    if skew > START_TIME_TOLERANCE {
        return Err(TakeoverError::HolderUnverified(holder.clone()));
    }
    Ok(())
}

fn send(holder: &ForeignSessionOwner, signal: ProcessSignal) -> Result<(), TakeoverError> {
    signal_pid(holder.pid, signal).map_err(|err| TakeoverError::SignalFailed {
        holder: holder.clone(),
        message: err.to_string(),
    })
}

/// 轮询到全部退出或超时；返回仍存活的持有方。
async fn wait_for_exit(
    holders: &[ForeignSessionOwner],
    grace: Duration,
) -> Vec<ForeignSessionOwner> {
    let deadline = Instant::now() + grace;
    loop {
        let alive: Vec<ForeignSessionOwner> = holders
            .iter()
            .filter(|holder| pid_is_alive(holder.pid))
            .cloned()
            .collect();
        let now = Instant::now();
        if alive.is_empty() || now >= deadline {
            return alive;
        }
        tokio::time::sleep(POLL_INTERVAL.min(deadline - now)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner(pid: u32, started_at_ms: Option<u64>) -> ForeignSessionOwner {
        ForeignSessionOwner {
            pid,
            entrypoint: Some("cli".into()),
            kind: Some("interactive".into()),
            status: None,
            version: None,
            started_at_ms,
        }
    }

    #[test]
    fn errors_map_to_stable_reasons_and_only_timeout_is_retryable() {
        let holder = owner(4242, None);
        let cases = [
            (
                TakeoverError::HolderUnverified(holder.clone()),
                "holder_unverified",
                false,
            ),
            (
                TakeoverError::SignalFailed {
                    holder: holder.clone(),
                    message: "EPERM".into(),
                },
                "signal_failed",
                false,
            ),
            (
                TakeoverError::Timeout(holder.clone()),
                "takeover_timeout",
                true,
            ),
            (
                TakeoverError::Respawned(holder.clone()),
                "holder_respawned",
                false,
            ),
        ];
        for (error, reason, retryable) in cases {
            assert_eq!(error.reason(), reason);
            assert_eq!(error.retryable(), retryable, "{reason}");
            assert_eq!(error.holder().pid, 4242);
        }
    }

    #[test]
    fn outcome_json_reports_release_and_signal() {
        assert_eq!(
            TakeoverOutcome::NoHolder.to_json(),
            serde_json::json!({ "released": false })
        );
        let released = TakeoverOutcome::Released {
            holders: vec![owner(7, Some(1))],
            signal: ProcessSignal::Terminate,
        };
        let json = released.to_json();
        assert_eq!(json["released"], serde_json::json!(true));
        assert_eq!(json["signal"], serde_json::json!("SIGTERM"));
        assert_eq!(json["holder"]["pid"], serde_json::json!(7));
    }

    #[cfg(unix)]
    #[test]
    fn verify_holder_rejects_missing_or_stale_start_time_and_self() {
        let me = std::process::id();
        let now_ms = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_millis(),
        )
        .expect("fits");
        assert!(
            matches!(
                verify_holder(&owner(me, Some(now_ms))),
                Err(TakeoverError::HolderUnverified(_))
            ),
            "绝不能给 bridge 自己发信号"
        );

        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sleep");
        let pid = child.id();
        assert!(verify_holder(&owner(pid, Some(now_ms))).is_ok());
        assert!(matches!(
            verify_holder(&owner(pid, None)),
            Err(TakeoverError::HolderUnverified(_))
        ));
        assert!(matches!(
            verify_holder(&owner(pid, Some(now_ms - 3_600_000))),
            Err(TakeoverError::HolderUnverified(_))
        ));
        child.kill().expect("kill sleep");
        child.wait().expect("reap sleep");
    }
}
