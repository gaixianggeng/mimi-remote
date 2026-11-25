#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/macos-installer-signing.sh"
PROJECT_PATH="$ROOT_DIR/macos/MimiRemoteMac/MimiRemoteMac.xcodeproj"
SCHEME="MimiRemoteMac"
OUTPUT_DIR="$ROOT_DIR/dist-macos"
DMG_BACKGROUND_PATH="$ROOT_DIR/scripts/assets/macos-installer/dmg-background.png"
DMG_WINDOW_WIDTH=660
DMG_WINDOW_HEIGHT=400
DMG_APP_POSITION_X=170
DMG_APP_POSITION_Y=185
DMG_APPLICATIONS_POSITION_X=490
DMG_APPLICATIONS_POSITION_Y=185
VERSION=""
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
SNAPSHOT=0
DEVELOPMENT_SIGNING=0
APP_ONLY=0
VERIFY_ONLY=0
VERIFY_ONLY_APP=""
RESOLVED_SLICE_TEAM_ID=""
VERIFIED_APP_TEAM_ID=""
verified_macho_count=0

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/build-macos-installer.sh --version 0.2.0 [--build-number 1] [--output-dir dist-macos]
  bash ./scripts/build-macos-installer.sh --snapshot [--app-only] --version 0.2.0 [--output-dir dist-macos]
  bash ./scripts/build-macos-installer.sh --development-signing --version 0.2.0 [--output-dir dist-macos]
  bash ./scripts/build-macos-installer.sh --verify-only [--snapshot|--development-signing] <Mimi-Remote-Mac.app>

正式构建需要以下环境变量：
  MACOS_SIGN_P12             Developer ID Application 证书和私钥的 base64 PKCS#12
  MACOS_SIGN_PASSWORD        PKCS#12 导出密码
  MACOS_NOTARY_KEY           App Store Connect API .p8 文件的 base64 内容
  MACOS_NOTARY_KEY_ID        API Key ID
  MACOS_NOTARY_ISSUER_ID     App Store Connect Issuer ID

--snapshot 使用临时 ad-hoc 签名，只验证 universal App/DMG 结构，不能安装运行后台服务。
--app-only 只能与 --snapshot 同时使用：跳过需要 Finder GUI 授权的 DMG 布局封装，仅输出已签名并校验过的 .app。
--development-signing 自动使用 Keychain 中的 Apple Development 身份，生成仅供本机
初始化与 ServiceManagement 验收的同团队签名包；不做公证，不可公开分发。
--verify-only 仅执行封包前的全量 Mach-O 签名与切片策略校验（默认按正式 Developer ID + Timestamp 策略，
可配合 --snapshot 或 --development-signing 使用）。
EOF
}

resolve_physical_dir() {
  local dir_path="$1"
  (
    CDPATH= cd -P -- "$dir_path" >/dev/null && pwd -P
  )
}

resolve_app_executable_path() {
  local app_dir="$1"
  local info_plist="$app_dir/Contents/Info.plist"
  local executable_name=""
  if [[ -f "$info_plist" ]]; then
    executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)"
  fi
  if [[ -z "$executable_name" ]]; then
    echo "Mac 安装包构建失败：无法从 ${app_dir}/Contents/Info.plist 读取 CFBundleExecutable。" >&2
    exit 1
  fi
  local executable_path="$app_dir/Contents/MacOS/$executable_name"
  if [[ ! -x "$executable_path" ]]; then
    echo "Mac 安装包构建失败：主 App 可执行文件不存在或不可执行：${executable_path}。" >&2
    exit 1
  fi
  printf '%s\n' "$executable_path"
}

