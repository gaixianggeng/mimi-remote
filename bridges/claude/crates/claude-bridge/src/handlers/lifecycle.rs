//! `initialize` / `initialized` plus the `account/*` and `feedback/upload`
//! shapes. The bridge does not own claude's authentication (the user runs
//! `claude auth login` themselves), so the account methods are stubs that report
//! "no account, no auth required".

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use alleycat_codex_proto as p;
use anyhow::Result;
use tokio::time::timeout;

use crate::state::ConnectionState;

/// Bridge user agent string included in `initialize` responses.
pub const USER_AGENT: &str = concat!("alleycat-claude-bridge/", env!("CARGO_PKG_VERSION"));

/// Default codex_home for the bridge: `$XDG_CONFIG_HOME/codex/claude-bridge`
/// on Linux, equivalent on macOS/Windows. Falls back to `.codex/claude-bridge`
/// when no config dir is resolvable.
pub fn default_codex_home() -> PathBuf {
    if let Some(dirs) = directories::ProjectDirs::from("", "", "codex") {
        dirs.config_dir().join("claude-bridge")
    } else {
        PathBuf::from(".codex/claude-bridge")
    }
}

pub fn handle_initialize(
    state: &Arc<ConnectionState>,
    params: p::InitializeParams,
    codex_home: &std::path::Path,
) -> p::InitializeResponse {
    state.set_capabilities(
        Some(params.client_info.name.clone()),
        params.client_info.title.clone(),
        Some(params.client_info.version.clone()),
        params.capabilities.as_ref(),
    );

    p::InitializeResponse {
        user_agent: USER_AGENT.to_string(),
        codex_home: codex_home.to_string_lossy().into_owned(),
        platform_family: platform_family().to_string(),
        platform_os: platform_os().to_string(),
    }
}

/// `initialized` is a one-shot notification with no params.
pub fn handle_initialized(_state: &Arc<ConnectionState>) {
    tracing::debug!("client sent initialized; connection ready");
}

// === account/* ============================================================
//
// claude's auth lives outside the bridge: the user runs `claude auth login`
// (or sets `ANTHROPIC_API_KEY`) and the spawned claude process picks it up.
// The bridge has nothing to authenticate, so every account method synthesizes
// the "no account, no auth required" answer codex clients tolerate.

pub fn handle_account_read(
    _state: &Arc<ConnectionState>,
    _params: p::GetAccountParams,
) -> p::GetAccountResponse {
    // claude-code authenticates via Anthropic API key or OAuth token; either
    // way the codex-side account shape is `ApiKey` (codex reserves
    // `Chatgpt` for OpenAI sign-in only).
    p::GetAccountResponse {
        account: Some(p::Account::ApiKey {}),
        requires_openai_auth: false,
    }
}

