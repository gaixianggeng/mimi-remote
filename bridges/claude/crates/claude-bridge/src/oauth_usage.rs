//! Claude OAuth usage 查询。
//!
//! Claude Code 的 headless `stream-json` 不会主动执行 `/usage`，但已登录账号的
//! OAuth 凭据可以访问 Claude Code 自己使用的 usage endpoint。这里仅在客户端
//! 明确请求 `account/rateLimits/read` 时查询，并保留原有 `rate_limit_event` 降级，
//! 不把凭据写入参数、日志或磁盘缓存。

use std::path::Path;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use alleycat_codex_proto as p;
use chrono::DateTime;
use serde::Deserialize;
use serde_json::Value;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::time::timeout;

const USAGE_ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const OAUTH_BETA_HEADER: &str = "oauth-2025-04-20";
#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const COMMAND_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Debug, thiserror::Error)]
pub(crate) enum OAuthUsageError {
    #[error("Claude OAuth 凭据不可用")]
    CredentialsUnavailable,
    #[error("Claude OAuth 凭据缺少 user:profile scope")]
    MissingProfileScope,
    #[error("Claude OAuth 凭据已过期")]
    CredentialsExpired,
    #[error("读取 Claude OAuth 凭据失败")]
    CredentialReadFailed,
    #[error("Claude OAuth usage 查询工具不可用")]
    QueryToolUnavailable,
    #[error("Claude OAuth usage 查询超时")]
    QueryTimedOut,
    #[error("Claude OAuth usage 查询失败")]
    QueryFailed,
    #[error("Claude OAuth usage 返回 HTTP {0}")]
    HTTPStatus(u16),
    #[error("Claude OAuth usage 返回格式无效")]
    InvalidResponse,
}

#[derive(Debug, Clone)]
struct OAuthCredentials {
    access_token: String,
    scopes: Vec<String>,
    expires_at_ms: Option<f64>,
    subscription_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CredentialRoot {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: Option<CredentialPayload>,
}

#[derive(Debug, Deserialize)]
struct CredentialPayload {
    #[serde(default, rename = "accessToken")]
    access_token: Option<String>,
    #[serde(default)]
    scopes: Vec<String>,
    #[serde(default, rename = "expiresAt")]
    expires_at_ms: Option<f64>,
    #[serde(default, rename = "subscriptionType")]
    subscription_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OAuthUsageResponse {
    #[serde(default)]
    five_hour: Option<OAuthUsageWindow>,
    #[serde(default)]
    seven_day: Option<OAuthUsageWindow>,
    #[serde(default)]
    seven_day_sonnet: Option<OAuthUsageWindow>,
    #[serde(default)]
    seven_day_opus: Option<OAuthUsageWindow>,
}

#[derive(Debug, Deserialize)]
struct OAuthUsageWindow {
    #[serde(default)]
    utilization: Option<f64>,
    #[serde(default)]
    resets_at: Option<String>,
}

pub(crate) async fn fetch_rate_limit_snapshot(
    _claude_bin: &Path,
) -> Result<p::RateLimitSnapshot, OAuthUsageError> {
    let mut credentials = load_credentials().await?;
    validate_credentials(&credentials)?;

    let response = match query_usage(&credentials.access_token).await {
        Err(OAuthUsageError::HTTPStatus(401)) => {
            // macOS 上 Keychain 才是 Claude Code 的凭据事实来源。401 后先检查
            // Keychain，避免旧凭据文件遮住其他 Claude 进程刚完成的轮换；其他
            // 平台或 Keychain 未变化时再检查文件。整个过程只读且只执行一轮。
            let Some(latest) = reload_credentials_after_unauthorized(&credentials).await? else {
                return Err(OAuthUsageError::HTTPStatus(401));
            };
            credentials = latest;
            query_usage(&credentials.access_token).await?
        }
        result => result?,
    };
    snapshot_from_response(response, credentials.subscription_type)
}

fn credentials_changed(previous: &OAuthCredentials, latest: &OAuthCredentials) -> bool {
    previous.access_token != latest.access_token
        || latest.expires_at_ms.unwrap_or_default() > previous.expires_at_ms.unwrap_or_default()
}

fn can_retry_with_reloaded_credentials(
    previous: &OAuthCredentials,
    latest: &OAuthCredentials,
) -> bool {
    credentials_changed(previous, latest) && validate_credentials(latest).is_ok()
}

async fn reload_credentials_after_unauthorized(
    previous: &OAuthCredentials,
) -> Result<Option<OAuthCredentials>, OAuthUsageError> {
    let keychain = read_keychain_credentials().await?;
    if let Some(latest) = select_reloaded_credentials(previous, keychain, None) {
        return Ok(Some(latest));
    }
    let file = read_credentials_file().await?;
    Ok(select_reloaded_credentials(previous, None, file))
}

fn select_reloaded_credentials(
    previous: &OAuthCredentials,
    keychain: Option<OAuthCredentials>,
    file: Option<OAuthCredentials>,
) -> Option<OAuthCredentials> {
    keychain
        .into_iter()
        .chain(file)
        .find(|latest| can_retry_with_reloaded_credentials(previous, latest))
}

async fn load_credentials() -> Result<OAuthCredentials, OAuthUsageError> {
    if let Some(credentials) = read_credentials_file().await? {
        return Ok(credentials);
    }
    if let Some(credentials) = read_keychain_credentials().await? {
        return Ok(credentials);
    }
    Err(OAuthUsageError::CredentialsUnavailable)
}

async fn read_credentials_file() -> Result<Option<OAuthCredentials>, OAuthUsageError> {
    let Some(home) = std::env::var_os("HOME").filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let path = PathBuf::from(home).join(".claude/.credentials.json");
    let data = match tokio::fs::read(&path).await {
        Ok(data) => data,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(OAuthUsageError::CredentialReadFailed),
    };

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata = tokio::fs::metadata(&path)
            .await
            .map_err(|_| OAuthUsageError::CredentialReadFailed)?;
        // 凭据文件若对组或其他用户可读，宁可不用，也不扩大既有安全问题。
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(OAuthUsageError::CredentialReadFailed);
        }
    }