verify_prepackage_macho_signatures() {
  local target_app_path="$1"
  local require_team_signing="$2"
  local require_developer_id="$3"
  local require_timestamp="$4"

  local physical_app_path expected_app_identifier=""
  physical_app_path="$(resolve_physical_dir "$target_app_path")"

  verify_macos_fixed_entry_paths "$physical_app_path"

  if [[ -e "$physical_app_path/Contents/MacOS/Mimi Remote Mac" ]]; then
    expected_app_identifier="com.gaixianggeng.mimi.mac"
  fi

  codesign --verify --deep --strict --verbose=2 "$physical_app_path"
  verify_macho_slice_policy \
    "$physical_app_path" \
    "主 App" \
    "$expected_app_identifier" \
    "$require_team_signing" \
    "" \
    "$require_developer_id" \
    "$require_timestamp"
  local app_team_identifier="$RESOLVED_SLICE_TEAM_ID"
  VERIFIED_APP_TEAM_ID="$app_team_identifier"
  verify_present_macos_fixed_machos "$physical_app_path" "$require_team_signing" \
    "$app_team_identifier" "$require_developer_id" "$require_timestamp"

  # 先把 find 输出完整写入 NUL 分隔临时清单并显式校验退出码，避免 process substitution 吞错。
  local manifest_file="$WORK_DIR/prepackage-macho-manifest.nul"
  if ! find -H "$physical_app_path" -type f -print0 > "$manifest_file"; then
    echo "Mac 安装包构建失败：枚举 App 内文件时 find 失败。" >&2
    exit 1
  fi

  local candidate_path candidate_rel_path candidate_kind
  verified_macho_count=0
  while IFS= read -r -d '' candidate_path; do
    candidate_kind="$(file -b "$candidate_path")"
    if [[ "$candidate_kind" != Mach-O* ]]; then
      continue
    fi
    verified_macho_count=$((verified_macho_count + 1))
    candidate_rel_path="${candidate_path#"$physical_app_path"/}"
    codesign --verify --strict --verbose=2 "$candidate_path"
    verify_macho_slice_policy \
      "$candidate_path" \
      "$candidate_rel_path" \
      "" \
      "$require_team_signing" \
      "$app_team_identifier" \
      "$require_developer_id" \
      "$require_timestamp"
  done < "$manifest_file"

  if [[ "$verified_macho_count" -eq 0 ]]; then
    echo "Mac 安装包构建失败：App 内没有找到任何 Mach-O 产物。" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --snapshot)
      SNAPSHOT=1
      shift
      ;;
    --app-only)
      APP_ONLY=1
      shift
      ;;
    --development-signing)
      DEVELOPMENT_SIGNING=1
      shift
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$VERIFY_ONLY" == "1" && -z "$VERIFY_ONLY_APP" && "$1" != -* ]]; then
        VERIFY_ONLY_APP="$1"
        shift
      else
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ "$SNAPSHOT" == "1" && "$DEVELOPMENT_SIGNING" == "1" ]]; then
  echo "Mac 安装包构建失败：--snapshot 与 --development-signing 不能同时使用。" >&2
  exit 2
fi
if [[ "$APP_ONLY" == "1" && "$SNAPSHOT" != "1" ]]; then
  echo "Mac 安装包构建失败：--app-only 只能与 --snapshot 同时使用。" >&2
  exit 2
fi
if [[ "$VERIFY_ONLY" == "1" && "$APP_ONLY" == "1" ]]; then
  echo "Mac 安装包构建失败：--verify-only 不能与 --app-only 同时使用。" >&2
  exit 2
fi
if [[ "$VERIFY_ONLY" == "1" && -z "$VERIFY_ONLY_APP" ]]; then
  echo "Mac 安装包构建失败：--verify-only 需要指定 .app 路径。" >&2
  exit 2
fi

WORK_DIR=""
KEYCHAIN_PATH=""
KEYCHAIN_LIST_FILE=""
DMG_MOUNT_DIR=""
DMG_MOUNTED=0

detach_dmg() {
  if [[ "$DMG_MOUNTED" != "1" ]]; then
    return 0
  fi
  if ! hdiutil detach "$DMG_MOUNT_DIR" -quiet >/dev/null 2>&1; then
    # Finder 偶尔会在保存 .DS_Store 时短暂占用卷；强制卸载仍只针对本次临时镜像。
    if ! hdiutil detach "$DMG_MOUNT_DIR" -force -quiet >/dev/null 2>&1; then
      echo "Mac 安装包构建失败：无法卸载临时 DMG 挂载点 $DMG_MOUNT_DIR。" >&2
      return 1
    fi
  fi
  DMG_MOUNTED=0
}

