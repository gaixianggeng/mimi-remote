#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/macos/MimiRemoteMac/MimiRemoteMac.xcodeproj"
SCHEME="MimiRemoteMac"
OUTPUT_DIR="$ROOT_DIR/dist-macos"
VERSION=""
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
SNAPSHOT=0

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/build-macos-installer.sh --version 0.2.0 [--build-number 1] [--output-dir dist-macos]
  bash ./scripts/build-macos-installer.sh --snapshot --version 0.2.0 [--output-dir dist-macos]

正式构建需要以下环境变量：
  MACOS_SIGN_P12             Developer ID Application 证书和私钥的 base64 PKCS#12
  MACOS_SIGN_PASSWORD        PKCS#12 导出密码
  MACOS_NOTARY_KEY           App Store Connect API .p8 文件的 base64 内容
  MACOS_NOTARY_KEY_ID        API Key ID
  MACOS_NOTARY_ISSUER_ID     App Store Connect Issuer ID

--snapshot 使用临时 ad-hoc 签名，只验证 universal App/DMG 构建，不可公开分发。
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

VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Mac 安装包构建失败：--version 必须是 X.Y.Z，例如 0.2.0。" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || [[ "$BUILD_NUMBER" == "0" ]]; then
  echo "Mac 安装包构建失败：--build-number 必须是正整数。" >&2
  exit 2
fi

for command_name in base64 codesign ditto hdiutil lipo openssl plutil security shasum spctl xcodebuild xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Mac 安装包构建失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done
if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
  echo "Mac 安装包构建失败：缺少 $PROJECT_PATH。" >&2
  exit 1
fi
if [[ "$SNAPSHOT" != "1" ]]; then
  bash "$ROOT_DIR/scripts/check-macos-release-signing.sh"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d -t mimi-macos-installer)"
KEYCHAIN_PATH=""

cleanup() {
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
if [[ ! -d "$APP_PATH" || ! -x "$AGENT_PATH" ]]; then
  echo "Mac 安装包构建失败：Release App 或内嵌 agentd 不存在。" >&2
  exit 1
fi

APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/Mimi Remote Mac")"
AGENT_ARCHS="$(lipo -archs "$AGENT_PATH")"
for required_arch in arm64 x86_64; do
  if [[ " $APP_ARCHS " != *" $required_arch "* || " $AGENT_ARCHS " != *" $required_arch "* ]]; then
    echo "Mac 安装包构建失败：App/agentd 缺少 ${required_arch}，App=${APP_ARCHS} agentd=${AGENT_ARCHS}。" >&2
    exit 1
  fi
done

CODESIGN_IDENTITY="-"
CODESIGN_TIMESTAMP=(--timestamp=none)
NOTARY_KEY_PATH=""

if [[ "$SNAPSHOT" != "1" ]]; then
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
  KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
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

  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | awk '/Developer ID Application:/ { print $2; exit }')"
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "Mac 安装包构建失败：PKCS#12 中没有 Developer ID Application 身份。" >&2
    exit 1
  fi
  CODESIGN_TIMESTAMP=(--timestamp)
fi

echo "==> 从内到外签名 agentd 与 App"
if [[ "$SNAPSHOT" == "1" ]]; then
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
DMG_PATH="$WORK_DIR/Mimi-Remote-Mac.dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/Mimi Remote Mac.app"
ln -s /Applications "$DMG_ROOT/Applications"

echo "==> 生成 DMG"
hdiutil create \
  -quiet \
  -volname "Mimi Remote Mac ${VERSION}" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

if [[ "$SNAPSHOT" != "1" ]]; then
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

FINAL_DMG="$OUTPUT_DIR/Mimi-Remote-Mac.dmg"
FINAL_SHA="$OUTPUT_DIR/Mimi-Remote-Mac.dmg.sha256"
ditto "$DMG_PATH" "$FINAL_DMG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$FINAL_DMG")" > "$(basename "$FINAL_SHA")"
)

echo "Mac 安装包已生成：$FINAL_DMG"
if [[ "$SNAPSHOT" == "1" ]]; then
  echo "注意：这是 ad-hoc 签名快照，只用于构建验证，不可公开分发。"
fi
