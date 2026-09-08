#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/MimiRemote/MimiRemote.xcodeproj"
SCHEME="MimiRemote"
IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-com.gaixianggeng.mimi}"
IOS_WIDGET_BUNDLE_ID="${IOS_WIDGET_BUNDLE_ID:-com.gaixianggeng.mimi.carstatuswidget}"
IOS_TESTFLIGHT_UPLOAD="${IOS_TESTFLIGHT_UPLOAD:-1}"
IOS_TESTFLIGHT_VALIDATE="${IOS_TESTFLIGHT_VALIDATE:-0}"
TESTFLIGHT_WHATS_NEW="${TESTFLIGHT_WHATS_NEW:-}"
IOS_ASC_BUILD_NUMBER_MODE="${IOS_ASC_BUILD_NUMBER_MODE:-off}"

fail() {
  echo "ios-testflight-ci: $1" >&2
  exit 1
}

require_env() {
  [[ -n "${!1:-}" ]] || fail "$1 is required"
}

case "$IOS_ASC_BUILD_NUMBER_MODE" in
  off|shadow|enforce) ;;
  *) fail "IOS_ASC_BUILD_NUMBER_MODE must be off, shadow or enforce" ;;
esac

run_asc_build_number_shadow() {
  local phase="$1"
  local local_build="$2"
  local expected_build="$3"
  local shadow_output
  local shadow_suggested

  [[ "$IOS_ASC_BUILD_NUMBER_MODE" != "off" ]] || return 0

  # 第一阶段只做影子核对：Ruby 仍是实际构建号的唯一来源。shadow 模式下
  # asc 不可用、查询失败或结果不一致都会写日志但不改变 Archive/上传行为；
  # 稳定后可切 enforce，把同一检查升级为发布门禁。
  if shadow_output="$(
    bash "$ROOT_DIR/scripts/ios_asc_cli.sh" next-build-number \
      --bundle-id "$IOS_BUNDLE_ID" \
      --version "$marketing_version" \
      --build "$local_build"
  )"; then
    printf '%s\n' "$shadow_output"
  else
    printf 'ASC_CLI_SHADOW_PHASE=%s\n' "$phase"
    printf 'ASC_CLI_SHADOW_STATUS=error\n'
    if [[ "$IOS_ASC_BUILD_NUMBER_MODE" == "enforce" ]]; then
      fail "asc shadow query failed during $phase"
    fi
    echo "ios-testflight-ci: warning: asc shadow query failed during $phase; keep Ruby preflight result" >&2
    return 0
  fi

  shadow_suggested="$(
    printf '%s\n' "$shadow_output" \
      | awk -F= '/^ASC_CLI_SUGGESTED_BUILD_NUMBER=/{print $2; exit}'
  )"
  if [[ ! "$shadow_suggested" =~ ^[0-9]+$ ]]; then
    printf 'ASC_CLI_SHADOW_PHASE=%s\n' "$phase"
    printf 'ASC_CLI_SHADOW_STATUS=invalid-output\n'
    if [[ "$IOS_ASC_BUILD_NUMBER_MODE" == "enforce" ]]; then
      fail "asc shadow output is invalid during $phase"
    fi
    echo "ios-testflight-ci: warning: asc shadow output is invalid during $phase; keep Ruby preflight result" >&2
    return 0
  fi

  printf 'ASC_CLI_SHADOW_PHASE=%s\n' "$phase"
  printf 'ASC_CLI_SHADOW_EXPECTED_BUILD_NUMBER=%s\n' "$expected_build"
  if [[ "$shadow_suggested" == "$expected_build" ]]; then
    printf 'ASC_CLI_SHADOW_STATUS=match\n'
    return 0
  fi

  printf 'ASC_CLI_SHADOW_STATUS=mismatch\n'
  if [[ "$IOS_ASC_BUILD_NUMBER_MODE" == "enforce" ]]; then
    fail "asc shadow mismatch during $phase: ruby=$expected_build asc=$shadow_suggested"
  fi
  echo "ios-testflight-ci: warning: asc shadow mismatch during $phase: ruby=$expected_build asc=$shadow_suggested; keep Ruby preflight result" >&2
}

for command in git ruby bash go xcodebuild xcrun plutil find file sw_vers awk sort codesign; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
for key in RUNNER_TEMP DEVELOPMENT_TEAM APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH IOS_SIGNING_KEYCHAIN_PATH IOS_CODE_SIGN_IDENTITY IOS_PROVISIONING_PROFILE_SPECIFIER IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER; do
  require_env "$key"
