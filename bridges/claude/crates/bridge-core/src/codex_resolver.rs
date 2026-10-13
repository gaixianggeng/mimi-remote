use std::collections::HashSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::time::Duration;

use tokio::process::Command;

/// POSIX shell lines consumed by `POSIX_RESOLVE_CODEX_BINARY`.
pub const POSIX_SHELL_CANDIDATE_LINES: &[&str] = &[
    r#"_litter_consider_path_candidates codex codex"#,
    r#"_litter_consider_candidate codex "${CODEX_HOME:-$HOME/.codex}/packages/standalone/current/codex""#,
    r#"_litter_consider_candidate codex "${BUN_INSTALL:-$HOME/.bun}/bin/codex""#,
    r#"_litter_consider_candidate codex "$HOME/.volta/bin/codex""#,
    r#"_litter_consider_candidate codex "$HOME/.local/bin/codex""#,
    r#"_litter_consider_from_dir codex codex "${PNPM_HOME:-}""#,
    r#"_litter_consider_from_dir codex codex "${NVM_BIN:-}""#,
    r#"_litter_consider_from_dir codex codex "${VOLTA_HOME:+$VOLTA_HOME/bin}""#,
    r#"_litter_consider_from_dir codex codex "${CARGO_HOME:-$HOME/.cargo}/bin""#,
    r#"_litter_consider_candidate codex "$HOME/Applications/Codex.app/Contents/Resources/codex""#,
    r#"_litter_consider_candidate codex "/Applications/Codex.app/Contents/Resources/codex""#,
    r#"_litter_consider_candidate codex "/opt/homebrew/bin/codex""#,
    r#"_litter_consider_candidate codex "/usr/local/bin/codex""#,
    r#"_litter_consider_candidate codex "/usr/bin/codex""#,
];

pub const POSIX_RESOLVE_CODEX_BINARY: &str =
    include_str!("codex_resolver/posix_resolve_codex_binary.sh");
pub const POWERSHELL_RESOLVE_CODEX_BINARY: &str =
    include_str!("codex_resolver/powershell_resolve_codex_binary.ps1");

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct CodexCliVersion {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

pub fn shell_candidate_lines() -> &'static [&'static str] {
    POSIX_SHELL_CANDIDATE_LINES
}

pub fn resolve_latest_codex_binary(program: &Path) -> Option<PathBuf> {
    let candidates = program_candidates(program);
    if candidates.is_empty() {
        return None;
    }

    if let Some(path) = latest_versioned_codex_candidate(&candidates) {
        return Some(path);
    }

    candidates.into_iter().next()
}

pub fn program_candidates(program: &Path) -> Vec<PathBuf> {
    if program.is_absolute() || program.components().count() > 1 {
        return vec![program.to_path_buf()];
    }

    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    for path in path_program_candidates(program) {
        push_executable_candidate(&mut candidates, &mut seen, path);
    }
    if is_codex_program_name(program) {
        for path in common_codex_candidates() {
            push_executable_candidate(&mut candidates, &mut seen, path);
        }
    }
    candidates
}

pub async fn newest_codex_candidates_first(candidates: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut versioned = Vec::new();
    let mut unversioned = Vec::new();

    for candidate in candidates {
        match codex_cli_version_async(&candidate).await {
            Some(version) => versioned.push((version, candidate)),
            None => unversioned.push(candidate),
        }
    }

    versioned.sort_by(|(left, _), (right, _)| right.cmp(left));

    versioned
        .into_iter()
        .map(|(_, path)| path)
        .chain(unversioned)
        .collect()
}

pub fn parse_codex_cli_version(text: &str) -> Option<CodexCliVersion> {
    text.split_whitespace().find_map(|token| {
        let token = token
            .trim_start_matches('v')
            .trim_matches(|ch: char| matches!(ch, '(' | ')' | ',' | ';'));
        let mut parts = token.split('.');
        let major = parse_version_component(parts.next()?)?;
        let minor = parse_version_component(parts.next()?)?;
        let patch = parse_version_component(parts.next()?)?;
        Some(CodexCliVersion {
            major,
            minor,
            patch,
        })
    })
}

pub fn is_codex_program_name(program: &Path) -> bool {
    let Some(name) = program.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    matches!(
        name.to_ascii_lowercase().as_str(),
        "codex" | "codex.exe" | "codex.cmd" | "codex.bat" | "codex.com"
    )
}

fn latest_versioned_codex_candidate(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates
        .iter()
        .filter_map(|path| codex_cli_version_sync(path).map(|version| (version, path.clone())))
        .max_by(|(left, _), (right, _)| left.cmp(right))
        .map(|(_, path)| path)
}

fn codex_cli_version_sync(bin: &Path) -> Option<CodexCliVersion> {
    let output = StdCommand::new(bin)
        .arg("--version")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push('\n');
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    parse_codex_cli_version(&text)
}