cleanup() {
  if [[ "$DMG_MOUNTED" == "1" ]]; then
    detach_dmg || true
  fi
  if [[ -n "$KEYCHAIN_LIST_FILE" && -f "$KEYCHAIN_LIST_FILE" ]]; then
    # 恢复用户原有的 Keychain 搜索列表，避免本地正式构建污染开发环境。
    set --
    while IFS= read -r original_keychain; do
      if [[ -n "$original_keychain" ]]; then
        set -- "$@" "$original_keychain"
      fi
    done < "$KEYCHAIN_LIST_FILE"
    if [[ $# -gt 0 ]]; then
      security list-keychains -d user -s "$@" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$KEYCHAIN_PATH" && -e "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

if [[ "$VERIFY_ONLY" == "1" ]]; then
  if [[ ! -d "$VERIFY_ONLY_APP" ]]; then
    echo "Mac 安装包构建失败：--verify-only 目标目录不存在：${VERIFY_ONLY_APP}。" >&2
    exit 2
  fi
  for command_name in awk codesign file find grep lipo mktemp plutil; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Mac 安装包构建失败：缺少命令 ${command_name}。" >&2
      exit 127
    fi
  done
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-installer-verify.XXXXXX")"
  verify_require_team=0
  verify_require_dev_id=0
  verify_require_timestamp=0
  if [[ "$SNAPSHOT" != "1" ]]; then
    verify_require_team=1
    if [[ "$DEVELOPMENT_SIGNING" != "1" ]]; then
      verify_require_dev_id=1
      verify_require_timestamp=1
    fi
  fi
  verify_prepackage_macho_signatures \
    "$VERIFY_ONLY_APP" \
    "$verify_require_team" \
    "$verify_require_dev_id" \
    "$verify_require_timestamp"
  echo "Mac 安装包封包前签名校验通过：已枚举 ${verified_macho_count} 个 Mach-O。"
  exit 0
fi

VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Mac 安装包构建失败：--version 必须是 X.Y.Z，例如 0.2.0。" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || [[ "$BUILD_NUMBER" == "0" ]]; then
  echo "Mac 安装包构建失败：--build-number 必须是正整数。" >&2
  exit 2
fi

for command_name in awk base64 codesign ditto file find grep hdiutil lipo mktemp openssl osascript plutil security shasum sips spctl xcodebuild xcrun python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Mac 安装包构建失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done
if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
  echo "Mac 安装包构建失败：缺少 $PROJECT_PATH。" >&2
  exit 1
fi
if [[ ! -f "$DMG_BACKGROUND_PATH" ]]; then
  echo "Mac 安装包构建失败：缺少 DMG 背景资产 $DMG_BACKGROUND_PATH。" >&2
  exit 1
fi
DMG_BACKGROUND_DIMENSIONS="$(sips -g pixelWidth -g pixelHeight "$DMG_BACKGROUND_PATH")"
DMG_BACKGROUND_WIDTH="$(awk '$1 == "pixelWidth:" { print $2; exit }' <<<"$DMG_BACKGROUND_DIMENSIONS")"
DMG_BACKGROUND_HEIGHT="$(awk '$1 == "pixelHeight:" { print $2; exit }' <<<"$DMG_BACKGROUND_DIMENSIONS")"
if [[ "$DMG_BACKGROUND_WIDTH" != "$DMG_WINDOW_WIDTH" || "$DMG_BACKGROUND_HEIGHT" != "$DMG_WINDOW_HEIGHT" ]]; then
  echo "Mac 安装包构建失败：DMG 背景必须是 ${DMG_WINDOW_WIDTH}x${DMG_WINDOW_HEIGHT}，实际为 ${DMG_BACKGROUND_WIDTH}x${DMG_BACKGROUND_HEIGHT}。" >&2
  exit 1
fi
PUBLISHER="$ROOT_DIR/scripts/macos-installer-publish.py"
PUBLISH_MODE=dmg
DMG_NAME=Mimi-Remote-Mac.dmg
if [[ "$APP_ONLY" == "1" ]]; then
  PUBLISH_MODE=app-only
elif [[ "$DEVELOPMENT_SIGNING" == "1" ]]; then
  PUBLISH_MODE=development-dmg
  DMG_NAME=Mimi-Remote-Mac-Development.dmg
fi
# 提前拒绝冲突，提交时在同一个输出目录锁内再次检查。
python3 "$PUBLISHER" "$PUBLISH_MODE" "$OUTPUT_DIR"
OUTPUT_DIR="$(resolve_physical_dir "$OUTPUT_DIR")"

if [[ "$SNAPSHOT" != "1" && "$DEVELOPMENT_SIGNING" != "1" ]]; then
  bash "$ROOT_DIR/scripts/check-macos-release-signing.sh"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-installer.XXXXXX")"

decode_base64() {
  local value="$1"
  local output="$2"
  if printf '%s' "$value" | base64 --decode > "$output" 2>/dev/null; then
    return
  fi
  printf '%s' "$value" | base64 -D > "$output" 2>/dev/null
}

configure_dmg_layout() {
  local mount_path="$1"

  # 先在可写 DMG 中让 Finder 写入 .DS_Store，再压缩为 UDZO，避免压缩后无法保存布局。
  osascript - \
    "$mount_path" \
    "$DMG_WINDOW_WIDTH" \
    "$DMG_WINDOW_HEIGHT" \
    "$DMG_APP_POSITION_X" \
    "$DMG_APP_POSITION_Y" \
    "$DMG_APPLICATIONS_POSITION_X" \
    "$DMG_APPLICATIONS_POSITION_Y" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  set windowWidth to (item 2 of argv) as integer
  set windowHeight to (item 3 of argv) as integer
  set appPositionX to (item 4 of argv) as integer
  set appPositionY to (item 5 of argv) as integer
  set applicationsPositionX to (item 6 of argv) as integer
  set applicationsPositionY to (item 7 of argv) as integer

  tell application "Finder"
    -- hdiutil 使用显式 mountpoint 时，Finder 中的卷名可能变成挂载目录名，
    -- 因此必须按实际路径取得窗口，不能依赖 -volname。
    set mountedAlias to (POSIX file mountPath) as alias
    set mountedDisk to disk of mountedAlias
    open mountedDisk

    set dmgWindow to missing value
    repeat with attempt from 1 to 20
      try
        set dmgWindow to «class cwnd» of mountedDisk
        -- 读取 bounds 触发 Finder 对窗口对象的实际解析，而不是只拿到延迟 specifier。
        set ignoredBounds to «class pbnd» of dmgWindow
        exit repeat
      on error errorMessage
        if attempt = 20 then
          error ("Finder 无法打开 DMG 窗口：" & errorMessage)
        end if
      end try
      delay 0.25
    end repeat
    if dmgWindow is missing value then
      error "Finder 在 5 秒内没有打开 DMG 窗口。"
    end if

    set «class pvew» of dmgWindow to «constant ecvwicnv»
    set «class tbvi» of dmgWindow to false
    set «class stvi» of dmgWindow to false
    set «class pbvi» of dmgWindow to false
    set «class sbwi» of dmgWindow to 0
    set «class pbnd» of dmgWindow to {100, 100, 100 + windowWidth, 100 + windowHeight}

    set iconViewOptions to «class icop» of dmgWindow
    set «class iarr» of iconViewOptions to «constant earrnarr»
    set «class lvis» of iconViewOptions to 112
    set «class fsiz» of iconViewOptions to 13
    set «class lpos» of iconViewOptions to «constant eposlbot»
    set «class ibkg» of iconViewOptions to (POSIX file (mountPath & "/.background/dmg-background.png")) as alias

    set position of item "Mimi Remote Mac.app" of dmgWindow to {appPositionX, appPositionY}
    set position of item "Applications" of dmgWindow to {applicationsPositionX, applicationsPositionY}
    update mountedDisk
    delay 1
    close dmgWindow
    delay 1
  end tell
end run
APPLESCRIPT
}

submit_and_wait_for_notarization() {
  local dmg_path="$1"
  local submission_json
  local submission_id
  local info_json
  local status
  local deadline

  submission_json="$(xcrun notarytool submit "$dmg_path" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$MACOS_NOTARY_KEY_ID" \
    --issuer "$MACOS_NOTARY_ISSUER_ID" \
    --output-format json)"
  submission_id="$(printf '%s' "$submission_json" | plutil -extract id raw -o - -)"
  if [[ ! "$submission_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "Mac 安装包构建失败：Apple Notary Service 没有返回有效提交 ID。" >&2
    exit 1
  fi

  echo "Apple Notary submission: $submission_id"
  deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    info_json="$(xcrun notarytool info "$submission_id" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$MACOS_NOTARY_KEY_ID" \
      --issuer "$MACOS_NOTARY_ISSUER_ID" \
      --output-format json)"
    status="$(printf '%s' "$info_json" | plutil -extract status raw -o - -)"
    echo "Apple Notary status: $status"
    case "$status" in
      Accepted)
        return
        ;;
      "In Progress")
        sleep 10
        ;;
      Invalid|Rejected)
        xcrun notarytool log "$submission_id" \
          --key "$NOTARY_KEY_PATH" \
          --key-id "$MACOS_NOTARY_KEY_ID" \
          --issuer "$MACOS_NOTARY_ISSUER_ID" || true
        echo "Mac 安装包构建失败：Apple Notary Service 返回 ${status}。" >&2
        exit 1
        ;;
      *)
        echo "Mac 安装包构建失败：未知 Apple Notary 状态 ${status}。" >&2
        exit 1
        ;;
    esac
  done

  echo "Mac 安装包构建失败：Apple 公证等待超过 20 分钟。" >&2
  exit 1
}

