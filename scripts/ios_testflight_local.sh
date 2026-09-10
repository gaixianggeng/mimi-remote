#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
REPO_ROOT="$DEFAULT_REPO_ROOT"
PROJECT_CONFIG=""
SECRETS_CONFIG=""
LOCAL_RELEASE_REF="HEAD"
CLI_WHATS_NEW=""
LOCAL_RELEASE_MODE=""

usage() {
  cat <<'USAGE'
Usage:
  ios_testflight_local.sh --check|--dry-run|--upload [options]

Options:
  --repo PATH             Git 仓库路径，默认使用脚本所在仓库
  --config PATH           项目适配配置，默认 config/release/ios-testflight.local.env
  --secrets PATH          本机 Secrets 配置；默认由项目 ID 推导
  --ref REF               要验证或发布的 commit/ref，默认 HEAD
  --what-to-test TEXT     TestFlight 测试说明；上传模式必填
  --check                 只检查仓库配置、Secrets 和本机依赖，不归档、不上传
  --dry-run               Archive、Export、Apple 服务端 Validate，不上传
  --upload                Archive、Export、上传并分发内部 TestFlight
  -h, --help              显示帮助
USAGE
}

fail() {
  echo "ios-testflight-local: $1" >&2
  exit 1
}

require_env() {
  [[ -n "${!1:-}" ]] || fail "$1 is required"
}

read_secret() {
  local name="$1"
  local value="${!name:-}"
  local file_name="${name}_FILE"
  local file_path="${!file_name:-}"
  local service_name="${name}_KEYCHAIN_SERVICE"
  local service="${!service_name:-}"
  local account_name="${name}_KEYCHAIN_ACCOUNT"
  local account="${!account_name:-}"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  if [[ -n "$file_path" ]]; then
    [[ -f "$file_path" ]] || fail "$file_name not found: $file_path"
    command cat "$file_path"
    return 0
  fi
  if [[ -n "$service" ]]; then
    if [[ -n "$account" ]]; then
      security find-generic-password -w -s "$service" -a "$account"
    else
      security find-generic-password -w -s "$service"
    fi
    return 0
  fi
  fail "$name, $file_name or $service_name is required"
}

check_secret() {
  local name="$1"
  local value="${!name:-}"
  local file_name="${name}_FILE"
  local file_path="${!file_name:-}"
  local service_name="${name}_KEYCHAIN_SERVICE"
  local service="${!service_name:-}"
  local account_name="${name}_KEYCHAIN_ACCOUNT"
  local account="${!account_name:-}"

  [[ -z "$value" ]] || return 0
  if [[ -n "$file_path" ]]; then
    [[ -f "$file_path" ]] || fail "$file_name not found: $file_path"
    return 0
  fi
  if [[ -n "$service" ]]; then
    if [[ -n "$account" ]]; then
      security find-generic-password -s "$service" -a "$account" >/dev/null
    else
      security find-generic-password -s "$service" >/dev/null
    fi
    return 0
  fi
  fail "$name, $file_name or $service_name is required"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || fail "--repo requires a value"
      REPO_ROOT="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || fail "--config requires a value"
      PROJECT_CONFIG="$2"
      shift 2
      ;;
    --secrets)
      [[ $# -ge 2 ]] || fail "--secrets requires a value"
      SECRETS_CONFIG="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || fail "--ref requires a value"
      LOCAL_RELEASE_REF="$2"
      shift 2
      ;;
    --what-to-test)
      [[ $# -ge 2 ]] || fail "--what-to-test requires a value"
      CLI_WHATS_NEW="$2"
      shift 2
      ;;
    --dry-run)
      [[ -z "$LOCAL_RELEASE_MODE" ]] || fail "choose exactly one of --check, --dry-run or --upload"
      LOCAL_RELEASE_MODE="dry-run"
      shift
      ;;
    --check)
      [[ -z "$LOCAL_RELEASE_MODE" ]] || fail "choose exactly one of --check, --dry-run or --upload"
      LOCAL_RELEASE_MODE="check"
      shift
      ;;
    --upload)
      [[ -z "$LOCAL_RELEASE_MODE" ]] || fail "choose exactly one of --check, --dry-run or --upload"
      LOCAL_RELEASE_MODE="upload"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$LOCAL_RELEASE_MODE" ]] || fail "choose --check, --dry-run or --upload"