    parse_credentials(&data)
}

#[cfg(target_os = "macos")]
async fn read_keychain_credentials() -> Result<Option<OAuthCredentials>, OAuthUsageError> {
    let mut command = Command::new("/usr/bin/security");
    command
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let child = command
        .spawn()
        .map_err(|_| OAuthUsageError::CredentialReadFailed)?;
    let output = timeout(Duration::from_secs(4), child.wait_with_output())
        .await
        .map_err(|_| OAuthUsageError::QueryTimedOut)?
        .map_err(|_| OAuthUsageError::CredentialReadFailed)?;
    if !output.status.success() {
        return Ok(None);
    }
    parse_credentials(&output.stdout)
}

#[cfg(not(target_os = "macos"))]
async fn read_keychain_credentials() -> Result<Option<OAuthCredentials>, OAuthUsageError> {
    Ok(None)
}

fn parse_credentials(data: &[u8]) -> Result<Option<OAuthCredentials>, OAuthUsageError> {
    let root: CredentialRoot =
        serde_json::from_slice(data).map_err(|_| OAuthUsageError::CredentialReadFailed)?;
    let Some(payload) = root.claude_ai_oauth else {
        return Ok(None);
    };
    let access_token = payload.access_token.unwrap_or_default().trim().to_string();
    if access_token.is_empty() {
        return Ok(None);
    }
    Ok(Some(OAuthCredentials {
        access_token,
        scopes: payload.scopes,
        expires_at_ms: payload.expires_at_ms,
        subscription_type: payload.subscription_type,
    }))
}

fn validate_credentials(credentials: &OAuthCredentials) -> Result<(), OAuthUsageError> {
    if !credentials
        .scopes
        .iter()
        .any(|scope| scope == "user:profile")
    {
        return Err(OAuthUsageError::MissingProfileScope);
    }
    if let Some(expires_at_ms) = credentials.expires_at_ms.filter(|value| *value > 0.0) {
        let now_ms = chrono::Utc::now().timestamp_millis() as f64;
        if expires_at_ms <= now_ms + 30_000.0 {
            return Err(OAuthUsageError::CredentialsExpired);
        }
    }
    if !safe_header_token(&credentials.access_token) {
        return Err(OAuthUsageError::CredentialReadFailed);
    }
    Ok(())
}