DERIVED_DATA="$WORK_DIR/DerivedData"
echo "==> 构建 universal Mimi Remote Mac ${VERSION} (${BUILD_NUMBER})"
xcodebuild \
  -quiet \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/Mimi Remote Mac.app"
AGENT_PATH="$APP_PATH/Contents/Resources/agentd"
BRIDGE_PATH="$APP_PATH/Contents/Resources/alleycat-claude-bridge"
ADAPTER_PATH="$APP_PATH/Contents/Resources/mimi-claude-adapter"
AGY_ADAPTER_PATH="$APP_PATH/Contents/Resources/mimi-agy-adapter"
TAILCAT_PATH="$APP_PATH/Contents/Resources/mimi-tailcat-experiment"
ADAPTER_ENTITLEMENTS="$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements"
if [[ ! -d "$APP_PATH" || ! -x "$AGENT_PATH" || ! -x "$BRIDGE_PATH" || ! -x "$ADAPTER_PATH" || ! -x "$AGY_ADAPTER_PATH" || ! -x "$TAILCAT_PATH" ]]; then
  echo "Mac 安装包构建失败：Release App、内嵌 agentd、Claude 适配器、Antigravity 适配器、旧 Claude bridge 或 Tailcat 不存在。" >&2
  exit 1
fi