done
case "$IOS_TESTFLIGHT_UPLOAD:$IOS_TESTFLIGHT_VALIDATE" in
  1:0|0:1) ;;
  *) fail "choose exactly one mode: upload or validate" ;;
esac
if [[ "$IOS_TESTFLIGHT_UPLOAD" == "1" ]]; then
  require_env TESTFLIGHT_BETA_GROUP_ID
  [[ -n "$TESTFLIGHT_WHATS_NEW" ]] || fail "TESTFLIGHT_WHATS_NEW is required"
fi
[[ -f "$PROJECT/project.pbxproj" ]] || fail "Xcode project not found: $PROJECT"
[[ -f "$ROOT_DIR/scripts/ios_asc_build_number_preflight.rb" ]] || fail "missing build-number preflight"
[[ -f "$ROOT_DIR/scripts/distribute_internal_build.rb" ]] || fail "missing distribution script"

# 正式发布必须记录并校验“宿主系统 + Xcode + SDK”完整组合。只检查
# xcodebuild -version 不够，因为 Beta macOS 也会写入归档的 BuildMachineOSBuild。
host_os_version="$(sw_vers -productVersion)"
host_os_build="$(sw_vers -buildVersion)"
xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
xcode_build="$(xcodebuild -version | sed -n '2s/^Build version //p')"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
sdk_build="$(xcrun --sdk iphoneos --show-sdk-build-version)"

check_expected() {
  local variable_name="$1"
  local actual="$2"
  local label="$3"
  local expected="${!variable_name:-}"
  [[ -z "$expected" || "$actual" == "$expected" ]] \
    || fail "$label mismatch: expected=$expected actual=$actual"
}

check_expected IOS_RELEASE_EXPECTED_MACOS_VERSION "$host_os_version" "macOS version"
check_expected IOS_RELEASE_EXPECTED_MACOS_BUILD "$host_os_build" "macOS build"
check_expected IOS_RELEASE_EXPECTED_XCODE_VERSION "$xcode_version" "Xcode version"
check_expected IOS_RELEASE_EXPECTED_XCODE_BUILD "$xcode_build" "Xcode build"
check_expected IOS_RELEASE_EXPECTED_SDK_VERSION "$sdk_version" "iOS SDK version"
check_expected IOS_RELEASE_EXPECTED_SDK_BUILD "$sdk_build" "iOS SDK build"
if [[ -n "${IOS_RELEASE_EXPECTED_MACOS_MAJOR:-}" ]]; then
  [[ "$host_os_version" == "$IOS_RELEASE_EXPECTED_MACOS_MAJOR".* ]] \
    || fail "macOS major mismatch: expected=$IOS_RELEASE_EXPECTED_MACOS_MAJOR actual=$host_os_version"
fi
echo "ios-testflight-ci: host macOS=$host_os_version ($host_os_build)"
echo "ios-testflight-ci: toolchain Xcode=$xcode_version ($xcode_build) SDK=$sdk_version ($sdk_build)"

# 本地执行器会提供干净 worktree；入口再检查一次，避免发布时混入临时改动。
git -C "$ROOT_DIR" diff --quiet
git -C "$ROOT_DIR" diff --cached --quiet
bash "$ROOT_DIR/scripts/check-ios-privacy-manifest.sh"

# Tailcat XCFramework 是本地生成产物，不进入 Git。发布时必须从仓库固定的
# Tailcat 版本重新生成；否则 App 虽能安装，但实验开关会因缺少桥接库而不可用。
GOTOOLCHAIN=auto bash "$ROOT_DIR/scripts/build-tailcat-mobile.sh"

