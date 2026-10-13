#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_MASTER="$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-ios-marketing-1024x1024@1x.png"
DEFAULT_DARK_MASTER="$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-ios-dark-1024x1024.png"
MASTER_PATH="${1:-$DEFAULT_MASTER}"
DARK_MASTER_PATH="${2:-$DEFAULT_DARK_MASTER}"

if ! command -v sips >/dev/null 2>&1; then
  echo "缺少 macOS 系统命令：sips" >&2
  exit 1
fi

validate_master() {
  local master_path="$1"
  local metadata

  if [[ ! -f "$master_path" ]]; then
    echo "找不到 AppIcon 母图：$master_path" >&2
    exit 1
  fi
  metadata="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$master_path")"
  if [[ "$metadata" != *"pixelWidth: 1024"* || "$metadata" != *"pixelHeight: 1024"* ]]; then
    echo "AppIcon 母图必须是 1024×1024：$master_path" >&2
    exit 1
  fi
  if [[ "$metadata" != *"hasAlpha: no"* ]]; then
    echo "AppIcon 母图不能包含 Alpha 通道：$master_path" >&2
    exit 1
  fi
}

# 两版先同时校验，再写入资源，避免无效深色母图留下只更新了一半的图标。
validate_master "$MASTER_PATH"
validate_master "$DARK_MASTER_PATH"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-app-icons.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
cp "$MASTER_PATH" "$temp_dir/master.png"
cp "$DARK_MASTER_PATH" "$temp_dir/dark-master.png"

generate_icon() {
  local target_path="$1"
  local pixel_size="$2"

  mkdir -p "$(dirname "$target_path")"
  sips --resampleHeightWidth "$pixel_size" "$pixel_size" "$temp_dir/master.png" \
    --out "$target_path" >/dev/null
}

# iOS 18+ 由系统从两张 1024 母图生成所需尺寸，并按桌面图标外观选择深浅色。
ios_icon_dir="$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$temp_dir/master.png" "$ios_icon_dir/AppIcon-ios-marketing-1024x1024@1x.png"
cp "$temp_dir/dark-master.png" "$ios_icon_dir/AppIcon-ios-dark-1024x1024.png"

mac_targets=(
  "AppIconMac-16x16.png:16"
  "AppIconMac-16x16@2x.png:32"
  "AppIconMac-32x32.png:32"
  "AppIconMac-32x32@2x.png:64"
  "AppIconMac-128x128.png:128"
  "AppIconMac-128x128@2x.png:256"
  "AppIconMac-256x256.png:256"
  "AppIconMac-256x256@2x.png:512"
  "AppIconMac-512x512.png:512"
  "AppIconMac-512x512@2x.png:1024"
)
mac_icon_dirs=(
  "$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIconMac.appiconset"
  "$ROOT_DIR/macos/MimiRemoteMac/Resources/Assets.xcassets/AppIcon.appiconset"
)
for mac_icon_dir in "${mac_icon_dirs[@]}"; do
  for target in "${mac_targets[@]}"; do
    IFS=: read -r filename pixel_size <<<"$target"
    generate_icon "$mac_icon_dir/$filename" "$pixel_size"
  done
done

# Web 安装图标与原生 AppIcon 共用品牌母图，避免不同入口继续展示旧版本。
cp "$temp_dir/master.png" "$ROOT_DIR/web/assets/app-icon.png"

echo "AppIcon 已生成，浅色母图：${MASTER_PATH}；深色母图：${DARK_MASTER_PATH}"
