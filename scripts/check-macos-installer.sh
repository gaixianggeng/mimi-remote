#!/usr/bin/env bash
set -euo pipefail

REQUIRE_NOTARIZATION=0
DMG_PATH=""

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-macos-installer.sh [--require-notarization] <Mimi-Remote-Mac.dmg>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarization)
      REQUIRE_NOTARIZATION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$DMG_PATH" ]]; then
        usage >&2
        exit 2
      fi
      DMG_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  usage >&2
  exit 2
fi
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"

for command_name in codesign hdiutil lipo plutil shasum spctl xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Mac 安装包校验失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done

hdiutil verify "$DMG_PATH" >/dev/null
SHA_PATH="$DMG_PATH.sha256"
if [[ -f "$SHA_PATH" ]]; then
  (
    cd "$(dirname "$DMG_PATH")"
    shasum -a 256 -c "$(basename "$SHA_PATH")" >/dev/null
  )
fi

MOUNT_DIR="$(mktemp -d -t mimi-macos-installer-check)"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH"
MOUNTED=1
APP_PATH="$MOUNT_DIR/Mimi Remote Mac.app"
AGENT_PATH="$APP_PATH/Contents/Resources/agentd"
LAUNCH_AGENT_PATH="$APP_PATH/Contents/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"

if [[ ! -d "$APP_PATH" || ! -x "$AGENT_PATH" || ! -f "$LAUNCH_AGENT_PATH" ]]; then
  echo "Mac 安装包校验失败：DMG 缺少 App、agentd 或 LaunchAgent。" >&2
  exit 1
fi
if [[ ! -L "$MOUNT_DIR/Applications" || "$(readlink "$MOUNT_DIR/Applications")" != "/Applications" ]]; then
  echo "Mac 安装包校验失败：DMG 缺少 Applications 拖放入口。" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$LAUNCH_AGENT_PATH" >/dev/null
"$AGENT_PATH" version >/dev/null

for binary_path in "$APP_PATH/Contents/MacOS/Mimi Remote Mac" "$AGENT_PATH"; do
  binary_archs="$(lipo -archs "$binary_path")"
  for required_arch in arm64 x86_64; do
    if [[ " $binary_archs " != *" $required_arch "* ]]; then
      echo "Mac 安装包校验失败：$(basename "$binary_path") 缺少 ${required_arch}。" >&2
      exit 1
    fi
  done
done

app_signing_details="$(codesign -d --verbose=4 "$APP_PATH" 2>&1)"
agent_signing_details="$(codesign -d --verbose=4 "$AGENT_PATH" 2>&1)"
# 先完整读取 codesign 输出，避免 pipefail 将 awk 提前退出造成的 SIGPIPE 误判为签名失败。
app_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$app_signing_details")"
agent_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$agent_signing_details")"
if [[ "$app_identifier" != "com.gaixianggeng.mimi.mac" \
  || "$agent_identifier" != "com.gaixianggeng.mimi.mac.agentd" ]]; then
  echo "Mac 安装包校验失败：App 或 agentd 签名 identifier 不稳定。" >&2
  exit 1
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  if ! grep -Fq 'Authority=Developer ID Application:' <<<"$app_signing_details" \
    || ! grep -Eq '^TeamIdentifier=[A-Z0-9]+' <<<"$app_signing_details"; then
    echo "Mac 安装包校验失败：App 不是有效的 Developer ID Application 签名。" >&2
    exit 1
  fi
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

echo "Mac 安装包校验通过：universal App、agentd、LaunchAgent、拖放入口和签名结构完整。"
