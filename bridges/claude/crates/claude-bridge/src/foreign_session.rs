//! 探测本机其他 Claude 进程（终端 `claude`、Claude 桌面内置 Claude Code）是否
//! 正持有某个会话。
//!
//! Claude Code 自己会在 `~/.claude/sessions/<pid>.json` 登记每个活进程：
//! `{"pid", "sessionId", "cwd", "entrypoint", "kind", "status", ...}`，进程退出时
//! 删除；`claude --bg --resume` 也是靠它判断 "session is already running"。
//! `-p` 模式不做这个检查，所以由 bridge 在起进程前查一次。
//!
//! 同一个 session 同时有两个活进程时，transcript 会从同一个 leaf 分叉成两条
//! parentUuid 链；第二个进程还会把第一个进程正在进行的工作（含后台任务的合成
//! `task-notification`）再做一遍。bridge 发现别处持有时不 spawn，把会话标成
//! 只读并附上持有方摘要，等持有方退出后同 id 续聊。
//!
//! 只读取登记目录，不写 `~/.claude`；`CLAUDE_SESSIONS_DIR` 供测试覆盖，
//! `CLAUDE_BRIDGE_FOREIGN_SESSION_POLICY=legacy` 关闭整个探测（kill switch）。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

/// 别处持有会话时 bridge 的处理策略。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ForeignSessionPolicy {
    /// 默认：不起第二个进程，会话只读并附持有方摘要。
    #[default]
    Guard,
    /// 关闭探测，回到旧行为（同 id 再起一个 `claude -p --resume`）。
    Legacy,
}

impl ForeignSessionPolicy {
    pub const ENV_KEY: &'static str = "CLAUDE_BRIDGE_FOREIGN_SESSION_POLICY";

    pub fn from_env() -> Self {
        match std::env::var(Self::ENV_KEY) {
            Ok(value) => Self::parse(&value),
            Err(_) => Self::Guard,
        }
    }

    pub fn parse(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "legacy" | "off" | "0" | "false" | "no" => Self::Legacy,
            _ => Self::Guard,
        }
    }
}

/// `~/.claude/sessions/<pid>.json` 中 bridge 关心的字段。未知字段忽略。
#[derive(Debug, Clone, Deserialize)]
struct SessionRegistryRecord {
    pid: u32,
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(default)]
    entrypoint: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    version: Option<String>,
    /// CLI 自身启动时刻（Unix 毫秒），与内核记录的进程启动时间只差约 2 秒；
    /// `thread/takeover` 用它确认 pid 没有被别的进程复用。
    #[serde(rename = "startedAt", default)]
    started_at_ms: Option<u64>,
}

/// 正持有某个会话的本机 Claude 进程摘要。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignSessionOwner {
    pub pid: u32,
    pub entrypoint: Option<String>,
    pub kind: Option<String>,
    pub status: Option<String>,
    pub version: Option<String>,
    pub started_at_ms: Option<u64>,
}

/// `thread/takeover` 会发给持有方的信号。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessSignal {
    Interrupt,
    Terminate,
}

impl ProcessSignal {
    pub fn as_str(self) -> &'static str {
        match self {
            ProcessSignal::Interrupt => "SIGINT",
            ProcessSignal::Terminate => "SIGTERM",
        }
    }
}

impl ForeignSessionOwner {
    /// Claude 把 `status` 写成 `busy` / `shell` 等；`-p` 进程不写，视为未知。
    pub fn is_busy(&self) -> bool {
        matches!(self.status.as_deref(), Some("busy") | Some("shell"))
    }

    /// 回给客户端的摘要。故意不带 cwd / name：客户端只需要知道谁在持有、
    /// 是否在执行，不需要再收一份可能含私有路径的字段。
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "pid": self.pid,
            "entrypoint": self.entrypoint,
            "kind": self.kind,
            "status": self.status,
            "version": self.version,
        })
    }
}