settings="$(
  xcodebuild \
    -project "$PROJECT" \
    -target MimiRemote \
    -configuration Release \
    -showBuildSettings
)"
# 不能在首个匹配后退出 awk。settings 较大且 pipefail 开启时，提前关闭管道会让
# printf 收到 SIGPIPE，使发布在归档前误判失败。
marketing_version="$(printf '%s\n' "$settings" | awk -F= '!found && /^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; found=1}')"
current_build="$(printf '%s\n' "$settings" | awk -F= '!found && /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; found=1}')"
[[ -n "$marketing_version" ]] || fail "MARKETING_VERSION not found"
[[ "$current_build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be an integer"

# 构建前先问 ASC，避免沿用 GitHub run number 号段或归档后才发现重复号。
preflight="$(
  ruby "$ROOT_DIR/scripts/ios_asc_build_number_preflight.rb" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --version "$marketing_version" \
    --build "$current_build"
)"
printf '%s\n' "$preflight"
build_number="$(printf '%s\n' "$preflight" | awk -F= '/^ASC_SUGGESTED_BUILD_NUMBER=/{print $2; exit}')"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "suggested build number must be an integer"
run_asc_build_number_shadow "before-archive" "$current_build" "$build_number"

output="$RUNNER_TEMP/mimi-testflight/$marketing_version-$build_number"
archive="$output/MimiRemote.xcarchive"
export_path="$output/export"
export_options="$output/ExportOptions.plist"
rm -rf "$output"
mkdir -p "$output"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$IOS_BUNDLE_ID</key><string>$IOS_PROVISIONING_PROFILE_SPECIFIER</string>
    <key>$IOS_WIDGET_BUNDLE_ID</key><string>$IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER</string>
  </dict>
</dict>
</plist>
PLIST

echo "ios-testflight-ci: archive $IOS_BUNDLE_ID $marketing_version ($build_number)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IOS_CODE_SIGN_IDENTITY" \
  IOS_PROVISIONING_PROFILE_SPECIFIER="$IOS_PROVISIONING_PROFILE_SPECIFIER" \
  IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER="$IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER" \
  OTHER_CODE_SIGN_FLAGS="--keychain $IOS_SIGNING_KEYCHAIN_PATH" \
  -quiet

archive_info="$archive/Products/Applications/MimiRemote.app/Info.plist"
[[ -f "$archive_info" ]] || fail "archive app Info.plist not found"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$archive_info")" == "$IOS_BUNDLE_ID" ]] || fail "archive bundle id mismatch"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$archive_info")" == "$marketing_version" ]] || fail "archive version mismatch"
[[ "$(plutil -extract CFBundleVersion raw -o - "$archive_info")" == "$build_number" ]] || fail "archive build mismatch"
[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$archive_info")" == "false" ]] || fail "encryption declaration must be false"

widget_path="$archive/Products/Applications/MimiRemote.app/PlugIns/MimiCarStatusWidget.appex"
widget_info="$widget_path/Info.plist"
[[ -f "$widget_info" ]] || fail "archive widget Info.plist not found"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$widget_info")" == "$IOS_WIDGET_BUNDLE_ID" ]] || fail "archive widget bundle id mismatch"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$widget_info")" == "$marketing_version" ]] || fail "archive widget version mismatch"
[[ "$(plutil -extract CFBundleVersion raw -o - "$widget_info")" == "$build_number" ]] || fail "archive widget build mismatch"

# 主 App 与 Widget 必须分别由各自 profile 签名，同时共享同一个 App Group。
# 这里审计最终归档签名，而不是只相信构建参数，防止 extension 被主 App profile 误签。
for signed_bundle in "$archive/Products/Applications/MimiRemote.app" "$widget_path"; do
  entitlements_plist="$output/$(basename "$signed_bundle").entitlements.plist"
  codesign -d --entitlements :- "$signed_bundle" > "$entitlements_plist" 2>/dev/null
  app_groups="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$entitlements_plist" 2>/dev/null || true)"
  [[ "$app_groups" == *"group.com.gaixianggeng.mimi"* ]] \
    || fail "$(basename "$signed_bundle") missing shared App Group entitlement"
done
echo "ios-testflight-ci: archive toolchain BuildMachineOSBuild=$(plutil -extract BuildMachineOSBuild raw -o - "$archive_info") DTXcodeBuild=$(plutil -extract DTXcodeBuild raw -o - "$archive_info") DTSDKName=$(plutil -extract DTSDKName raw -o - "$archive_info")"

