//! User launch environment resolution.
//!
//! Alleycat is often started by launchd/systemd, but users expect spawned
//! agents to behave as if they were launched from their normal terminal in the
//! target project. This module centralises that policy so every bridge-managed
//! process gets the same treatment instead of each agent growing bespoke shell
//! patches.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::future::BoxFuture;
use serde_json::Value;
use tokio::process::Command;
use tokio::sync::Mutex;
use tracing::debug;

use crate::launcher::{ChildProcess, ProcessLauncher, ProcessSpec};

type EnvMap = HashMap<OsString, OsString>;

const DEFAULT_PROVIDER_TIMEOUT: Duration = Duration::from_secs(8);
const DEFAULT_CACHE_TTL: Duration = Duration::from_secs(30);

/// Controls how Alleycat reconstructs the user's terminal-like environment for
/// child processes.
#[derive(Debug, Clone)]
pub struct LaunchEnvironmentPolicy {
    /// Capture the configured user shell (`$SHELL`) before agent launch. The
    /// shell is invoked as login+interactive where the shell supports it so
    /// zsh/bash/fish users get their normal rc-file-managed variables.
    pub load_user_shell: bool,
    /// Overlay `mise env --json -C <cwd>` when `mise` is available on PATH.
    pub load_mise: bool,
    /// Overlay `direnv export json` when `direnv` is available on PATH.
    pub load_direnv: bool,
    /// Maximum time to spend in any one shell/provider probe.
    pub provider_timeout: Duration,
    /// How long a resolved environment for a cwd can be reused.
    pub cache_ttl: Duration,
}

impl Default for LaunchEnvironmentPolicy {
    fn default() -> Self {
        Self {
            load_user_shell: true,
            load_mise: true,
            load_direnv: true,
            provider_timeout: DEFAULT_PROVIDER_TIMEOUT,
            cache_ttl: DEFAULT_CACHE_TTL,
        }
    }
}

/// Resolved environment variables for one launch cwd.
#[derive(Debug, Clone)]
pub struct LaunchEnvironment {
    vars: EnvMap,
}

impl LaunchEnvironment {
    pub fn current() -> Self {
        Self {
            vars: std::env::vars_os().collect(),
        }
    }

    pub fn get(&self, key: &str) -> Option<&OsStr> {
        self.vars.get(OsStr::new(key)).map(OsString::as_os_str)
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.vars.contains_key(OsStr::new(key))
    }

    pub fn find_on_path(&self, program: &str) -> Option<PathBuf> {
        find_on_path(program, &self.vars)
    }

    pub fn into_pairs(self) -> Vec<(OsString, OsString)> {
        self.vars.into_iter().collect()
    }
}

#[derive(Debug, Clone)]
pub struct LaunchEnvironmentResolver {
    policy: LaunchEnvironmentPolicy,
    cache: Arc<Mutex<HashMap<Option<PathBuf>, CacheEntry>>>,
}

impl Default for LaunchEnvironmentResolver {
    fn default() -> Self {
        Self::new(LaunchEnvironmentPolicy::default())
    }
}