/// `~/.claude/sessions`。`CLAUDE_SESSIONS_DIR` 供测试覆盖。
pub fn claude_sessions_dir() -> Option<PathBuf> {
    if let Ok(env_dir) = std::env::var("CLAUDE_SESSIONS_DIR")
        && !env_dir.trim().is_empty()
    {
        return Some(PathBuf::from(env_dir));
    }
    let home = directories::UserDirs::new()?.home_dir().to_path_buf();
    Some(home.join(".claude").join("sessions"))
}

#[derive(Debug)]
pub struct ForeignSessionRegistry {
    dir: Option<PathBuf>,
    policy: ForeignSessionPolicy,
}

impl ForeignSessionRegistry {
    pub fn from_env() -> Self {
        Self {
            dir: claude_sessions_dir(),
            policy: ForeignSessionPolicy::from_env(),
        }
    }

    pub fn with_dir(dir: PathBuf, policy: ForeignSessionPolicy) -> Self {
        Self {
            dir: Some(dir),
            policy,
        }
    }

    pub fn disabled() -> Self {
        Self {
            dir: None,
            policy: ForeignSessionPolicy::Legacy,
        }
    }

    pub fn policy(&self) -> ForeignSessionPolicy {
        self.policy
    }

    pub fn is_enabled(&self) -> bool {
        self.policy == ForeignSessionPolicy::Guard && self.dir.is_some()
    }

    /// 扫一遍登记目录，返回 sessionId → 活着且不属于本 bridge 的持有方。
    /// 目录不存在、单个文件损坏都按"无持有方"处理：探测失败不能变成拒绝服务。
    pub async fn owners(&self, own_pids: &HashSet<u32>) -> HashMap<String, ForeignSessionOwner> {
        let mut out = HashMap::new();
        if !self.is_enabled() {
            return out;
        }
        let Some(dir) = self.dir.as_deref() else {
            return out;
        };
        let mut read_dir = match tokio::fs::read_dir(dir).await {
            Ok(read_dir) => read_dir,
            Err(_) => return out,
        };
        while let Ok(Some(entry)) = read_dir.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let Some(record) = read_record(&path).await else {
                continue;
            };
            // bridge 自己的 `claude -p` 子进程同样会登记；那是我们持有的，不算别处。
            // 非正常退出可能留下残余文件，所以必须再核对 pid 是否活着。
            if own_pids.contains(&record.pid) || !pid_is_alive(record.pid) {
                continue;
            }
            let owner = owner_from_record(&record);
            // 同一个 session 有多个活进程时保留正在执行的那个，客户端提示更准确。
            match out.get(&record.session_id) {
                Some(existing) if existing.is_busy() && !owner.is_busy() => {}
                _ => {
                    out.insert(record.session_id, owner);
                }
            }
        }
        out
    }

    pub async fn owner_of(
        &self,
        session_id: &str,
        own_pids: &HashSet<u32>,
    ) -> Option<ForeignSessionOwner> {
        if !self.is_enabled() {
            return None;
        }
        self.owners(own_pids).await.remove(session_id)
    }

    /// 某个 session 的全部活着的别处持有方，不去重：`thread/takeover` 必须把每一个
    /// 都结束，只结束"正在执行的那个"会留下另一个继续分叉。
    pub async fn holders_of(
        &self,
        session_id: &str,
        own_pids: &HashSet<u32>,
    ) -> Vec<ForeignSessionOwner> {
        let mut holders = Vec::new();
        if !self.is_enabled() {
            return holders;
        }
        let Some(dir) = self.dir.as_deref() else {
            return holders;
        };
        let mut read_dir = match tokio::fs::read_dir(dir).await {
            Ok(read_dir) => read_dir,
            Err(_) => return holders,
        };
        while let Ok(Some(entry)) = read_dir.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let Some(record) = read_record(&path).await else {
                continue;
            };
            if record.session_id != session_id
                || own_pids.contains(&record.pid)
                || !pid_is_alive(record.pid)
                || holders
                    .iter()
                    .any(|holder: &ForeignSessionOwner| holder.pid == record.pid)
            {
                continue;
            }
            holders.push(owner_from_record(&record));
        }
        holders
    }
}