/// 优先从 Claude OAuth usage endpoint 主动读取账号窗口；不可用时退回当前连接
/// 已观测到的 `rate_limit_event`。两条链路都失败才明确返回 unavailable。
pub async fn handle_account_rate_limits_read(
    state: &Arc<ConnectionState>,
) -> p::GetAccountRateLimitsResponse {
    const OAUTH_CACHE_SECS: i64 = 5 * 60;
    const OAUTH_RETRY_SECS: i64 = 15;
    // OAuth usage 是展示增强能力。整条只读查询必须有界，不能拖慢会话链路。
    const OAUTH_REFRESH_BUDGET: Duration = Duration::from_secs(12);
    let now = chrono::Utc::now().timestamp();
    if let Some(snapshot) = state.cached_oauth_rate_limit(now, OAUTH_CACHE_SECS) {
        return p::GetAccountRateLimitsResponse {
            rate_limits: snapshot,
            rate_limits_by_limit_id: None,
        };
    }
    // 设置页和菜单栏可能同时触发刷新。包括等待 single-flight 锁在内，整条
    // Keychain/OAuth 链路最多占用 12 秒；超时会取消 curl，避免断开的菜单
    // 客户端留下长时间工作。该链路不启动 Claude，也不驱动认证刷新。
    let refresh_result = timeout(OAUTH_REFRESH_BUDGET, async {
        let _refresh_guard = state.lock_oauth_rate_limit_refresh().await;
        let now = chrono::Utc::now().timestamp();
        if let Some(snapshot) = state.cached_oauth_rate_limit(now, OAUTH_CACHE_SECS) {
            return Some(snapshot);
        }
        if state.begin_oauth_rate_limit_refresh(now, OAUTH_RETRY_SECS) {
            match crate::oauth_usage::fetch_rate_limit_snapshot(state.claude_pool().claude_bin())
                .await
            {
                Ok(snapshot) => {
                    state.store_oauth_rate_limit(snapshot.clone(), chrono::Utc::now().timestamp());
                    return Some(snapshot);
                }
                Err(err) => {
                    // OAuth 是展示增强能力；凭据缺失、过期或临时网络失败都必须安全
                    // 降级到官方事件缓存，不能影响 Claude 会话与发送链路。
                    tracing::debug!(
                        error = %err,
                        "Claude OAuth usage unavailable; falling back to observed events"
                    );
                }
            }
        }
        None
    })
    .await;
    if let Ok(Some(snapshot)) = refresh_result {
        return p::GetAccountRateLimitsResponse {
            rate_limits: snapshot,
            rate_limits_by_limit_id: None,
        };
    }
    if refresh_result.is_err() {
        tracing::debug!(
            budget_secs = OAUTH_REFRESH_BUDGET.as_secs(),
            "Claude OAuth usage refresh exceeded budget; falling back to observed events"
        );
    }

    let infos: Vec<_> = state.caches().rate_limit_infos.into_values().collect();
    if infos.is_empty() {
        return p::GetAccountRateLimitsResponse {
            rate_limits: p::RateLimitSnapshot {
                limit_id: Some("claude".into()),
                limit_name: Some("Claude".into()),
                availability: Some("unavailable".into()),
                unavailable_reason: Some("headless_statusline_unavailable".into()),
                ..Default::default()
            },
            rate_limits_by_limit_id: None,
        };
    }

    account_rate_limits_response(&infos)
}

fn account_rate_limits_response(
    infos: &[crate::pool::claude_protocol::RateLimitInfo],
) -> p::GetAccountRateLimitsResponse {
    let snapshot = rate_limit_snapshot_from_infos(infos);
    p::GetAccountRateLimitsResponse {
        rate_limits: snapshot,
        rate_limits_by_limit_id: None,
    }
}

/// 将 Claude Code `rate_limit_event` 的真实观测值映射到公共协议。
/// Claude 的 utilization 是 0...1 比例，而 Codex 协议使用 0...100 的
/// usedPercent；这里沿用 Claude Code 自身 `/usage` 的向下取整展示规则。
pub(crate) fn rate_limit_snapshot_from_infos(
    infos: &[crate::pool::claude_protocol::RateLimitInfo],
) -> p::RateLimitSnapshot {
    let primary = infos
        .iter()
        .find(|info| info.rate_limit_type.as_deref() == Some("five_hour"))
        .and_then(|info| rate_limit_window(info, 300));
    // 公共协议只有一个 secondary 槽位。优先账号总周窗口，模型专属周窗口
    // 仅在总周窗口未观测到时作为降级数据。
    let secondary = ["seven_day", "seven_day_sonnet", "seven_day_opus"]
        .into_iter()
        .find_map(|kind| {
            infos
                .iter()
                .find(|info| info.rate_limit_type.as_deref() == Some(kind))
                .and_then(|info| rate_limit_window(info, 10_080))
        });
    let has_percent = primary
        .as_ref()
        .and_then(|window| window.used_percent)
        .is_some()
        || secondary
            .as_ref()
            .and_then(|window| window.used_percent)
            .is_some();
    let reached_type = infos
        .iter()
        // allowed_warning 只是接近阈值。iOS 会把任何非空 reachedType
        // 视为额度耗尽，因此只有 Claude 明确拒绝请求时才能设置该字段。
        .find(|info| info.status == "rejected")
        .map(|info| serde_json::Value::String(info.status.clone()));

    p::RateLimitSnapshot {
        limit_id: Some("claude".into()),
        limit_name: Some("Claude".into()),
        primary,
        secondary,
        credits: None,
        plan_type: None,
        rate_limit_reached_type: reached_type,
        availability: Some("partial".into()),
        unavailable_reason: (!has_percent).then(|| "usage_percentage_unavailable".into()),
    }
}