impl LaunchEnvironmentResolver {
    pub fn new(policy: LaunchEnvironmentPolicy) -> Self {
        Self {
            policy,
            cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn resolve(&self, cwd: Option<&Path>) -> LaunchEnvironment {
        let cache_key = cwd.map(Path::to_path_buf);
        let now = Instant::now();
        {
            let cache = self.cache.lock().await;
            if let Some(entry) = cache.get(&cache_key)
                && now.duration_since(entry.cached_at) <= self.policy.cache_ttl
            {
                return entry.env.clone();
            }
        }

        let env = resolve_uncached(cwd, &self.policy).await;
        let mut cache = self.cache.lock().await;
        cache.insert(
            cache_key,
            CacheEntry {
                env: env.clone(),
                cached_at: now,
            },
        );
        env
    }
}

#[derive(Debug, Clone)]
struct CacheEntry {
    env: LaunchEnvironment,
    cached_at: Instant,
}

/// Process launcher wrapper that overlays the resolved user launch environment
/// before applying per-command `ProcessSpec::env` overrides.
#[derive(Clone)]
pub struct UserEnvironmentLauncher {
    inner: Arc<dyn ProcessLauncher>,
    resolver: LaunchEnvironmentResolver,
    program_aliases: Arc<HashMap<OsString, Vec<OsString>>>,
}

impl UserEnvironmentLauncher {
    pub fn new(inner: Arc<dyn ProcessLauncher>) -> Self {
        Self::with_policy(inner, LaunchEnvironmentPolicy::default())
    }

    pub fn with_policy(inner: Arc<dyn ProcessLauncher>, policy: LaunchEnvironmentPolicy) -> Self {
        Self::with_resolver(inner, LaunchEnvironmentResolver::new(policy))
    }

    pub fn with_resolver(
        inner: Arc<dyn ProcessLauncher>,
        resolver: LaunchEnvironmentResolver,
    ) -> Self {
        Self {
            inner,
            resolver,
            program_aliases: Arc::new(HashMap::new()),
        }
    }

    pub fn with_program_aliases(
        mut self,
        aliases: impl IntoIterator<Item = (OsString, Vec<OsString>)>,
    ) -> Self {
        self.program_aliases = Arc::new(aliases.into_iter().collect());
        self
    }

    pub fn resolver(&self) -> &LaunchEnvironmentResolver {
        &self.resolver
    }
}

impl ProcessLauncher for UserEnvironmentLauncher {
    fn launch(
        &self,
        mut spec: ProcessSpec,
    ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
        Box::pin(async move {
            let explicit_env = std::mem::take(&mut spec.env);
            let mut launch_env = self.resolver.resolve(spec.cwd.as_deref()).await;
            merge_env(
                &mut launch_env.vars,
                explicit_env.iter().cloned().collect::<EnvMap>(),
            );
            spec.program =
                resolve_program_for_launch(&spec.program, &launch_env, &self.program_aliases);
            spec.env = launch_env.into_pairs();
            spec.env_clear = true;
            self.inner.launch(spec).await
        })
    }
}

async fn resolve_uncached(
    cwd: Option<&Path>,
    policy: &LaunchEnvironmentPolicy,
) -> LaunchEnvironment {
    let mut env: EnvMap = std::env::vars_os().collect();

    if policy.load_user_shell {
        if let Some(shell) = detect_user_shell() {
            match capture_shell_env(&shell, cwd, &env, policy.provider_timeout).await {
                Ok(shell_env) => merge_env(&mut env, shell_env),
                Err(error) => debug!(
                    shell = %shell.display(),
                    error = %error,
                    "launch environment shell snapshot skipped"
                ),
            }
        }
    }

    if policy.load_mise {
        if let Err(error) = apply_mise_env(cwd, &mut env, policy.provider_timeout).await {
            debug!(error = %error, "launch environment mise provider skipped");
        }
    }

    if policy.load_direnv {
        if let Err(error) = apply_direnv(cwd, &mut env, policy.provider_timeout).await {
            debug!(error = %error, "launch environment direnv provider skipped");
        }
    }

    LaunchEnvironment { vars: env }
}

fn merge_env(target: &mut EnvMap, source: EnvMap) {
    for (key, value) in source {
        target.insert(key, value);
    }
}

fn resolve_program_for_launch(
    program: &Path,
    env: &LaunchEnvironment,
    aliases: &HashMap<OsString, Vec<OsString>>,
) -> PathBuf {
    if program.components().count() > 1 {
        return program.to_path_buf();
    }

    if let Some(name) = program.as_os_str().to_str()
        && let Some(path) = env.find_on_path(name)
    {
        return path;
    }

    if let Some(alias_names) = aliases.get(program.as_os_str()) {
        for alias in alias_names {
            if let Some(alias) = alias.to_str()
                && let Some(path) = env.find_on_path(alias)
            {
                return path;
            }
        }
    }

    program.to_path_buf()
}

fn detect_user_shell() -> Option<PathBuf> {
    if let Some(shell) = std::env::var_os("SHELL").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(shell));
    }

