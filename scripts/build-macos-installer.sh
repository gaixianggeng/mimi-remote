#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/build-macos-installer.sh --version 0.2.0 [--build-number 1] [--output-dir dist-macos]
  bash ./scripts/build-macos-installer.sh --snapshot --version 0.2.0 [--output-dir dist-macos]
  bash ./scripts/build-macos-installer.sh --development-signing --version 0.2.0 [--output-dir dist-macos]

正式构建需要以下环境变量：
  MACOS_SIGN_P12             Developer ID Application 证书和私钥的 base64 PKCS#12
  MACOS_SIGN_PASSWORD        PKCS#12 导出密码
  MACOS_NOTARY_KEY           App Store Connect API .p8 文件的 base64 内容
  MACOS_NOTARY_KEY_ID        API Key ID
  MACOS_NOTARY_ISSUER_ID     App Store Connect Issuer ID

--snapshot 使用临时 ad-hoc 签名，只验证 universal App/DMG 结构，不能安装运行后台服务。
--development-signing 自动使用 Keychain 中的 Apple Development 身份，生成仅供本机
初始化与 ServiceManagement 验收的同团队签名包；不做公证，不可公开分发。
EOF
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
    --development-signing)
      DEVELOPMENT_SIGNING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SNAPSHOT" == "1" && "$DEVELOPMENT_SIGNING" == "1" ]]; then
  echo "Mac 安装包构建失败：--snapshot 与 --development-signing 不能同时使用。" >&2
  exit 2
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

for command_name in base64 codesign ditto hdiutil lipo openssl osascript plutil security shasum sips spctl xcodebuild xcrun; do
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
if [[ "$SNAPSHOT" != "1" && "$DEVELOPMENT_SIGNING" != "1" ]]; then
  bash "$ROOT_DIR/scripts/check-macos-release-signing.sh"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d -t mimi-macos-installer)"
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
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

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
if [[ ! -d "$APP_PATH" || ! -x "$AGENT_PATH" || ! -x "$BRIDGE_PATH" ]]; then
  echo "Mac 安装包构建失败：Release App、内嵌 agentd 或 Claude bridge 不存在。" >&2
  exit 1
fi

APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/Mimi Remote Mac")"
AGENT_ARCHS="$(lipo -archs "$AGENT_PATH")"
BRIDGE_ARCHS="$(lipo -archs "$BRIDGE_PATH")"
for required_arch in arm64 x86_64; do
  if [[ " $APP_ARCHS " != *" $required_arch "* \
    || " $AGENT_ARCHS " != *" $required_arch "* \
    || " $BRIDGE_ARCHS " != *" $required_arch "* ]]; then
    echo "Mac 安装包构建失败：App/agentd/Claude bridge 缺少 ${required_arch}，App=${APP_ARCHS} agentd=${AGENT_ARCHS} bridge=${BRIDGE_ARCHS}。" >&2
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

echo "==> 从内到外签名 Claude bridge、agentd 与 App"
if [[ "$SNAPSHOT" == "1" || "$DEVELOPMENT_SIGNING" == "1" ]]; then
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.claude-bridge \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$BRIDGE_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
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
    --identifier com.gaixianggeng.mimi.mac.claude-bridge \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$BRIDGE_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    "$AGENT_PATH"
  codesign --force \
    --sign "$CODESIGN_IDENTITY" \
    --keychain "$KEYCHAIN_PATH" \
    --options runtime \
    "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
    "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

DMG_ROOT="$WORK_DIR/dmg-root"
DMG_WRITABLE_PATH="$WORK_DIR/Mimi-Remote-Mac-writable.dmg"
DMG_PATH="$WORK_DIR/Mimi-Remote-Mac.dmg"
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
  # 主动轮询状态，避免 Xcode beta 的 notarytool --wait 在收到提交 ID 后提前退出。
  submit_and_wait_for_notarization "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

if [[ "$DEVELOPMENT_SIGNING" == "1" ]]; then
  FINAL_DMG="$OUTPUT_DIR/Mimi-Remote-Mac-Development.dmg"
  FINAL_SHA="$OUTPUT_DIR/Mimi-Remote-Mac-Development.dmg.sha256"
else
  FINAL_DMG="$OUTPUT_DIR/Mimi-Remote-Mac.dmg"
  FINAL_SHA="$OUTPUT_DIR/Mimi-Remote-Mac.dmg.sha256"
fi
ditto "$DMG_PATH" "$FINAL_DMG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$FINAL_DMG")" > "$(basename "$FINAL_SHA")"
)

echo "Mac 安装包已生成：$FINAL_DMG"
if [[ "$SNAPSHOT" == "1" ]]; then
  echo "注意：这是 ad-hoc 结构快照，不能用于真实安装或启动 macOS 后台服务。"
elif [[ "$DEVELOPMENT_SIGNING" == "1" ]]; then
  echo "注意：这是同团队开发签名包，仅用于本机初始化验收；未公证，不可公开分发。"
fi