async fn codex_cli_version_async(bin: &Path) -> Option<CodexCliVersion> {
    let output = tokio::time::timeout(
        Duration::from_secs(5),
        Command::new(bin)
            .arg("--version")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }

    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push('\n');
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    parse_codex_cli_version(&text)
}

fn parse_version_component(component: &str) -> Option<u64> {
    let digits = component
        .chars()
        .take_while(|ch| ch.is_ascii_digit())
        .collect::<String>();
    if digits.is_empty() {
        return None;
    }
    digits.parse().ok()
}

fn path_program_candidates(program: &Path) -> Vec<PathBuf> {
    let Some(path_var) = std::env::var_os("PATH") else {
        return Vec::new();
    };
    let names = program_file_names(program);
    std::env::split_paths(&path_var)
        .flat_map(|dir| names.iter().map(move |name| dir.join(name)))
        .collect()
}

#[cfg(windows)]
fn program_file_names(program: &Path) -> Vec<OsString> {
    if program.extension().is_some() {
        return vec![program.as_os_str().to_os_string()];
    }
    let name = program.as_os_str().to_string_lossy();
    let pathext = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
    pathext
        .split(';')
        .filter(|ext| !ext.is_empty())
        .map(|ext| OsString::from(format!("{name}{ext}")))
        .collect()
}

#[cfg(not(windows))]
fn program_file_names(program: &Path) -> Vec<OsString> {
    vec![program.as_os_str().to_os_string()]
}