fn owner_from_record(record: &SessionRegistryRecord) -> ForeignSessionOwner {
    ForeignSessionOwner {
        pid: record.pid,
        entrypoint: record.entrypoint.clone(),
        kind: record.kind.clone(),
        status: record.status.clone(),
        version: record.version.clone(),
        started_at_ms: record.started_at_ms,
    }
}

async fn read_record(path: &Path) -> Option<SessionRegistryRecord> {
    // 登记文件只有几百字节；上限只是防止误读到别的大文件。
    let metadata = tokio::fs::metadata(path).await.ok()?;
    if metadata.len() > 64 * 1024 {
        return None;
    }
    let text = tokio::fs::read_to_string(path).await.ok()?;
    serde_json::from_str(&text).ok()
}

#[cfg(unix)]
pub(crate) fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    // kill(pid, 0) 不发送信号，只检查进程是否存在；EPERM 说明存在但属于别的用户。
    // SAFETY: kill 只接收整数参数，不涉及内存所有权。
    let rc = unsafe { libc::kill(pid, 0) };
    if rc == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
pub(crate) fn pid_is_alive(_pid: u32) -> bool {
    // Windows 上暂不探测活进程；宁可保持旧行为，也不把残余登记误判成持有方。
    false
}

/// 给单个进程发信号。pid 0 / 1 / 负数会打到整个进程组或 init，这里一律拒绝；
/// 进程已经不在（ESRCH）视为送达，调用方靠存活轮询判断结果。
#[cfg(unix)]
pub(crate) fn signal_pid(pid: u32, signal: ProcessSignal) -> std::io::Result<()> {
    if pid <= 1 {
        return Err(std::io::Error::other(format!(
            "refusing to signal pid {pid}"
        )));
    }
    let pid = i32::try_from(pid).map_err(std::io::Error::other)?;
    let signal = match signal {
        ProcessSignal::Interrupt => libc::SIGINT,
        ProcessSignal::Terminate => libc::SIGTERM,
    };
    // SAFETY: kill 只接收整数参数，不涉及内存所有权。
    let rc = unsafe { libc::kill(pid, signal) };
    if rc == 0 {
        return Ok(());
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(libc::ESRCH) {
        return Ok(());
    }
    Err(err)
}

#[cfg(not(unix))]
pub(crate) fn signal_pid(_pid: u32, _signal: ProcessSignal) -> std::io::Result<()> {
    Err(std::io::Error::other(
        "signalling foreign claude processes is not supported on this platform",
    ))
}

/// 内核记录的进程启动时刻（Unix 秒）。拿不到就返回 None，调用方按"无法核实"拒绝。
#[cfg(target_os = "macos")]
pub(crate) fn process_start_epoch_secs(pid: u32) -> Option<u64> {
    let pid = i32::try_from(pid).ok()?;
    // SAFETY: proc_bsdinfo 是 plain-old-data，全零是合法初值。
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = i32::try_from(std::mem::size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: 缓冲区与声明的大小一致，proc_pidinfo 只写入该缓冲区。
    let written = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast::<libc::c_void>(),
            size,
        )
    };
    if written != size {
        return None;
    }
    Some(info.pbi_start_tvsec)
}