    #[cfg(target_os = "macos")]
    {
        for candidate in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            let path = PathBuf::from(candidate);
            if path.exists() {
                return Some(path);
            }
        }
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        for candidate in [
            "/bin/bash",
            "/usr/bin/bash",
            "/bin/zsh",
            "/usr/bin/zsh",
            "/usr/bin/fish",
            "/bin/fish",
            "/bin/sh",
        ] {
            let path = PathBuf::from(candidate);
            if path.exists() {
                return Some(path);
            }
        }
    }

    None
}

fn shell_env_args(shell: &Path) -> Vec<OsString> {
    let name = shell
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_ascii_lowercase();

    if name.contains("fish") {
        vec!["-l".into(), "-c".into(), "env".into()]
    } else if name.contains("zsh") || name.contains("bash") {
        vec!["-lic".into(), "env".into()]
    } else if matches!(name.as_str(), "sh" | "dash" | "ash" | "busybox") {
        vec!["-c".into(), "env".into()]
    } else {
        vec!["-lc".into(), "env".into()]
    }
}

async fn capture_shell_env(
    shell: &Path,
    cwd: Option<&Path>,
    env: &EnvMap,
    timeout: Duration,
) -> std::io::Result<EnvMap> {
    let mut command = Command::new(shell);
    command.args(shell_env_args(shell));
    configure_probe_command(&mut command, cwd, env);
    let output = run_probe(command, timeout).await?;
    Ok(parse_env_output(&output.stdout))
}

async fn apply_mise_env(
    cwd: Option<&Path>,
    env: &mut EnvMap,
    timeout: Duration,
) -> std::io::Result<()> {
    let Some(mise) = find_provider_on_path(
        "mise",
        env,
        &[
            ".local/bin/mise",
            ".local/share/mise/bin/mise",
            ".local/share/mise/shims/mise",
            "/opt/homebrew/bin/mise",
            "/usr/local/bin/mise",
            "/usr/bin/mise",
        ],
    ) else {
        return Ok(());
    };

    let mut command = Command::new(mise);
    command.arg("env").arg("--json");
    if let Some(cwd) = cwd {
        command.arg("-C").arg(cwd);
    }
    configure_probe_command(&mut command, cwd, env);
    let output = run_probe(command, timeout).await?;
    if output.status.success() {
        apply_json_env(&output.stdout, env);
    }
    Ok(())
}

async fn apply_direnv(
    cwd: Option<&Path>,
    env: &mut EnvMap,
    timeout: Duration,
) -> std::io::Result<()> {
    let Some(direnv) = find_provider_on_path(
        "direnv",
        env,
        &[
            ".local/bin/direnv",
            "/opt/homebrew/bin/direnv",
            "/usr/local/bin/direnv",
            "/usr/bin/direnv",
        ],
    ) else {
        return Ok(());
    };

    let mut command = Command::new(direnv);
    command.arg("export").arg("json");
    command.env("DIRENV_LOG_FORMAT", "");
    configure_probe_command(&mut command, cwd, env);
    let output = run_probe(command, timeout).await?;
    if output.status.success() {
        apply_json_env(&output.stdout, env);
    }
    Ok(())
}

fn configure_probe_command(command: &mut Command, cwd: Option<&Path>, env: &EnvMap) {
    if let Some(cwd) = cwd.filter(|path| path.is_dir()) {
        command.current_dir(cwd);
    }
    command.env_clear();
    for (key, value) in env {
        command.env(key, value);
    }
    command.stdin(std::process::Stdio::null());
    command.stderr(std::process::Stdio::null());
    command.kill_on_drop(true);
}

async fn run_probe(
    mut command: Command,
    timeout: Duration,
) -> std::io::Result<std::process::Output> {
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(result) => result,
        Err(_) => Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "launch environment provider timed out",
        )),
    }
}