fn rate_limit_window(
    info: &crate::pool::claude_protocol::RateLimitInfo,
    duration: i64,
) -> Option<p::RateLimitWindow> {
    let used_percent = info
        .utilization
        .filter(|value| value.is_finite())
        // 0.57 * 100 在 IEEE-754 下可能得到 56.999...；加一个极小容差后
        // 再向下取整，避免把 Claude 明确返回的整百分比少展示 1%。
        .map(|value| (value.clamp(0.0, 1.0) * 100.0 + 1e-9).floor() as i32);
    (used_percent.is_some() || info.resets_at.is_some()).then_some(p::RateLimitWindow {
        used_percent,
        window_duration_mins: Some(duration),
        resets_at: info.resets_at,
    })
}

pub(crate) fn rate_limit_updated_notification(
    infos: &[crate::pool::claude_protocol::RateLimitInfo],
) -> p::ServerNotification {
    p::ServerNotification::AccountRateLimitsUpdated(p::AccountRateLimitsUpdatedNotification {
        rate_limits: rate_limit_snapshot_from_infos(infos),
    })
}

/// We never actually start a login flow. The simplest valid reply is the
/// `apiKey` shape; the codex client treats this as "auth completed
/// synchronously, nothing to poll".
pub fn handle_account_login_start(
    _state: &Arc<ConnectionState>,
    _params: p::LoginAccountParams,
) -> Result<p::LoginAccountResponse> {
    Ok(p::LoginAccountResponse::ApiKey {})
}

pub fn handle_account_login_cancel(
    _state: &Arc<ConnectionState>,
    _params: p::CancelLoginAccountParams,
) -> p::CancelLoginAccountResponse {
    p::CancelLoginAccountResponse {
        status: p::CancelLoginAccountStatus::NotFound,
    }
}

pub fn handle_account_logout(_state: &Arc<ConnectionState>) -> p::LogoutAccountResponse {
    p::LogoutAccountResponse::default()
}

pub fn handle_feedback_upload(
    _state: &Arc<ConnectionState>,
    params: p::FeedbackUploadParams,
) -> p::FeedbackUploadResponse {
    tracing::info!(
        classification = %params.classification,
        reason = ?params.reason,
        "feedback/upload received (discarded by claude-bridge)"
    );
    p::FeedbackUploadResponse::default()
}

fn platform_family() -> &'static str {
    if cfg!(target_family = "windows") {
        "windows"
    } else {
        "unix"
    }
}