fn safe_header_token(token: &str) -> bool {
    !token.is_empty()
        && token
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && byte != b'"' && byte != b'\\')
}

async fn query_usage(access_token: &str) -> Result<OAuthUsageResponse, OAuthUsageError> {
    let curl = if tokio::fs::try_exists("/usr/bin/curl")
        .await
        .unwrap_or(false)
    {
        "/usr/bin/curl"
    } else {
        "curl"
    };
    let beta_header = format!("anthropic-beta: {OAUTH_BETA_HEADER}");
    let mut command = Command::new(curl);
    command
        .args([
            // 禁用用户级 .curlrc，避免代理、输出或调试配置意外改变凭据请求。
            "-q",
            "--silent",
            "--show-error",
            "--connect-timeout",
            "3",
            "--max-time",
            "10",
            "--request",
            "GET",
            "--header",
            "Accept: application/json",
            "--header",
            "Content-Type: application/json",
            "--header",
            beta_header.as_str(),
            "--header",
            "User-Agent: claude-code/2.1.0",
            "--write-out",
            "\n%{http_code}",
            "--config",
            "-",
            USAGE_ENDPOINT,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|_| OAuthUsageError::QueryToolUnavailable)?;
    let config = format!("header = \"Authorization: Bearer {access_token}\"\n");
    let mut stdin = child.stdin.take().ok_or(OAuthUsageError::QueryFailed)?;
    stdin
        .write_all(config.as_bytes())
        .await
        .map_err(|_| OAuthUsageError::QueryFailed)?;
    drop(stdin);

    let output = timeout(COMMAND_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| OAuthUsageError::QueryTimedOut)?
        .map_err(|_| OAuthUsageError::QueryFailed)?;
    if !output.status.success() {
        return Err(OAuthUsageError::QueryFailed);
    }
    let (body, status) = split_curl_output(&output.stdout)?;
    if status != 200 {
        return Err(OAuthUsageError::HTTPStatus(status));
    }
    serde_json::from_slice(body).map_err(|_| OAuthUsageError::InvalidResponse)
}

fn split_curl_output(output: &[u8]) -> Result<(&[u8], u16), OAuthUsageError> {
    let Some(index) = output.iter().rposition(|byte| *byte == b'\n') else {
        return Err(OAuthUsageError::InvalidResponse);
    };
    let status = std::str::from_utf8(&output[index + 1..])
        .ok()
        .and_then(|value| value.trim().parse::<u16>().ok())
        .ok_or(OAuthUsageError::InvalidResponse)?;
    Ok((&output[..index], status))
}

fn snapshot_from_response(
    response: OAuthUsageResponse,
    subscription_type: Option<String>,
) -> Result<p::RateLimitSnapshot, OAuthUsageError> {
    let primary = response
        .five_hour
        .as_ref()
        .and_then(|window| rate_limit_window(window, 300));
    let secondary = response
        .seven_day
        .as_ref()
        .and_then(|window| rate_limit_window(window, 10_080))
        .or_else(|| {
            response
                .seven_day_sonnet
                .as_ref()
                .and_then(|window| rate_limit_window(window, 10_080))
        })
        .or_else(|| {
            response
                .seven_day_opus
                .as_ref()
                .and_then(|window| rate_limit_window(window, 10_080))
        });
    if primary.is_none() && secondary.is_none() {
        return Err(OAuthUsageError::InvalidResponse);
    }

    Ok(p::RateLimitSnapshot {
        limit_id: Some("claude".into()),
        limit_name: Some("Claude".into()),
        primary,
        secondary,
        credits: None,
        plan_type: subscription_type.map(Value::String),
        rate_limit_reached_type: None,
        availability: Some("available".into()),
        unavailable_reason: None,
    })
}

fn rate_limit_window(window: &OAuthUsageWindow, duration: i64) -> Option<p::RateLimitWindow> {
    let used_percent = window
        .utilization
        .filter(|value| value.is_finite())
        // OAuth usage endpoint 已经返回 0...100 的百分比，不再乘 100。
        .map(|value| (value.clamp(0.0, 100.0) + 1e-9).floor() as i32);
    let resets_at = window
        .resets_at
        .as_deref()
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.timestamp());
    (used_percent.is_some() || resets_at.is_some()).then_some(p::RateLimitWindow {
        used_percent,
        window_duration_mins: Some(duration),
        resets_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_keychain_credentials_without_exposing_token() {
        let data = br#"{"claudeAiOauth":{"accessToken":"test-oauth-token","expiresAt":4102444800000,"scopes":["user:profile"],"subscriptionType":"pro"}}"#;
        let credentials = parse_credentials(data).unwrap().unwrap();
        assert_eq!(credentials.scopes, vec!["user:profile"]);
        assert_eq!(credentials.subscription_type.as_deref(), Some("pro"));
        assert!(validate_credentials(&credentials).is_ok());
    }

    #[test]
    fn maps_oauth_percentages_and_reset_times() {
        let response: OAuthUsageResponse = serde_json::from_str(
            r#"{
                "five_hour":{"utilization":0.0,"resets_at":"2026-07-20T16:00:00.433227+00:00"},
                "seven_day":{"utilization":33.9,"resets_at":"2026-07-20T20:00:00.433254+00:00"}
            }"#,
        )
        .unwrap();
        let snapshot = snapshot_from_response(response, Some("pro".into())).unwrap();
        assert_eq!(snapshot.primary.unwrap().used_percent, Some(0));
        assert_eq!(snapshot.secondary.unwrap().used_percent, Some(33));
        assert_eq!(snapshot.plan_type, Some(Value::String("pro".into())));
        assert_eq!(snapshot.availability.as_deref(), Some("available"));
    }

    #[test]
    fn falls_back_to_model_weekly_window() {
        let response: OAuthUsageResponse = serde_json::from_str(
            r#"{"seven_day_sonnet":{"utilization":42,"resets_at":"2026-07-21T00:00:00Z"}}"#,
        )
        .unwrap();
        let snapshot = snapshot_from_response(response, None).unwrap();
        assert!(snapshot.primary.is_none());
        assert_eq!(snapshot.secondary.unwrap().used_percent, Some(42));
    }

    #[test]
    fn rejects_header_injection_tokens() {
        assert!(!safe_header_token("token\nheader: injected"));
        assert!(!safe_header_token("token\\value"));
        assert!(safe_header_token("test-oauth-token_123"));
    }

    #[test]
    fn splits_curl_body_and_status() {
        let (body, status) = split_curl_output(b"{\"five_hour\":null}\n200").unwrap();
        assert_eq!(body, b"{\"five_hour\":null}");
        assert_eq!(status, 200);
    }

    #[test]
    fn detects_rotated_or_extended_credentials_without_logging_tokens() {
        let previous = OAuthCredentials {
            access_token: "old-token".into(),
            scopes: vec!["user:profile".into()],
            expires_at_ms: Some(4_102_444_800_000.0),
            subscription_type: Some("pro".into()),
        };
        let rotated = OAuthCredentials {
            access_token: "new-token".into(),
            ..previous.clone()
        };
        let extended = OAuthCredentials {
            expires_at_ms: Some(4_102_448_400_000.0),
            ..previous.clone()
        };
        let expired = OAuthCredentials {
            access_token: "expired-token".into(),
            expires_at_ms: Some(1.0),
            ..previous.clone()
        };

        assert!(credentials_changed(&previous, &rotated));
        assert!(credentials_changed(&previous, &extended));
        assert!(!credentials_changed(&previous, &previous));
        assert!(can_retry_with_reloaded_credentials(&previous, &rotated));
        assert!(can_retry_with_reloaded_credentials(&previous, &extended));
        assert!(!can_retry_with_reloaded_credentials(&previous, &previous));
        assert!(!can_retry_with_reloaded_credentials(&previous, &expired));
        assert!(matches!(
            validate_credentials(&expired),
            Err(OAuthUsageError::CredentialsExpired)
        ));

        let reloaded =
            select_reloaded_credentials(&previous, Some(rotated), Some(previous.clone()))
                .expect("已轮换的 Keychain 凭据应优先于未变化的凭据文件");
        assert_eq!(reloaded.access_token, "new-token");
    }
}