#[cfg(target_os = "linux")]
pub(crate) fn process_start_epoch_secs(pid: u32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // comm 可能含空格和括号，从最后一个 ')' 之后再切；starttime 是第 22 个字段，
    // 即 ')' 之后的第 20 个，单位是时钟滴答。
    let rest = &stat[stat.rfind(')')? + 1..];
    let start_ticks: u64 = rest.split_whitespace().nth(19)?.parse().ok()?;
    let btime: u64 = std::fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("btime "))?
        .trim()
        .parse()
        .ok()?;
    // SAFETY: sysconf 只读取系统常量。
    let ticks_per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let ticks_per_sec = u64::try_from(ticks_per_sec)
        .ok()
        .filter(|ticks| *ticks > 0)?;
    Some(btime + start_ticks / ticks_per_sec)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn process_start_epoch_secs(_pid: u32) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_record(dir: &Path, name: &str, body: &str) {
        std::fs::write(dir.join(name), body).expect("write registry record");
    }

    /// 已退出的子进程 pid：`true` 立即返回，wait 之后这个 pid 一定不再存活。
    fn dead_pid() -> u32 {
        let mut child = std::process::Command::new("true")
            .spawn()
            .expect("spawn true");
        let pid = child.id();
        child.wait().expect("wait true");
        pid
    }

    #[test]
    fn policy_parses_kill_switch_values() {
        assert_eq!(
            ForeignSessionPolicy::parse("legacy"),
            ForeignSessionPolicy::Legacy
        );
        assert_eq!(
            ForeignSessionPolicy::parse(" OFF "),
            ForeignSessionPolicy::Legacy
        );
        assert_eq!(
            ForeignSessionPolicy::parse("guard"),
            ForeignSessionPolicy::Guard
        );
        assert_eq!(ForeignSessionPolicy::parse(""), ForeignSessionPolicy::Guard);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn owners_keep_live_foreign_processes_and_drop_own_or_dead_pids() {
        let dir = tempfile::tempdir().expect("tempdir");
        let live = std::process::id();
        let dead = dead_pid();
        write_record(
            dir.path(),
            &format!("{live}.json"),
            &format!(
                r#"{{"pid":{live},"sessionId":"session-live","cwd":"/tmp/a","entrypoint":"cli","kind":"interactive","status":"busy","version":"2.1.269","messagingSocketPath":"/tmp/x.sock"}}"#
            ),
        );
        write_record(
            dir.path(),
            &format!("{dead}.json"),
            &format!(r#"{{"pid":{dead},"sessionId":"session-dead","entrypoint":"cli"}}"#),
        );
        write_record(dir.path(), "broken.json", "{not json");
        write_record(dir.path(), &format!("{live}.abc.key"), "not a record");

        let registry =
            ForeignSessionRegistry::with_dir(dir.path().to_path_buf(), ForeignSessionPolicy::Guard);
        let owners = registry.owners(&HashSet::new()).await;
        assert_eq!(owners.len(), 1, "{owners:?}");
        let owner = owners.get("session-live").expect("live owner");
        assert_eq!(owner.pid, live);
        assert_eq!(owner.entrypoint.as_deref(), Some("cli"));
        assert!(owner.is_busy());
        assert_eq!(owner.to_json().get("cwd"), None, "摘要不得带 cwd");

        let own = HashSet::from([live]);
        assert!(
            registry.owner_of("session-live", &own).await.is_none(),
            "bridge 自己的子进程不算别处持有"
        );
        assert!(
            registry
                .owner_of("session-dead", &HashSet::new())
                .await
                .is_none()
        );
    }

    #[tokio::test]
    async fn legacy_policy_and_missing_dir_report_no_owners() {
        let dir = tempfile::tempdir().expect("tempdir");
        let live = std::process::id();
        write_record(
            dir.path(),
            &format!("{live}.json"),
            &format!(r#"{{"pid":{live},"sessionId":"session-live"}}"#),
        );
        let legacy = ForeignSessionRegistry::with_dir(
            dir.path().to_path_buf(),
            ForeignSessionPolicy::Legacy,
        );
        assert!(!legacy.is_enabled());
        assert!(
            legacy
                .owner_of("session-live", &HashSet::new())
                .await
                .is_none()
        );

        let missing = ForeignSessionRegistry::with_dir(
            dir.path().join("does-not-exist"),
            ForeignSessionPolicy::Guard,
        );
        assert!(missing.owners(&HashSet::new()).await.is_empty());
        assert!(
            ForeignSessionRegistry::disabled()
                .owners(&HashSet::new())
                .await
                .is_empty()
        );
    }
}