verify_macos_fixed_entry_paths "$APP_PATH"
APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/Mimi Remote Mac")"
AGENT_ARCHS="$(lipo -archs "$AGENT_PATH")"
BRIDGE_ARCHS="$(lipo -archs "$BRIDGE_PATH")"
ADAPTER_ARCHS="$(lipo -archs "$ADAPTER_PATH")"
AGY_ADAPTER_ARCHS="$(lipo -archs "$AGY_ADAPTER_PATH")"
TAILCAT_ARCHS="$(lipo -archs "$TAILCAT_PATH")"
for required_arch in arm64 x86_64; do
  if [[ " $APP_ARCHS " != *" $required_arch "* \
    || " $AGENT_ARCHS " != *" $required_arch "* \
    || " $BRIDGE_ARCHS " != *" $required_arch "* \
    || " $ADAPTER_ARCHS " != *" $required_arch "* \
    || " $AGY_ADAPTER_ARCHS " != *" $required_arch "* \
    || " $TAILCAT_ARCHS " != *" $required_arch "* ]]; then
    echo "Mac 安装包构建失败：App/agentd/Claude 适配器/Antigravity 适配器/旧 bridge/Tailcat 缺少 ${required_arch}，App=${APP_ARCHS} agentd=${AGENT_ARCHS} adapter=${ADAPTER_ARCHS} agy-adapter=${AGY_ADAPTER_ARCHS} bridge=${BRIDGE_ARCHS} tailcat=${TAILCAT_ARCHS}。" >&2
    exit 1
  fi
done

CODESIGN_IDENTITY="-"
CODESIGN_TIMESTAMP=(--timestamp=none)
NOTARY_KEY_PATH=""