# 递归检查归档内所有 bundle 和 Mach-O，避免主 App 已切换正式 Xcode，
# 但 Frameworks、PlugIns 或复制进包的预编译二进制仍来自 Beta SDK。
bundle_count=0
while IFS= read -r -d '' plist; do
  bundle_xcode_build="$(plutil -extract DTXcodeBuild raw -o - "$plist" 2>/dev/null || true)"
  [[ -n "$bundle_xcode_build" ]] || continue
  bundle_count=$((bundle_count + 1))
  relative_plist="${plist#"$archive/"}"
  bundle_machine_build="$(plutil -extract BuildMachineOSBuild raw -o - "$plist" 2>/dev/null || true)"
  bundle_sdk_name="$(plutil -extract DTSDKName raw -o - "$plist" 2>/dev/null || true)"
  bundle_sdk_build="$(plutil -extract DTSDKBuild raw -o - "$plist" 2>/dev/null || true)"
  bundle_platform_build="$(plutil -extract DTPlatformBuild raw -o - "$plist" 2>/dev/null || true)"
  [[ "$bundle_machine_build" == "$host_os_build" ]] \
    || fail "$relative_plist BuildMachineOSBuild mismatch: $bundle_machine_build"
  [[ "$bundle_xcode_build" == "$xcode_build" ]] \
    || fail "$relative_plist DTXcodeBuild mismatch: $bundle_xcode_build"
  [[ "$bundle_sdk_name" == "iphoneos$sdk_version" ]] \
    || fail "$relative_plist DTSDKName mismatch: $bundle_sdk_name"
  [[ "$bundle_sdk_build" == "$sdk_build" ]] \
    || fail "$relative_plist DTSDKBuild mismatch: $bundle_sdk_build"
  [[ "$bundle_platform_build" == "$sdk_build" ]] \
    || fail "$relative_plist DTPlatformBuild mismatch: $bundle_platform_build"
  echo "ios-testflight-ci: audited bundle $relative_plist"
done < <(find "$archive/Products/Applications" -name Info.plist -type f -print0)
(( bundle_count > 0 )) || fail "no bundle toolchain metadata found in archive"

macho_count=0
while IFS= read -r -d '' candidate; do
  file_type="$(file -b "$candidate")"
  [[ "$file_type" == *"Mach-O"* ]] || continue
  macho_count=$((macho_count + 1))
  relative_binary="${candidate#"$archive/"}"
  macho_sdks="$(
    xcrun vtool -show-build "$candidate" \
      | awk '$1 == "sdk" { print $2 }' \
      | sort -u
  )"
  [[ -n "$macho_sdks" ]] || fail "$relative_binary has no LC_BUILD_VERSION SDK"
  while IFS= read -r macho_sdk; do
    [[ "$macho_sdk" == "$sdk_version" ]] \
      || fail "$relative_binary SDK mismatch: expected=$sdk_version actual=$macho_sdk"
  done <<< "$macho_sdks"
  echo "ios-testflight-ci: audited Mach-O $relative_binary sdk=$macho_sdks"
done < <(find "$archive/Products/Applications" -type f -perm -111 -print0)
(( macho_count > 0 )) || fail "no Mach-O binaries found in archive"

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  -quiet

ipa_candidates=()
while IFS= read -r ipa; do
  ipa_candidates+=("$ipa")
done < <(find "$export_path" -maxdepth 1 -name '*.ipa' -type f -print)
[[ "${#ipa_candidates[@]}" == "1" ]] || fail "expected exactly one IPA"
ipa="${ipa_candidates[0]}"

# 上传前再次检查远端 build，发现竞争发布就停止并要求重新归档。
final_preflight="$(
  ruby "$ROOT_DIR/scripts/ios_asc_build_number_preflight.rb" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --version "$marketing_version" \
    --build "$build_number"
)"
final_suggested="$(printf '%s\n' "$final_preflight" | awk -F= '/^ASC_SUGGESTED_BUILD_NUMBER=/{print $2; exit}')"
[[ "$final_suggested" == "$build_number" ]] || fail "remote build number changed during archive; rebuild with $final_suggested"
run_asc_build_number_shadow "before-upload" "$build_number" "$final_suggested"

if [[ "$IOS_TESTFLIGHT_VALIDATE" == "1" ]]; then
  echo "ios-testflight-ci: validate $IOS_BUNDLE_ID $marketing_version ($build_number)"
  xcrun altool --validate-app \
    --file "$ipa" \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
    --p8-file-path "$APP_STORE_CONNECT_API_KEY_PATH"
else
  echo "ios-testflight-ci: upload $IOS_BUNDLE_ID $marketing_version ($build_number)"
  xcrun altool --upload-app \
    --file "$ipa" \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
    --p8-file-path "$APP_STORE_CONNECT_API_KEY_PATH"
  IOS_BUNDLE_ID="$IOS_BUNDLE_ID" \
  TESTFLIGHT_BETA_GROUP_ID="$TESTFLIGHT_BETA_GROUP_ID" \
  TESTFLIGHT_WHATS_NEW="$TESTFLIGHT_WHATS_NEW" \
    ruby "$ROOT_DIR/scripts/distribute_internal_build.rb" "$ipa"
fi

echo "ios-testflight-ci ok: mode=$([[ "$IOS_TESTFLIGHT_UPLOAD" == "1" ]] && printf upload || printf validate) version=$marketing_version build=$build_number ipa=$ipa"
