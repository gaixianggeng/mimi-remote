#!/usr/bin/env bash
set -euo pipefail

REQUIRE_NOTARIZATION=0
REQUIRE_TEAM_SIGNING=0
DMG_PATH=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version_at_least() {
  local actual="$1"
  local minimum="$2"
  local actual_major actual_minor actual_patch
  local minimum_major minimum_minor minimum_patch

  IFS=. read -r actual_major actual_minor actual_patch <<<"$actual"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<<"$minimum"
  if (( 10#$actual_major != 10#$minimum_major )); then
    (( 10#$actual_major > 10#$minimum_major ))
    return
  fi
  if (( 10#$actual_minor != 10#$minimum_minor )); then
    (( 10#$actual_minor > 10#$minimum_minor ))
    return
  fi
  (( 10#$actual_patch >= 10#$minimum_patch ))
}

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-macos-installer.sh [--require-team-signing] [--require-notarization] <Mimi-Remote-Mac.dmg>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarization)
      REQUIRE_NOTARIZATION=1
      REQUIRE_TEAM_SIGNING=1
      shift
      ;;
    --require-team-signing)
      REQUIRE_TEAM_SIGNING=1
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

for command_name in arch codesign file find hdiutil lipo osascript plutil shasum sips spctl strings sysctl xcrun; do
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

MOUNT_DIR=""
MOUNT_TARGET=""
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    if ! hdiutil detach "$MOUNT_TARGET" -quiet >/dev/null 2>&1; then
      # Finder 的运行态校验可能短暂占用卷；强制卸载仅针对本次只读校验挂载。
      hdiutil detach "$MOUNT_TARGET" -force -quiet >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
MOUNT_TARGET="$(awk -F '\t' '$1 ~ /^\/dev\/disk/ { device=$1; sub(/[[:space:]]+$/, "", device); print device; exit }' <<<"$ATTACH_OUTPUT")"
MOUNTED=1
MOUNT_DIR="$(awk -F '\t' '$NF ~ /^\/Volumes\// { mount_path=$NF } END { print mount_path }' <<<"$ATTACH_OUTPUT")"
if [[ -z "$MOUNT_TARGET" || -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "Mac 安装包校验失败：无法解析 DMG 挂载点。" >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi
APP_PATH="$MOUNT_DIR/Mimi Remote Mac.app"
APP_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Mimi Remote Mac"
AGENT_PATH="$APP_PATH/Contents/Resources/agentd"
BRIDGE_PATH="$APP_PATH/Contents/Resources/alleycat-claude-bridge"
TAILCAT_PATH="$APP_PATH/Contents/Resources/mimi-tailcat-experiment"
LAUNCH_AGENT_PATH="$APP_PATH/Contents/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"

if [[ ! -d "$APP_PATH" || ! -x "$AGENT_PATH" || ! -x "$BRIDGE_PATH" || ! -x "$TAILCAT_PATH" || ! -f "$LAUNCH_AGENT_PATH" ]]; then
  echo "Mac 安装包校验失败：DMG 缺少 App、agentd、Claude bridge、Tailcat 或 LaunchAgent。" >&2
  exit 1
fi
if [[ ! -L "$MOUNT_DIR/Applications" || "$(readlink "$MOUNT_DIR/Applications")" != "/Applications" ]]; then
  echo "Mac 安装包校验失败：DMG 缺少 Applications 拖放入口。" >&2
  exit 1
fi
BACKGROUND_PATH="$MOUNT_DIR/.background/dmg-background.png"
if [[ ! -f "$BACKGROUND_PATH" ]]; then
  echo "Mac 安装包校验失败：DMG 缺少 Finder 背景 PNG。" >&2
  exit 1
fi
BACKGROUND_DIMENSIONS="$(sips -g pixelWidth -g pixelHeight "$BACKGROUND_PATH")"
BACKGROUND_WIDTH="$(awk '$1 == "pixelWidth:" { print $2; exit }' <<<"$BACKGROUND_DIMENSIONS")"
BACKGROUND_HEIGHT="$(awk '$1 == "pixelHeight:" { print $2; exit }' <<<"$BACKGROUND_DIMENSIONS")"
if [[ "$BACKGROUND_WIDTH" != "660" || "$BACKGROUND_HEIGHT" != "400" ]]; then
  echo "Mac 安装包校验失败：Finder 背景必须是 660x400，实际为 ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}。" >&2
  exit 1
fi
if [[ ! -f "$MOUNT_DIR/.DS_Store" ]]; then
  echo "Mac 安装包校验失败：DMG 缺少 Finder 布局元数据 .DS_Store。" >&2
  exit 1
fi
FINDER_METADATA="$(strings -a "$MOUNT_DIR/.DS_Store")"
if [[ "$FINDER_METADATA" != *"backgroundImageAlias"* || "$FINDER_METADATA" != *"dmg-background.png"* ]]; then
  echo "Mac 安装包校验失败：Finder 布局未保存可恢复的背景图 alias。" >&2
  exit 1
fi

# 真实打开只读卷，验证 Finder 确实恢复了图标视图、窗口和位置。
if ! osascript - "$MOUNT_DIR" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  tell application "Finder"
    set mountedAlias to (POSIX file mountPath) as alias
    set mountedDisk to disk of mountedAlias
    open mountedDisk
    set dmgWindow to missing value
    try
      repeat with attempt from 1 to 20
        try
          set dmgWindow to «class cwnd» of mountedDisk
          set ignoredBounds to «class pbnd» of dmgWindow
          exit repeat
        on error errorMessage
          if attempt = 20 then error ("Finder 无法打开 DMG 窗口：" & errorMessage)
        end try
        delay 0.25
      end repeat
      if dmgWindow is missing value then error "Finder 在 5 秒内没有打开 DMG 窗口。"
      if «class pvew» of dmgWindow is not «constant ecvwicnv» then error "DMG 未使用图标视图。"
      if «class pbnd» of dmgWindow is not {100, 100, 760, 500} then error "DMG 窗口尺寸或位置不正确。"
      if position of item "Mimi Remote Mac.app" of dmgWindow is not {170, 185} then error "App 图标位置不正确。"
      if position of item "Applications" of dmgWindow is not {490, 185} then error "Applications 图标位置不正确。"
      close dmgWindow
    on error errorMessage number errorNumber
      if dmgWindow is not missing value then close dmgWindow
      error errorMessage number errorNumber
    end try
  end tell
end run
APPLESCRIPT
then
  echo "Mac 安装包校验失败：Finder 无法完整还原品牌拖放布局。" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$BRIDGE_PATH"
codesign --verify --strict --verbose=2 "$TAILCAT_PATH"
plutil -lint "$LAUNCH_AGENT_PATH" >/dev/null

if plutil -extract NSPhotoLibraryUsageDescription raw -o - "$INFO_PLIST_PATH" >/dev/null 2>&1; then
  echo "Mac 安装包校验失败：App 仍包含已移除的照片图库用途说明。" >&2
  exit 1
fi

photos_entitlement="com.apple.security.personal-information.photos-library"
for binary_path in "$APP_PATH" "$AGENT_PATH"; do
  signed_entitlements="$(codesign -d --entitlements - --xml "$binary_path" 2>/dev/null || true)"
  if grep -Fq "$photos_entitlement" <<<"$signed_entitlements"; then
    echo "Mac 安装包校验失败：${binary_path} 仍包含已移除的照片图库 entitlement。" >&2
    exit 1
  fi
done

# 运行时按 Info.plist 的 CFBundleExecutable 解析 TCC 责任进程；最终 Release 包仍只应
# 包含这个主程序，避免把 Debug/Preview dylib 或其他未预期入口带进安装产物。
main_executable_count="$(find "$APP_PATH/Contents/MacOS" -maxdepth 1 -type f -perm -111 | wc -l | tr -d " ")"
if [[ "$main_executable_count" != "1" ]]; then
  echo "Mac 安装包校验失败：Contents/MacOS 必须恰好有一个可执行文件，实际 ${main_executable_count} 个。" >&2
  exit 1
fi

# macOS 27 的前向兼容通知由 Rosetta 进程启动触发。Apple silicon 上显式选择
# arm64，避免版本探针继承调用方的翻译架构偏好，反而由发布检查制造误报。
run_native_version_probe() {
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
    /usr/bin/arch -arm64 "$@"
    return
  fi
  "$@"
}

run_native_version_probe "$AGENT_PATH" version >/dev/null
run_native_version_probe "$TAILCAT_PATH" version >/dev/null
bridge_version_output="$(run_native_version_probe "$BRIDGE_PATH" --version)"
if [[ "$bridge_version_output" =~ ^alleycat-claude-bridge[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  bridge_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
else
  echo "Mac 安装包校验失败：Claude bridge 未返回标准版本：${bridge_version_output}" >&2
  exit 1
fi

minimum_version_source="$ROOT_DIR/internal/claudebridge/version.go"
minimum_bridge_version="$(
  sed -nE 's/^[[:space:]]*MinimumVersion[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' \
    "$minimum_version_source"
)"
if [[ ! "$minimum_bridge_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Mac 安装包校验失败：无法从 agentd 源码读取 Claude bridge 最低版本。" >&2
  exit 1
fi
if ! version_at_least "$bridge_version" "$minimum_bridge_version"; then
  echo "Mac 安装包校验失败：Claude bridge ${bridge_version} 低于 agentd 要求的 ${minimum_bridge_version}。" >&2
  exit 1
fi

# 不只检查三个已知入口；后续新增的 framework、helper 或工具也必须带 arm64，
# 并声明可识别的 macOS 构建元数据，防止 x86-only 组件静默进入发布包。
macho_count=0
while IFS= read -r -d '' candidate_path; do
  candidate_kind="$(file -b "$candidate_path")"
  if [[ "$candidate_kind" != Mach-O* ]]; then
    continue
  fi

  macho_count=$((macho_count + 1))
  # codesign --deep 不会可靠拒绝 Resources 下新增的裸 Mach-O。逐个校验，避免未签名
  # sidecar 一直拖到 Apple 公证阶段才暴露。
  codesign --verify --strict --verbose=2 "$candidate_path"
  binary_archs="$(lipo -archs "$candidate_path")"
  if [[ " $binary_archs " != *" arm64 "* ]]; then
    echo "Mac 安装包校验失败：${candidate_path#"$APP_PATH"/} 是 x86-only Mach-O，缺少 arm64。" >&2
    exit 1
  fi

  reference_sdk=""
  reference_sdk_arch=""
  for binary_arch in $binary_archs; do
    build_metadata="$(xcrun vtool -arch "$binary_arch" -show-build "$candidate_path")"
    if ! grep -Eq 'platform[[:space:]]+MACOS|cmd[[:space:]]+LC_VERSION_MIN_MACOSX' <<<"$build_metadata" \
      || ! grep -Eq '(minos|version)[[:space:]]+[0-9]+' <<<"$build_metadata" \
      || ! grep -Eq 'sdk[[:space:]]+[1-9][0-9]*(\.[0-9]+)*' <<<"$build_metadata"; then
      echo "Mac 安装包校验失败：${candidate_path#"$APP_PATH"/} 的 ${binary_arch} 切片缺少可识别的 macOS 构建元数据。" >&2
      exit 1
    fi

    binary_sdk="$(awk '$1 == "sdk" { print $2; exit }' <<<"$build_metadata")"
    if [[ -z "$reference_sdk" ]]; then
      reference_sdk="$binary_sdk"
      reference_sdk_arch="$binary_arch"
    elif [[ "$binary_sdk" != "$reference_sdk" ]]; then
      echo "Mac 安装包校验失败：${candidate_path#"$APP_PATH"/} 的 ${reference_sdk_arch}/${binary_arch} SDK 不一致（${reference_sdk}/${binary_sdk}）。" >&2
      exit 1
    fi
  done
done < <(find "$APP_PATH" -type f -print0)

if [[ "$macho_count" -eq 0 ]]; then
  echo "Mac 安装包校验失败：App 内没有找到 Mach-O 产物。" >&2
  exit 1
fi

for binary_path in "$APP_EXECUTABLE_PATH" "$AGENT_PATH" "$BRIDGE_PATH" "$TAILCAT_PATH"; do
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
bridge_signing_details="$(codesign -d --verbose=4 "$BRIDGE_PATH" 2>&1)"
tailcat_signing_details="$(codesign -d --verbose=4 "$TAILCAT_PATH" 2>&1)"
# 先完整读取 codesign 输出，避免 pipefail 将 awk 提前退出造成的 SIGPIPE 误判为签名失败。
app_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$app_signing_details")"
agent_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$agent_signing_details")"
bridge_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$bridge_signing_details")"
tailcat_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$tailcat_signing_details")"
if [[ "$app_identifier" != "com.gaixianggeng.mimi.mac" \
  || "$agent_identifier" != "com.gaixianggeng.mimi.mac.agentd" \
  || "$bridge_identifier" != "com.gaixianggeng.mimi.mac.claude-bridge" \
  || "$tailcat_identifier" != "com.gaixianggeng.mimi.mac.tailcat" ]]; then
  echo "Mac 安装包校验失败：App、agentd、Claude bridge 或 Tailcat 签名 identifier 不稳定。" >&2
  exit 1
fi

app_team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$app_signing_details")"
agent_team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$agent_signing_details")"
bridge_team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$bridge_signing_details")"
tailcat_team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$tailcat_signing_details")"
if [[ "$REQUIRE_TEAM_SIGNING" == "1" ]]; then
  if [[ ! "$app_team_identifier" =~ ^[A-Z0-9]+$ \
    || "$agent_team_identifier" != "$app_team_identifier" \
    || "$bridge_team_identifier" != "$app_team_identifier" \
    || "$tailcat_team_identifier" != "$app_team_identifier" ]]; then
    echo "Mac 安装包校验失败：App、agentd、Claude bridge 与 Tailcat 必须使用同一非空 Team ID 签名。" >&2
    exit 1
  fi
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  if ! grep -Fq 'Authority=Developer ID Application:' <<<"$app_signing_details" \
    || ! grep -Fq 'Authority=Developer ID Application:' <<<"$agent_signing_details" \
    || ! grep -Fq 'Authority=Developer ID Application:' <<<"$bridge_signing_details" \
    || ! grep -Fq 'Authority=Developer ID Application:' <<<"$tailcat_signing_details"; then
    echo "Mac 安装包校验失败：App、agentd、Claude bridge 或 Tailcat 不是有效的 Developer ID Application 签名。" >&2
    exit 1
  fi
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

team_summary=""
if [[ "$REQUIRE_TEAM_SIGNING" == "1" ]]; then
  team_summary="、Team ID ${app_team_identifier} 一致"
fi
echo "Mac 安装包校验通过：已枚举 ${macho_count} 个 Mach-O，全部已签名、包含 arm64 且 macOS 构建元数据可读取；universal App、agentd、Claude bridge ${bridge_version}（要求 >= ${minimum_bridge_version}）、Tailcat、LaunchAgent、拖放入口和签名结构完整${team_summary}。"