if [[ "$SNAPSHOT" != "1" && "$DEVELOPMENT_SIGNING" != "1" ]]; then
  for secret_name in MACOS_SIGN_P12 MACOS_SIGN_PASSWORD MACOS_NOTARY_KEY MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID; do
    if [[ -z "${!secret_name:-}" ]]; then
      echo "Mac 安装包构建失败：缺少 ${secret_name}。" >&2
      exit 1
    fi
  done

  P12_PATH="$WORK_DIR/developer-id.p12"
  NOTARY_KEY_PATH="$WORK_DIR/notary-key.p8"
  decode_base64 "$MACOS_SIGN_P12" "$P12_PATH"
  decode_base64 "$MACOS_NOTARY_KEY" "$NOTARY_KEY_PATH"
  chmod 600 "$P12_PATH" "$NOTARY_KEY_PATH"

  KEYCHAIN_PATH="$WORK_DIR/release-signing.keychain-db"
  KEYCHAIN_LIST_FILE="$WORK_DIR/original-user-keychains.txt"
  KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
  security list-keychains -d user \
    | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
    > "$KEYCHAIN_LIST_FILE"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$P12_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$MACOS_SIGN_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null

  # GitHub runner 不会自动搜索显式创建的 Keychain；codesign --keychain 仍要求它在搜索列表中。
  ACTIVE_KEYCHAINS=("$KEYCHAIN_PATH")
  while IFS= read -r original_keychain; do
    if [[ -n "$original_keychain" && "$original_keychain" != "$KEYCHAIN_PATH" ]]; then
      ACTIVE_KEYCHAINS+=("$original_keychain")
    fi
  done < "$KEYCHAIN_LIST_FILE"
  security list-keychains -d user -s "${ACTIVE_KEYCHAINS[@]}"

  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | awk '/Developer ID Application:/ { print $2; exit }')"
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "Mac 安装包构建失败：PKCS#12 中没有 Developer ID Application 身份。" >&2
    exit 1
  fi
  CODESIGN_TIMESTAMP=(--timestamp)