fn platform_os() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        std::env::consts::OS
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pool::claude_protocol::RateLimitInfo;
    use crate::state::ClaudeCaches;

    fn rate_limit_info(rate_limit_type: &str, utilization: Option<f64>) -> RateLimitInfo {
        RateLimitInfo {
            status: "allowed".into(),
            utilization,
            resets_at: Some(1_780_494_300),
            rate_limit_type: Some(rate_limit_type.into()),
            overage_status: None,
            is_using_overage: Some(false),
            extra: Default::default(),
        }
    }

    #[test]
    fn maps_claude_utilization_to_primary_used_percent() {
        let info = rate_limit_info("five_hour", Some(0.23));
        let snapshot = rate_limit_snapshot_from_infos(std::slice::from_ref(&info));
        let primary = snapshot.primary.expect("five-hour window");

        assert_eq!(primary.used_percent, Some(23));
        assert_eq!(primary.window_duration_mins, Some(300));
        assert_eq!(primary.resets_at, Some(1_780_494_300));
        assert_eq!(snapshot.availability.as_deref(), Some("partial"));
        assert_eq!(snapshot.unavailable_reason, None);
    }

    #[test]
    fn keeps_unavailable_reason_when_event_has_no_utilization() {
        let info = rate_limit_info("seven_day", None);
        let snapshot = rate_limit_snapshot_from_infos(std::slice::from_ref(&info));
        let secondary = snapshot.secondary.expect("weekly window");

        assert_eq!(secondary.used_percent, None);
        assert_eq!(secondary.window_duration_mins, Some(10_080));
        assert_eq!(
            snapshot.unavailable_reason.as_deref(),
            Some("usage_percentage_unavailable")
        );
    }

    #[test]
    fn clamps_out_of_range_utilization_and_ignores_non_finite_value() {
        let below_info = rate_limit_info("five_hour", Some(-0.1));
        let above_info = rate_limit_info("five_hour", Some(1.2));
        let nan_info = rate_limit_info("five_hour", Some(f64::NAN));
        let below_zero = rate_limit_snapshot_from_infos(std::slice::from_ref(&below_info));
        let above_one = rate_limit_snapshot_from_infos(std::slice::from_ref(&above_info));
        let not_a_number = rate_limit_snapshot_from_infos(std::slice::from_ref(&nan_info));

        assert_eq!(below_zero.primary.unwrap().used_percent, Some(0));
        assert_eq!(above_one.primary.unwrap().used_percent, Some(100));
        assert!(not_a_number.primary.is_some());
        assert_eq!(not_a_number.primary.unwrap().used_percent, None);
        assert_eq!(
            not_a_number.unavailable_reason.as_deref(),
            Some("usage_percentage_unavailable")
        );
    }

    #[test]
    fn merges_five_hour_and_weekly_windows_into_read_and_updated_snapshot() {
        let mut caches = ClaudeCaches::default();
        let _ = caches.refresh_rate_limit(rate_limit_info("five_hour", Some(0.23)));
        let infos = caches
            .refresh_rate_limit(rate_limit_info("seven_day", Some(0.57)))
            .expect("new weekly window should refresh the snapshot");
        let response = account_rate_limits_response(&infos);
        let snapshot = response.rate_limits;

        assert_eq!(snapshot.primary.as_ref().unwrap().used_percent, Some(23));
        assert_eq!(snapshot.secondary.as_ref().unwrap().used_percent, Some(57));
        assert_eq!(snapshot.unavailable_reason, None);

        let p::ServerNotification::AccountRateLimitsUpdated(update) =
            rate_limit_updated_notification(&infos)
        else {
            panic!("expected account/rateLimits/updated")
        };
        assert_eq!(update.rate_limits.primary.unwrap().used_percent, Some(23));
        assert_eq!(update.rate_limits.secondary.unwrap().used_percent, Some(57));
    }

    #[test]
    fn skips_duplicate_rate_limit_snapshot_broadcasts() {
        let mut caches = ClaudeCaches::default();
        let first = rate_limit_info("five_hour", Some(0.23));

        assert!(caches.refresh_rate_limit(first.clone()).is_some());
        assert!(caches.refresh_rate_limit(first).is_none());

        // 状态或用量发生变化时仍要广播，保证额度状态不会变旧。
        assert!(
            caches
                .refresh_rate_limit(rate_limit_info("five_hour", Some(0.24)))
                .is_some()
        );
    }

    #[test]
    fn warning_does_not_mark_quota_exhausted_but_rejection_does() {
        let mut warning = rate_limit_info("five_hour", Some(0.91));
        warning.status = "allowed_warning".into();
        let warning_snapshot = rate_limit_snapshot_from_infos(&[warning]);
        assert_eq!(warning_snapshot.rate_limit_reached_type, None);

        let mut rejected = rate_limit_info("five_hour", Some(1.0));
        rejected.status = "rejected".into();
        let rejected_snapshot = rate_limit_snapshot_from_infos(&[rejected]);
        assert_eq!(
            rejected_snapshot.rate_limit_reached_type,
            Some(serde_json::Value::String("rejected".into()))
        );
    }
}