fn parse_env_output(stdout: &[u8]) -> EnvMap {
    let mut out = EnvMap::new();
    for line in String::from_utf8_lossy(stdout).lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if is_valid_env_key(key) {
            out.insert(OsString::from(key), OsString::from(value));
        }
    }
    out
}

fn apply_json_env(stdout: &[u8], env: &mut EnvMap) {
    let Ok(value) = serde_json::from_slice::<Value>(stdout) else {
        return;
    };
    let Some(object) = value.as_object() else {
        return;
    };
    for (key, value) in object {
        if !is_valid_env_key(key) {
            continue;
        }
        match value {
            Value::String(raw) => {
                env.insert(OsString::from(key), OsString::from(raw));
            }
            Value::Null => {
                env.remove(OsStr::new(key));
            }
            _ => {}
        }
    }
}

fn is_valid_env_key(key: &str) -> bool {
    let mut chars = key.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if first != '_' && !first.is_ascii_alphabetic() {
        return false;
    }
    chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn find_provider_on_path(program: &str, env: &EnvMap, fallback_paths: &[&str]) -> Option<PathBuf> {
    find_on_path(program, env).or_else(|| {
        let home = env.get(OsStr::new("HOME")).map(PathBuf::from);
        fallback_paths.iter().find_map(|candidate| {
            let path = PathBuf::from(candidate);
            let path = if path.is_absolute() {
                path
            } else {
                home.as_ref()?.join(path)
            };
            is_executable_file(&path).then_some(path)
        })
    })
}

fn find_on_path(program: &str, env: &EnvMap) -> Option<PathBuf> {
    let path = env.get(OsStr::new("PATH"))?;
    for dir in std::env::split_paths(path) {
        let candidate = dir.join(program);
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
        #[cfg(windows)]
        {
            for ext in ["exe", "cmd", "bat"] {
                let candidate = dir.join(format!("{program}.{ext}"));
                if is_executable_file(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }
    None
}

fn is_executable_file(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }

    #[cfg(not(unix))]
    {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_args_cover_common_shells() {
        assert_eq!(
            shell_env_args(Path::new("/bin/zsh")),
            vec![OsString::from("-lic"), OsString::from("env")]
        );
        assert_eq!(
            shell_env_args(Path::new("/bin/bash")),
            vec![OsString::from("-lic"), OsString::from("env")]
        );
        assert_eq!(
            shell_env_args(Path::new("/usr/bin/fish")),
            vec![
                OsString::from("-l"),
                OsString::from("-c"),
                OsString::from("env")
            ]
        );
        assert_eq!(
            shell_env_args(Path::new("/bin/sh")),
            vec![OsString::from("-c"), OsString::from("env")]
        );
    }

    #[test]
    fn parses_only_valid_env_lines() {
        let parsed = parse_env_output(b"GOOD=value\nNOPE\n1BAD=x\nALSO_GOOD=a=b\n");
        assert_eq!(
            parsed.get(OsStr::new("GOOD")),
            Some(&OsString::from("value"))
        );
        assert_eq!(
            parsed.get(OsStr::new("ALSO_GOOD")),
            Some(&OsString::from("a=b"))
        );
        assert!(!parsed.contains_key(OsStr::new("1BAD")));
    }

    #[test]
    fn json_provider_sets_and_removes_values() {
        let mut env = EnvMap::new();
        env.insert(OsString::from("REMOVE_ME"), OsString::from("old"));
        apply_json_env(
            br#"{"SET_ME":"new","REMOVE_ME":null,"NESTED":{"ignored":true}}"#,
            &mut env,
        );
        assert_eq!(env.get(OsStr::new("SET_ME")), Some(&OsString::from("new")));
        assert!(!env.contains_key(OsStr::new("REMOVE_ME")));
        assert!(!env.contains_key(OsStr::new("NESTED")));
    }

    #[cfg(unix)]
    #[test]
    fn find_on_path_skips_non_executable_files() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().expect("tempdir");
        let first = temp.path().join("first");
        let second = temp.path().join("second");
        std::fs::create_dir_all(&first).expect("first dir");
        std::fs::create_dir_all(&second).expect("second dir");

        let shadow = first.join("agent");
        std::fs::write(&shadow, "not executable").expect("write shadow");
        let mut shadow_perms = std::fs::metadata(&shadow)
            .expect("shadow metadata")
            .permissions();
        shadow_perms.set_mode(0o644);
        std::fs::set_permissions(&shadow, shadow_perms).expect("chmod shadow");

        let executable = second.join("agent");
        std::fs::write(&executable, "#!/bin/sh\n").expect("write executable");
        let mut executable_perms = std::fs::metadata(&executable)
            .expect("executable metadata")
            .permissions();
        executable_perms.set_mode(0o755);
        std::fs::set_permissions(&executable, executable_perms).expect("chmod executable");

        let path = std::env::join_paths([first.as_path(), second.as_path()]).expect("join path");
        let mut env = EnvMap::new();
        env.insert(OsString::from("PATH"), path);

        assert_eq!(
            find_on_path("agent", &env).as_deref(),
            Some(executable.as_path())
        );
    }

    #[cfg(unix)]
    #[test]
    fn find_provider_on_path_uses_home_relative_fallback() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().expect("tempdir");
        let empty_path = temp.path().join("empty-path");
        std::fs::create_dir_all(&empty_path).expect("empty path");
        let local_bin = temp.path().join(".local/bin");
        std::fs::create_dir_all(&local_bin).expect("local bin");
        let provider = local_bin.join("mise");
        std::fs::write(&provider, "#!/bin/sh\n").expect("write provider");
        let mut perms = std::fs::metadata(&provider)
            .expect("metadata")
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&provider, perms).expect("chmod");

        let mut env = EnvMap::new();
        env.insert(
            OsString::from("PATH"),
            empty_path.as_os_str().to_os_string(),
        );
        env.insert(
            OsString::from("HOME"),
            temp.path().as_os_str().to_os_string(),
        );

        assert_eq!(
            find_provider_on_path("mise", &env, &[".local/bin/mise"]).as_deref(),
            Some(provider.as_path())
        );
    }

    #[tokio::test]
    async fn user_environment_launcher_requests_clean_env() {
        use std::sync::{Arc, Mutex};

        #[derive(Clone)]
        struct CapturingLauncher {
            captured: Arc<Mutex<Option<ProcessSpec>>>,
        }

        impl ProcessLauncher for CapturingLauncher {
            fn launch(
                &self,
                spec: ProcessSpec,
            ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
                let captured = Arc::clone(&self.captured);
                Box::pin(async move {
                    *captured.lock().expect("capture lock") = Some(spec);
                    Err(std::io::Error::other("captured"))
                })
            }
        }

        let captured = Arc::new(Mutex::new(None));
        let policy = LaunchEnvironmentPolicy {
            load_user_shell: false,
            load_mise: false,
            load_direnv: false,
            ..LaunchEnvironmentPolicy::default()
        };
        let base: Arc<dyn ProcessLauncher> = Arc::new(CapturingLauncher {
            captured: Arc::clone(&captured),
        });
        let launcher = UserEnvironmentLauncher::with_policy(base, policy);
        let mut spec = ProcessSpec::new("agent");
        spec.env = vec![("EXPLICIT_ENV".into(), "wins".into())];

        let _ = launcher.launch(spec).await;

        let captured = captured
            .lock()
            .expect("capture lock")
            .take()
            .expect("captured spec");
        assert!(captured.env_clear);
        assert!(
            captured
                .env
                .iter()
                .any(|(key, value)| key == "EXPLICIT_ENV" && value == "wins")
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn launcher_resolves_program_after_explicit_path_and_aliases() {
        use std::os::unix::fs::PermissionsExt;
        use std::sync::{Arc, Mutex};

        #[derive(Clone)]
        struct CapturingLauncher {
            captured: Arc<Mutex<Option<ProcessSpec>>>,
        }

        impl ProcessLauncher for CapturingLauncher {
            fn launch(
                &self,
                spec: ProcessSpec,
            ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
                let captured = Arc::clone(&self.captured);
                Box::pin(async move {
                    *captured.lock().expect("capture lock") = Some(spec);
                    Err(std::io::Error::other("captured"))
                })
            }
        }

        let temp = tempfile::tempdir().expect("tempdir");
        let bin = temp.path().join("pi-coding-agent");
        std::fs::write(&bin, "#!/bin/sh\n").expect("write bin");
        let mut perms = std::fs::metadata(&bin).expect("metadata").permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&bin, perms).expect("chmod");

        let captured = Arc::new(Mutex::new(None));
        let policy = LaunchEnvironmentPolicy {
            load_user_shell: false,
            load_mise: false,
            load_direnv: false,
            ..LaunchEnvironmentPolicy::default()
        };
        let base: Arc<dyn ProcessLauncher> = Arc::new(CapturingLauncher {
            captured: Arc::clone(&captured),
        });
        let launcher = UserEnvironmentLauncher::with_policy(base, policy).with_program_aliases([(
            OsString::from("pi"),
            vec![OsString::from("pi-coding-agent")],
        )]);
        let mut spec = ProcessSpec::new("pi");
        spec.env = vec![("PATH".into(), temp.path().as_os_str().to_os_string())];

        let _ = launcher.launch(spec).await;

        let captured = captured
            .lock()
            .expect("capture lock")
            .take()
            .expect("captured spec");
        assert_eq!(captured.program, bin);
        assert!(captured.env_clear);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn launcher_applies_explicit_env_last() {
        use std::sync::Arc;

        use crate::launcher::{LocalLauncher, StdioMode};
        use tokio::io::AsyncReadExt;

        let policy = LaunchEnvironmentPolicy {
            load_user_shell: false,
            load_mise: false,
            load_direnv: false,
            ..LaunchEnvironmentPolicy::default()
        };
        let base: Arc<dyn ProcessLauncher> = Arc::new(LocalLauncher);
        let launcher = UserEnvironmentLauncher::with_policy(base, policy);
        let mut spec = ProcessSpec::new("/bin/sh");
        spec.args = vec!["-c".into(), "printf %s \"$ALLEY_TEST_ENV\"".into()];
        spec.env = vec![("ALLEY_TEST_ENV".into(), "explicit".into())];
        spec.stdout = StdioMode::Piped;

        let mut child = launcher.launch(spec).await.expect("launch");
        let mut stdout = child.take_stdout().expect("stdout");
        let mut output = String::new();
        stdout
            .read_to_string(&mut output)
            .await
            .expect("read stdout");
        let status = child.wait().await.expect("wait");

        assert!(status.success());
        assert_eq!(output, "explicit");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn mise_provider_is_project_aware_when_available() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().expect("tempdir");
        let bin = temp.path().join("mise");
        std::fs::write(
            &bin,
            "#!/bin/sh\nprintf '{\"FROM_MISE\":\"%s\"}' \"$PWD\"\n",
        )
        .expect("write mise");
        let mut perms = std::fs::metadata(&bin).expect("metadata").permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&bin, perms).expect("chmod");

        let project = temp.path().join("project");
        std::fs::create_dir(&project).expect("project dir");
        let mut env = EnvMap::new();
        env.insert(
            OsString::from("PATH"),
            temp.path().as_os_str().to_os_string(),
        );

        apply_mise_env(Some(&project), &mut env, Duration::from_secs(2))
            .await
            .expect("mise provider");

        let actual = env
            .get(OsStr::new("FROM_MISE"))
            .map(PathBuf::from)
            .and_then(|path| path.canonicalize().ok());
        let expected = project.canonicalize().expect("canonical project");
        assert_eq!(actual.as_deref(), Some(expected.as_path()));
    }
}