elif [[ "$DEVELOPMENT_SIGNING" == "1" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk '/Apple Development:/ { print $2; exit }')"
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "Mac 安装包构建失败：Keychain 中没有可用的 Apple Development 签名身份。" >&2
    exit 1
  fi
fi

echo "==> 从内到外签名 Tailcat、Claude/Antigravity 适配器与旧 bridge、agentd 与 App"
if [[ "$SNAPSHOT" == "1" || "$DEVELOPMENT_SIGNING" == "1" ]]; then
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.tailcat \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$TAILCAT_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.claude-bridge \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$BRIDGE_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.claude-adapter \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ADAPTER_ENTITLEMENTS" \
    "$ADAPTER_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.agy-adapter \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ADAPTER_ENTITLEMENTS" \
    "$AGY_ADAPTER_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
    "$AGENT_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
    "$APP_PATH"
else
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --identifier com.gaixianggeng.mimi.mac.tailcat \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$TAILCAT_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --identifier com.gaixianggeng.mimi.mac.claude-bridge \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$BRIDGE_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --identifier com.gaixianggeng.mimi.mac.claude-adapter \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ADAPTER_ENTITLEMENTS" \
    "$ADAPTER_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --identifier com.gaixianggeng.mimi.mac.agy-adapter \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ADAPTER_ENTITLEMENTS" \
    "$AGY_ADAPTER_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
    "$AGENT_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
    "$APP_PATH"
fi

for binary_path in "$AGENT_PATH" "$BRIDGE_PATH" "$ADAPTER_PATH" "$AGY_ADAPTER_PATH" "$TAILCAT_PATH"; do
  # --deep 不会可靠拒绝 Resources 下新增的裸 Mach-O，发布前必须直接验证。
  codesign --verify --strict --verbose=2 "$binary_path"
done

# 封包/公证前枚举 App 内全部 Mach-O 并按切片校验策略，防止以后新增内嵌二进制或坏切片漏检。
prepackage_require_team=0
prepackage_require_dev_id=0
prepackage_require_timestamp=0
if [[ "$SNAPSHOT" != "1" ]]; then
  prepackage_require_team=1
  if [[ "$DEVELOPMENT_SIGNING" != "1" ]]; then
    prepackage_require_dev_id=1
    prepackage_require_timestamp=1
  fi
fi
verify_prepackage_macho_signatures \
  "$APP_PATH" \
  "$prepackage_require_team" \
  "$prepackage_require_dev_id" \
  "$prepackage_require_timestamp"

if [[ "$APP_ONLY" == "1" ]]; then
  FINAL_APP="$OUTPUT_DIR/Mimi Remote Mac.app"
  python3 "$PUBLISHER" "$PUBLISH_MODE" "$OUTPUT_DIR" "${APP_PATH%/*}"
  echo "Mac App 快照已生成（--app-only，已验证 ${verified_macho_count} 个 Mach-O 签名）：$FINAL_APP"
  echo "注意：这是 ad-hoc 结构快照（跳过 Finder DMG 布局），不能用于真实安装或启动 macOS 后台服务。"
  exit 0
fi

DMG_ROOT="$WORK_DIR/dmg-root"
DMG_WRITABLE_PATH="$WORK_DIR/Mimi-Remote-Mac-writable.dmg"
DMG_PATH="$WORK_DIR/$DMG_NAME"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/Mimi Remote Mac.app"
ln -s /Applications "$DMG_ROOT/Applications"
mkdir -p "$DMG_ROOT/.background"
ditto "$DMG_BACKGROUND_PATH" "$DMG_ROOT/.background/dmg-background.png"

echo "==> 生成可写 DMG 并写入 Finder 拖放布局"
hdiutil create \
  -quiet \
  -volname "Mimi Remote Mac ${VERSION}" \
  -srcfolder "$DMG_ROOT" \
  -format UDRW \
  "$DMG_WRITABLE_PATH"

DMG_ATTACH_OUTPUT=""
if ! DMG_ATTACH_OUTPUT="$(hdiutil attach -readwrite -nobrowse "$DMG_WRITABLE_PATH")"; then
  echo "Mac 安装包构建失败：无法以可写模式挂载临时 DMG。" >&2
  exit 1
fi
# Finder 会把背景图保存为 alias。使用 /Volumes 下的真实卷挂载点，
# 才能让 alias 在用户之后挂载最终 DMG 时重新解析。
DMG_MOUNT_DIR="$(awk -F '\t' '$NF ~ /^\/Volumes\// { mount_path=$NF } END { print mount_path }' <<<"$DMG_ATTACH_OUTPUT")"
if [[ -z "$DMG_MOUNT_DIR" || ! -d "$DMG_MOUNT_DIR" ]]; then
  echo "Mac 安装包构建失败：无法解析临时 DMG 挂载点。" >&2
  printf '%s\n' "$DMG_ATTACH_OUTPUT" >&2
  exit 1
fi
DMG_MOUNTED=1
configure_dmg_layout "$DMG_MOUNT_DIR"
sync
detach_dmg

# App 在签名后没有再被修改；仅将写好 Finder 元数据的镜像压缩，保持签名、公证输入稳定。
hdiutil convert \
  -quiet \
  "$DMG_WRITABLE_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

if [[ "$SNAPSHOT" != "1" && "$DEVELOPMENT_SIGNING" != "1" ]]; then
  echo "==> 签名并提交 Apple Notary Service"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --timestamp \
    "$DMG_PATH"
  verify_dmg_image_signature "$DMG_PATH" "$VERIFIED_APP_TEAM_ID"
  # 主动轮询状态，避免 Xcode beta 的 notarytool --wait 在收到提交 ID 后提前退出。
  submit_and_wait_for_notarization "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

(
  cd "$WORK_DIR"
  shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)
python3 "$PUBLISHER" "$PUBLISH_MODE" "$OUTPUT_DIR" "$WORK_DIR"
FINAL_DMG="$OUTPUT_DIR/$DMG_NAME"

echo "Mac 安装包已生成：$FINAL_DMG"
if [[ "$SNAPSHOT" == "1" ]]; then
  echo "注意：这是 ad-hoc 结构快照，不能用于真实安装或启动 macOS 后台服务。"
elif [[ "$DEVELOPMENT_SIGNING" == "1" ]]; then
  echo "注意：这是同团队开发签名包，仅用于本机初始化验收；未公证，不可公开分发。"
fi