REPO_ROOT="$(cd "$REPO_ROOT" && git rev-parse --show-toplevel)"
release_commit="$(git -C "$REPO_ROOT" rev-parse --verify "$LOCAL_RELEASE_REF^{commit}")"
PROJECT_CONFIG="${PROJECT_CONFIG:-$REPO_ROOT/config/release/ios-testflight.local.env}"
[[ "$PROJECT_CONFIG" == /* ]] || PROJECT_CONFIG="$REPO_ROOT/$PROJECT_CONFIG"

# 仓库内配置必须读取 release commit 中的版本，避免本地未提交配置改变上传内容。
set -a
if [[ "$PROJECT_CONFIG" == "$REPO_ROOT/"* ]]; then
  project_config_relative="${PROJECT_CONFIG#$REPO_ROOT/}"
  if ! project_config_content="$(git -C "$REPO_ROOT" show "$release_commit:$project_config_relative")"; then
    fail "project config is not tracked in release ref: $project_config_relative"
  fi
  # shellcheck disable=SC1090
  source /dev/stdin <<< "$project_config_content"
else
  [[ -f "$PROJECT_CONFIG" ]] || fail "project config not found: $PROJECT_CONFIG"
  # shellcheck disable=SC1090
  source "$PROJECT_CONFIG"
fi
set +a

for name in IOS_RELEASE_PROJECT_ID IOS_RELEASE_ENTRYPOINT IOS_BUNDLE_ID DEVELOPMENT_TEAM; do
  require_env "$name"
done
[[ "$IOS_RELEASE_PROJECT_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid IOS_RELEASE_PROJECT_ID"
case "$IOS_RELEASE_ENTRYPOINT" in
  /*|../*|*/../*|*/..)
    fail "IOS_RELEASE_ENTRYPOINT must stay inside the release worktree"
    ;;
esac
git -C "$REPO_ROOT" cat-file -e "$release_commit:$IOS_RELEASE_ENTRYPOINT" \
  || fail "release entrypoint is not tracked in release ref: $IOS_RELEASE_ENTRYPOINT"

if [[ -z "$SECRETS_CONFIG" ]]; then
  SECRETS_CONFIG="${IOS_RELEASE_SECRETS_FILE:-$HOME/.config/ios-testflight/$IOS_RELEASE_PROJECT_ID/secrets.env}"
fi
[[ "$SECRETS_CONFIG" == /* ]] || SECRETS_CONFIG="$REPO_ROOT/$SECRETS_CONFIG"
[[ -f "$SECRETS_CONFIG" ]] || fail "secrets config not found: $SECRETS_CONFIG"
set -a
# shellcheck disable=SC1090
source "$SECRETS_CONFIG"
set +a

for name in APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH IOS_DISTRIBUTION_CERTIFICATE_PATH; do
  require_env "$name"
done
check_secret IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
check_secret IOS_KEYCHAIN_PASSWORD
[[ -f "$APP_STORE_CONNECT_API_KEY_PATH" ]] || fail "ASC private key not found: $APP_STORE_CONNECT_API_KEY_PATH"
[[ -f "$IOS_DISTRIBUTION_CERTIFICATE_PATH" ]] || fail "distribution certificate not found: $IOS_DISTRIBUTION_CERTIFICATE_PATH"
if [[ -z "${IOS_PROVISIONING_PROFILE_PATH:-}" && -z "${IOS_PROVISIONING_PROFILE_ID:-}" && -z "${IOS_PROVISIONING_PROFILE_NAME:-}" ]]; then
  fail "provide IOS_PROVISIONING_PROFILE_PATH, IOS_PROVISIONING_PROFILE_ID or IOS_PROVISIONING_PROFILE_NAME"
fi
if [[ -z "${IOS_WIDGET_PROVISIONING_PROFILE_PATH:-}" && -z "${IOS_WIDGET_PROVISIONING_PROFILE_ID:-}" && -z "${IOS_WIDGET_PROVISIONING_PROFILE_NAME:-}" ]]; then
  fail "provide IOS_WIDGET_PROVISIONING_PROFILE_PATH, IOS_WIDGET_PROVISIONING_PROFILE_ID or IOS_WIDGET_PROVISIONING_PROFILE_NAME"
fi
if [[ -z "${IOS_NOTIFICATION_PROVISIONING_PROFILE_PATH:-}" && -z "${IOS_NOTIFICATION_PROVISIONING_PROFILE_ID:-}" && -z "${IOS_NOTIFICATION_PROVISIONING_PROFILE_NAME:-}" ]]; then
  fail "provide IOS_NOTIFICATION_PROVISIONING_PROFILE_PATH, IOS_NOTIFICATION_PROVISIONING_PROFILE_ID or IOS_NOTIFICATION_PROVISIONING_PROFILE_NAME"
fi

for command in git security ruby plutil xcodebuild xcrun codesign tee caffeinate; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done

asc_build_number_mode="${IOS_ASC_BUILD_NUMBER_MODE:-off}"
case "$asc_build_number_mode" in
  off|shadow|enforce) ;;
  *)
    fail "IOS_ASC_BUILD_NUMBER_MODE must be off, shadow or enforce"
    ;;
esac

required_branch="${IOS_RELEASE_REQUIRED_BRANCH:-}"
if [[ -n "$required_branch" ]]; then
  branch_ref="refs/heads/$required_branch"
  branch_commit="$(git -C "$REPO_ROOT" rev-parse --verify "$branch_ref^{commit}")"
  if [[ "$LOCAL_RELEASE_MODE" == "upload" || "$LOCAL_RELEASE_MODE" == "check" ]]; then
    [[ "$release_commit" == "$branch_commit" ]] || fail "upload/check ref must equal local $required_branch tip"
  else
    git -C "$REPO_ROOT" merge-base --is-ancestor "$branch_commit" "$release_commit" \
      || fail "dry-run ref must be based on local $required_branch tip"
  fi
fi
if [[ -n "$CLI_WHATS_NEW" ]]; then
  TESTFLIGHT_WHATS_NEW="$CLI_WHATS_NEW"
fi
if [[ "$LOCAL_RELEASE_MODE" == "upload" && -z "${TESTFLIGHT_WHATS_NEW:-}" ]]; then
  fail "--what-to-test is required with --upload"
fi
if [[ -z "${TESTFLIGHT_WHATS_NEW:-}" ]]; then
  TESTFLIGHT_WHATS_NEW="本地校验：$(git -C "$REPO_ROOT" log -1 --format=%s "$release_commit")"
fi
export TESTFLIGHT_WHATS_NEW

temp_base="${TMPDIR:-/tmp}"
temp_base="${temp_base%/}"
lock_dir="$temp_base/ios-testflight-local-$IOS_RELEASE_PROJECT_ID.lock"
lock_acquired=0
work_dir=""
source_dir=""
runner_temp=""
original_keychains=""
keychain=""
profile=""
profile_plist=""
installed_profile=""
profile_backup=""
widget_profile=""
widget_profile_plist=""
installed_widget_profile=""
widget_profile_backup=""
notification_profile=""
notification_profile_plist=""
installed_notification_profile=""
notification_profile_backup=""
worktree_added=0

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "$original_keychains" && -f "$original_keychains" ]]; then
    local restored=()
    local item
    while IFS= read -r item; do
      [[ -n "$item" ]] && restored+=("$item")
    done < "$original_keychains"
    if (( ${#restored[@]} > 0 )); then
      security list-keychains -d user -s "${restored[@]}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$keychain" ]]; then
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi

  if [[ -n "$installed_profile" ]]; then
    if [[ -n "$profile_backup" && -f "$profile_backup" ]]; then
      cp "$profile_backup" "$installed_profile" >/dev/null 2>&1 || true
    else
      rm -f "$installed_profile"
    fi
  fi
  if [[ -n "$installed_widget_profile" ]]; then
    if [[ -n "$widget_profile_backup" && -f "$widget_profile_backup" ]]; then
      cp "$widget_profile_backup" "$installed_widget_profile" >/dev/null 2>&1 || true
    else
      rm -f "$installed_widget_profile"
    fi
  fi
  if [[ -n "$installed_notification_profile" ]]; then
    if [[ -n "$notification_profile_backup" && -f "$notification_profile_backup" ]]; then
      cp "$notification_profile_backup" "$installed_notification_profile" >/dev/null 2>&1 || true
    else
      rm -f "$installed_notification_profile"
    fi
  fi

  if [[ "$worktree_added" == "1" && -n "$source_dir" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$source_dir" >/dev/null 2>&1 || true
  fi
  [[ -z "$work_dir" ]] || rm -rf "$work_dir"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -rf "$lock_dir"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! mkdir "$lock_dir" 2>/dev/null; then
  lock_pid="$(command cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    fail "another release is running with pid $lock_pid"
  fi
  rm -rf "$lock_dir"
  mkdir "$lock_dir" || fail "failed to acquire release lock"
fi
lock_acquired=1
printf '%s\n' "$$" > "$lock_dir/pid"

work_dir="$(mktemp -d "$temp_base/ios-testflight-local-$IOS_RELEASE_PROJECT_ID.XXXXXX")"
source_dir="$work_dir/source"
runner_temp="$work_dir/runner-temp"
original_keychains="$work_dir/original-keychains.txt"
keychain="$work_dir/signing.keychain-db"
profile="$work_dir/app-store.mobileprovision"
profile_plist="$work_dir/profile.plist"
widget_profile="$work_dir/widget-app-store.mobileprovision"
widget_profile_plist="$work_dir/widget-profile.plist"
notification_profile="$work_dir/notification-app-store.mobileprovision"
notification_profile_plist="$work_dir/notification-profile.plist"
log_dir="${IOS_RELEASE_LOG_DIR:-$HOME/Library/Logs/ios-testflight-local/$IOS_RELEASE_PROJECT_ID}"
state_dir="${IOS_RELEASE_STATE_DIR:-$HOME/Library/Application Support/ios-testflight-local/$IOS_RELEASE_PROJECT_ID}"
mkdir -p "$log_dir" "$state_dir" "$runner_temp"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
log_file="$log_dir/$timestamp-${release_commit:0:12}-$LOCAL_RELEASE_MODE.log"
exec > >(tee -a "$log_file") 2>&1

echo "ios-testflight-local: project=$IOS_RELEASE_PROJECT_ID mode=$LOCAL_RELEASE_MODE commit=$release_commit"
echo "ios-testflight-local: log=$log_file"

git -C "$REPO_ROOT" worktree add --detach --quiet "$source_dir" "$release_commit"
worktree_added=1
entrypoint="$source_dir/$IOS_RELEASE_ENTRYPOINT"
[[ -f "$entrypoint" ]] || fail "release entrypoint not found in ref: $IOS_RELEASE_ENTRYPOINT"

# 必须从 release commit 的隔离 worktree 执行，避免 --ref 与当前 checkout
# 不一致时误用当前分支或未提交改动中的 asc 版本与校验和。
case "$asc_build_number_mode" in
  off) ;;
  shadow|enforce)
    if asc_check="$(bash "$source_dir/scripts/ios_asc_cli.sh" check)"; then
      printf '%s\n' "$asc_check"
    elif [[ "$asc_build_number_mode" == "enforce" ]]; then
      fail "pinned asc CLI check failed"
    else
      echo "ios-testflight-local: warning: pinned asc CLI check failed; shadow comparison will be skipped if unavailable" >&2
    fi
    ;;
esac

if [[ "$LOCAL_RELEASE_MODE" == "check" ]]; then
  echo "ios-testflight-local check ok: project=$IOS_RELEASE_PROJECT_ID commit=$release_commit"
  exit 0
fi

if [[ -n "${IOS_PROVISIONING_PROFILE_PATH:-}" ]]; then
  [[ -f "$IOS_PROVISIONING_PROFILE_PATH" ]] || fail "provisioning profile not found: $IOS_PROVISIONING_PROFILE_PATH"
  cp "$IOS_PROVISIONING_PROFILE_PATH" "$profile"
else
  profile_args=()
  if [[ -n "${IOS_PROVISIONING_PROFILE_ID:-}" ]]; then
    profile_args=(--profile-id "$IOS_PROVISIONING_PROFILE_ID")
  else
    profile_args=(--profile-name "$IOS_PROVISIONING_PROFILE_NAME")
  fi
  ruby "$SCRIPT_DIR/ios_asc_download_profile.rb" "${profile_args[@]}" --output "$profile"
fi
chmod 600 "$profile"

security cms -D -i "$profile" > "$profile_plist"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist")"
profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")"
profile_expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist")"
[[ "$profile_team" == "$DEVELOPMENT_TEAM" ]] || fail "provisioning profile team mismatch"
[[ "$profile_app_id" == "$DEVELOPMENT_TEAM.$IOS_BUNDLE_ID" ]] || fail "provisioning profile bundle id mismatch"
if [[ -n "${IOS_EXPECTED_PROVISIONING_PROFILE_NAME:-}" ]]; then
  [[ "$profile_name" == "$IOS_EXPECTED_PROVISIONING_PROFILE_NAME" ]] || fail "unexpected provisioning profile: $profile_name"
fi
ruby -rtime -e 'exit(Time.parse(ARGV.fetch(0)) > Time.now ? 0 : 1)' "$profile_expiration" \
  || fail "provisioning profile is expired"

profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profiles_dir"
installed_profile="$profiles_dir/$profile_uuid.mobileprovision"
if [[ -f "$installed_profile" ]]; then
  profile_backup="$work_dir/installed-profile.backup"
  cp "$installed_profile" "$profile_backup"
fi
cp "$profile" "$installed_profile"

if [[ -n "${IOS_WIDGET_PROVISIONING_PROFILE_PATH:-}" ]]; then
  [[ -f "$IOS_WIDGET_PROVISIONING_PROFILE_PATH" ]] || fail "widget provisioning profile not found: $IOS_WIDGET_PROVISIONING_PROFILE_PATH"
  cp "$IOS_WIDGET_PROVISIONING_PROFILE_PATH" "$widget_profile"
else
  widget_profile_args=()
  if [[ -n "${IOS_WIDGET_PROVISIONING_PROFILE_ID:-}" ]]; then
    widget_profile_args=(--profile-id "$IOS_WIDGET_PROVISIONING_PROFILE_ID")
  else
    widget_profile_args=(--profile-name "$IOS_WIDGET_PROVISIONING_PROFILE_NAME")
  fi
  ruby "$SCRIPT_DIR/ios_asc_download_profile.rb" "${widget_profile_args[@]}" --output "$widget_profile"
fi
chmod 600 "$widget_profile"

security cms -D -i "$widget_profile" > "$widget_profile_plist"
widget_profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$widget_profile_plist")"
widget_profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$widget_profile_plist")"
widget_profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$widget_profile_plist")"
widget_profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$widget_profile_plist")"
widget_profile_expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$widget_profile_plist")"
widget_bundle_id="${IOS_WIDGET_BUNDLE_ID:-com.gaixianggeng.mimi.carstatuswidget}"
[[ "$widget_profile_team" == "$DEVELOPMENT_TEAM" ]] || fail "widget provisioning profile team mismatch"
[[ "$widget_profile_app_id" == "$DEVELOPMENT_TEAM.$widget_bundle_id" ]] || fail "widget provisioning profile bundle id mismatch"
if [[ -n "${IOS_WIDGET_EXPECTED_PROVISIONING_PROFILE_NAME:-}" ]]; then
  [[ "$widget_profile_name" == "$IOS_WIDGET_EXPECTED_PROVISIONING_PROFILE_NAME" ]] || fail "unexpected widget provisioning profile: $widget_profile_name"
fi
ruby -rtime -e 'exit(Time.parse(ARGV.fetch(0)) > Time.now ? 0 : 1)' "$widget_profile_expiration" \
  || fail "widget provisioning profile is expired"

# 通知扩展（#418）在设备上用 App Group 缓存改写锁屏标题，和 Widget 一样需要
# 独立的 App Store profile；不能拿主 App 或 Widget profile 代替。
if [[ -n "${IOS_NOTIFICATION_PROVISIONING_PROFILE_PATH:-}" ]]; then
  [[ -f "$IOS_NOTIFICATION_PROVISIONING_PROFILE_PATH" ]] || fail "notification provisioning profile not found: $IOS_NOTIFICATION_PROVISIONING_PROFILE_PATH"
  cp "$IOS_NOTIFICATION_PROVISIONING_PROFILE_PATH" "$notification_profile"
else
  notification_profile_args=()
  if [[ -n "${IOS_NOTIFICATION_PROVISIONING_PROFILE_ID:-}" ]]; then
    notification_profile_args=(--profile-id "$IOS_NOTIFICATION_PROVISIONING_PROFILE_ID")
  else
    notification_profile_args=(--profile-name "$IOS_NOTIFICATION_PROVISIONING_PROFILE_NAME")
  fi
  ruby "$SCRIPT_DIR/ios_asc_download_profile.rb" "${notification_profile_args[@]}" --output "$notification_profile"
fi
chmod 600 "$notification_profile"

security cms -D -i "$notification_profile" > "$notification_profile_plist"
notification_profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$notification_profile_plist")"
notification_profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$notification_profile_plist")"
notification_profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$notification_profile_plist")"
notification_profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$notification_profile_plist")"
notification_profile_expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$notification_profile_plist")"
notification_bundle_id="${IOS_NOTIFICATION_BUNDLE_ID:-com.gaixianggeng.mimi.notificationservice}"
[[ "$notification_profile_team" == "$DEVELOPMENT_TEAM" ]] || fail "notification provisioning profile team mismatch"
[[ "$notification_profile_app_id" == "$DEVELOPMENT_TEAM.$notification_bundle_id" ]] || fail "notification provisioning profile bundle id mismatch"
if [[ -n "${IOS_NOTIFICATION_EXPECTED_PROVISIONING_PROFILE_NAME:-}" ]]; then
  [[ "$notification_profile_name" == "$IOS_NOTIFICATION_EXPECTED_PROVISIONING_PROFILE_NAME" ]] || fail "unexpected notification provisioning profile: $notification_profile_name"
fi
ruby -rtime -e 'exit(Time.parse(ARGV.fetch(0)) > Time.now ? 0 : 1)' "$notification_profile_expiration" \
  || fail "notification provisioning profile is expired"

for entitlement_plist in "$profile_plist" "$widget_profile_plist" "$notification_profile_plist"; do
  profile_app_groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$entitlement_plist" 2>/dev/null || true)"
  [[ "$profile_app_groups" == *"group.com.gaixianggeng.mimi"* ]] \
    || fail "provisioning profile missing group.com.gaixianggeng.mimi App Group"
done

installed_widget_profile="$profiles_dir/$widget_profile_uuid.mobileprovision"
if [[ -f "$installed_widget_profile" ]]; then
  widget_profile_backup="$work_dir/installed-widget-profile.backup"
  cp "$installed_widget_profile" "$widget_profile_backup"
fi
cp "$widget_profile" "$installed_widget_profile"

installed_notification_profile="$profiles_dir/$notification_profile_uuid.mobileprovision"
if [[ -f "$installed_notification_profile" ]]; then
  notification_profile_backup="$work_dir/installed-notification-profile.backup"
  cp "$installed_notification_profile" "$notification_profile_backup"
fi
cp "$notification_profile" "$installed_notification_profile"

distribution_password="$(read_secret IOS_DISTRIBUTION_CERTIFICATE_PASSWORD)"
keychain_password="$(read_secret IOS_KEYCHAIN_PASSWORD)"
security list-keychains -d user \
  | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/' \
  > "$original_keychains"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$IOS_DISTRIBUTION_CERTIFICATE_PATH" \
  -P "$distribution_password" \
  -A -t cert -f pkcs12 -k "$keychain" >/dev/null
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain" >/dev/null
unset distribution_password keychain_password

search_list=("$keychain")
while IFS= read -r item; do
  [[ -n "$item" && "$item" != "$keychain" ]] && search_list+=("$item")
done < "$original_keychains"
security list-keychains -d user -s "${search_list[@]}"

signing_identity="$(
  security find-identity -v -p codesigning "$keychain" \
    | sed -nE 's/.*"((Apple|iPhone) Distribution:[^"]+)".*/\1/p' \
    | head -n 1
)"
[[ -n "$signing_identity" && "$signing_identity" == *"($DEVELOPMENT_TEAM)" ]] \
  || fail "distribution identity for team $DEVELOPMENT_TEAM not found"

if [[ -n "${XCODE_APP_PATH:-}" ]]; then
  export DEVELOPER_DIR="$XCODE_APP_PATH/Contents/Developer"
else
  export DEVELOPER_DIR="$(xcode-select -p)"
fi
[[ -d "$DEVELOPER_DIR" ]] || fail "invalid DEVELOPER_DIR: $DEVELOPER_DIR"
xcodebuild -version

export RUNNER_TEMP="$runner_temp"
export IOS_SIGNING_STYLE=manual
export IOS_SIGNING_KEYCHAIN_PATH="$keychain"
export IOS_CODE_SIGN_IDENTITY="$signing_identity"
export IOS_PROVISIONING_PROFILE_SPECIFIER="$profile_name"
export IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER="$widget_profile_name"
export IOS_NOTIFICATION_PROVISIONING_PROFILE_SPECIFIER="$notification_profile_name"
if [[ "$LOCAL_RELEASE_MODE" == "upload" ]]; then
  export IOS_TESTFLIGHT_UPLOAD=1
  export IOS_TESTFLIGHT_VALIDATE=0
else
  export IOS_TESTFLIGHT_UPLOAD=0
  export IOS_TESTFLIGHT_VALIDATE=1
fi

release_shell="${IOS_RELEASE_SHELL:-/bin/bash}"
[[ -x "$release_shell" ]] || fail "release shell is not executable: $release_shell"
(
  cd "$source_dir"
  /usr/bin/caffeinate -im "$release_shell" "$entrypoint"
)

state_tmp="$state_dir/last-run.env.tmp"
{
  printf 'IOS_RELEASE_PROJECT_ID=%q\n' "$IOS_RELEASE_PROJECT_ID"
  printf 'IOS_RELEASE_COMMIT=%q\n' "$release_commit"
  printf 'IOS_RELEASE_MODE=%q\n' "$LOCAL_RELEASE_MODE"
  printf 'IOS_RELEASE_COMPLETED_AT=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'IOS_RELEASE_LOG=%q\n' "$log_file"
} > "$state_tmp"
chmod 600 "$state_tmp"
mv "$state_tmp" "$state_dir/last-run.env"
echo "ios-testflight-local ok: mode=$LOCAL_RELEASE_MODE commit=$release_commit log=$log_file"