fn common_codex_candidates() -> Vec<PathBuf> {
    let home = home_dir();
    let mut candidates = Vec::new();

    #[cfg(windows)]
    {
        if let Some(home) = home {
            let codex_home = std::env::var_os("CODEX_HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".codex"));
            candidates.push(codex_home.join("packages/standalone/current/codex.exe"));
            candidates.push(codex_home.join("packages/standalone/current/codex.cmd"));
            candidates.push(home.join("AppData/Roaming/npm/codex.cmd"));
            candidates.push(home.join(".cargo/bin/codex.exe"));
            candidates.push(home.join(".bun/bin/codex.exe"));
            candidates.push(home.join(".bun/bin/codex.cmd"));
            candidates.push(home.join(".volta/bin/codex.exe"));
            candidates.push(home.join(".volta/bin/codex.cmd"));
            candidates.push(home.join(".local/bin/codex.exe"));
        }
    }

    #[cfg(not(windows))]
    {
        if let Some(home) = home {
            let codex_home = std::env::var_os("CODEX_HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".codex"));
            candidates.push(codex_home.join("packages/standalone/current/codex"));
            candidates.push(home.join(".bun/bin/codex"));
            candidates.push(home.join(".volta/bin/codex"));
            candidates.push(home.join(".local/bin/codex"));
            candidates.push(home.join(".cargo/bin/codex"));
            push_env_dir_candidate(&mut candidates, "PNPM_HOME", "codex");
            push_env_dir_candidate(&mut candidates, "NVM_BIN", "codex");
            if let Some(volta_home) =
                std::env::var_os("VOLTA_HOME").filter(|value| !value.is_empty())
            {
                candidates.push(PathBuf::from(volta_home).join("bin/codex"));
            }
            if let Some(cargo_home) =
                std::env::var_os("CARGO_HOME").filter(|value| !value.is_empty())
            {
                candidates.push(PathBuf::from(cargo_home).join("bin/codex"));
            }
            #[cfg(target_os = "macos")]
            {
                candidates.push(home.join("Applications/Codex.app/Contents/Resources/codex"));
                candidates.push(PathBuf::from(
                    "/Applications/Codex.app/Contents/Resources/codex",
                ));
            }
        }
        candidates.push(PathBuf::from("/opt/homebrew/bin/codex"));
        candidates.push(PathBuf::from("/usr/local/bin/codex"));
        candidates.push(PathBuf::from("/usr/bin/codex"));
    }
    candidates
}

#[cfg(not(windows))]
fn push_env_dir_candidate(candidates: &mut Vec<PathBuf>, var: &str, name: &str) {
    if let Some(value) = std::env::var_os(var).filter(|value| !value.is_empty()) {
        candidates.push(PathBuf::from(value).join(name));
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn push_executable_candidate(
    candidates: &mut Vec<PathBuf>,
    seen: &mut HashSet<PathBuf>,
    path: PathBuf,
) {
    if is_executable_file(&path) && seen.insert(path.clone()) {
        candidates.push(path);
    }
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
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
    fn parses_codex_cli_version() {
        assert_eq!(
            parse_codex_cli_version("codex-cli 0.130.0"),
            Some(CodexCliVersion {
                major: 0,
                minor: 130,
                patch: 0,
            })
        );
        assert_eq!(
            parse_codex_cli_version("codex-cli v1.2.3-beta.1"),
            Some(CodexCliVersion {
                major: 1,
                minor: 2,
                patch: 3,
            })
        );
        assert_eq!(
            parse_codex_cli_version("codex-cli 0.130.0.dev-20260514"),
            Some(CodexCliVersion {
                major: 0,
                minor: 130,
                patch: 0,
            })
        );
        assert!(parse_codex_cli_version("codex-cli unknown").is_none());
    }

    #[test]
    fn codex_cli_version_orders_by_numeric_components() {
        assert!(
            (CodexCliVersion {
                major: 0,
                minor: 130,
                patch: 0,
            }) > (CodexCliVersion {
                major: 0,
                minor: 31,
                patch: 0,
            })
        );
    }

    #[test]
    fn recognizes_windows_codex_program_names() {
        assert!(is_codex_program_name(Path::new("codex")));
        assert!(is_codex_program_name(Path::new("codex.exe")));
        assert!(is_codex_program_name(Path::new("CODEX.CMD")));
        assert!(!is_codex_program_name(Path::new("pi")));
    }

    #[test]
    fn shell_candidate_lines_cover_common_posix_installs() {
        let shell = shell_candidate_lines().join("\n");
        assert!(shell.contains("_litter_consider_path_candidates codex codex"));
        assert!(shell.contains("packages/standalone/current/codex"));
        assert!(shell.contains("Codex.app/Contents/Resources/codex"));
        assert!(shell.contains(".local/bin/codex"));
        assert!(shell.contains("/opt/homebrew/bin/codex"));
        assert!(shell.contains("/usr/local/bin/codex"));
        assert!(shell.contains("/usr/bin/codex"));
    }

    #[test]
    fn powershell_resolver_prefers_latest_version() {
        assert!(POWERSHELL_RESOLVE_CODEX_BINARY.contains("Get-Command codex -All"));
        assert!(
            POWERSHELL_RESOLVE_CODEX_BINARY.contains("packages\\standalone\\current\\codex.exe")
        );
        assert!(POWERSHELL_RESOLVE_CODEX_BINARY.contains("AppData\\Roaming\\npm\\codex.cmd"));
        assert!(POWERSHELL_RESOLVE_CODEX_BINARY.contains(r"(\d+)\.(\d+)\.(\d+)"));
        assert!(POWERSHELL_RESOLVE_CODEX_BINARY.contains("$bestVersion"));
        assert!(POWERSHELL_RESOLVE_CODEX_BINARY.contains("CompareTo"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn newest_candidates_accept_dev_suffix_versions() {
        let temp = tempfile::tempdir().unwrap();
        let old_dir = temp.path().join("old");
        let new_dir = temp.path().join("new");
        std::fs::create_dir_all(&old_dir).unwrap();
        std::fs::create_dir_all(&new_dir).unwrap();
        let old = old_dir.join("codex");
        let new = new_dir.join("codex");
        write_fake_codex(&old, "codex-cli 0.31.0");
        write_fake_codex(&new, "codex-cli 0.130.0.dev-20260514");

        let sorted = newest_codex_candidates_first(vec![old.clone(), new.clone()]).await;
        assert_eq!(sorted, vec![new, old]);
    }

    #[cfg(unix)]
    #[test]
    fn posix_resolver_accepts_dev_suffix_versions() {
        use std::process::Command as StdCommand;

        let temp = tempfile::tempdir().unwrap();
        let old_dir = temp.path().join("old");
        let new_dir = temp.path().join("new");
        std::fs::create_dir_all(&old_dir).unwrap();
        std::fs::create_dir_all(&new_dir).unwrap();
        write_fake_codex(&old_dir.join("codex"), "codex-cli 0.31.0");
        write_fake_codex(&new_dir.join("codex"), "codex-cli 0.130.0.dev-20260514");

        let script = POSIX_RESOLVE_CODEX_BINARY
            .replace("{{PROFILE_INIT}}", "")
            .replace("{{PACKAGE_MANAGER_PROBE}}", "")
            .replace(
                "{{SHARED_LINES}}",
                "_litter_consider_path_candidates codex codex",
            );
        // 测试只保留 shell 脚本依赖的系统目录，避免开发机已安装的 Codex / ChatGPT
        // 被 PATH 扫描后以更高版本覆盖这里专门构造的候选项。
        let path_value = format!("{}:{}:/usr/bin:/bin", old_dir.display(), new_dir.display());
        let output = StdCommand::new("/bin/sh")
            .arg("-c")
            .arg(script)
            .env("PATH", path_value)
            .output()
            .unwrap();

        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            format!("codex:{}", new_dir.join("codex").display())
        );
    }

    #[cfg(unix)]
    fn write_fake_codex(path: &Path, version: &str) {
        crate::test_support::write_executable_script(
            path,
            &format!("#!/bin/sh\nprintf '%s\\n' '{version}'\n"),
        );
    }
}
