#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ios/MimiRemote/MimiRemote.xcodeproj}"
SCHEME="${SCHEME:-MimiRemote}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEVICE_NAME="${DEVICE_NAME:-iPad Pro}"
DEVICE_ID="${DEVICE_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-com.gaixianggeng.mimi}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/ios/MimiRemote/build/deploy-derived}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SKIP_LAUNCH="${SKIP_LAUNCH:-0}"
REFRESH_INSTALL="${REFRESH_INSTALL:-0}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-1}"
IOS_DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"
XCODEBUILD_BIN="${IOS_XCODEBUILD_BIN:-xcodebuild}"
XCRUN_BIN="${IOS_XCRUN_BIN:-xcrun}"

if [[ "${IOS_UNIFIED_ENTRYPOINT:-0}" != "1" ]]; then
  echo "scripts/deploy-ipad.sh 是 ios-dev.sh 的内部真机执行器，不能直接调用。" >&2
  echo "日常部署请使用：bash ./scripts/ios-dev.sh run" >&2
  echo "需要刷新安装时使用：REFRESH_INSTALL=1 bash ./scripts/ios-dev.sh run" >&2
  exit 64
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "找不到 Xcode 工程：$PROJECT_PATH" >&2
  echo "如果刚改过 project.yml，请先运行：xcodegen generate --spec ios/MimiRemote/project.yml --project ios/MimiRemote" >&2
  exit 1
fi

if [[ -n "$DEVICE_ID" ]]; then
  # DEVICE_ID 优先，避免同名设备或模拟器导致目标选择不稳定。
  DEVICE_REF="$DEVICE_ID"
  DESTINATION="platform=iOS,id=$DEVICE_ID"
else
  # 默认按设备名选择真机；platform=iOS 会排除同名 Simulator。
  DEVICE_REF="$DEVICE_NAME"
  DESTINATION="platform=iOS,name=$DEVICE_NAME"
fi

PROVISIONING_ARGS=()
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  PROVISIONING_ARGS=(-allowProvisioningUpdates)
fi

SIGNING_ARGS=()
if [[ -n "$IOS_DEVELOPMENT_TEAM" ]]; then
  # 真机部署必须有开发团队。这里显式传入，避免工程重新生成后丢失 Xcode 本地签名设置。
  SIGNING_ARGS+=("DEVELOPMENT_TEAM=$IOS_DEVELOPMENT_TEAM" "CODE_SIGN_STYLE=$CODE_SIGN_STYLE")
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/MimiRemote.app"

echo "==> 构建 $SCHEME ($CONFIGURATION)"
echo "    destination: $DESTINATION"
if [[ -n "$IOS_DEVELOPMENT_TEAM" ]]; then
  echo "    development team: $IOS_DEVELOPMENT_TEAM"
fi

# macOS 系统 Bash 仍常见 3.2 版本；在 set -u 下直接展开空数组会报
# "unbound variable"。先组装成非空命令数组，避免没有签名参数时脚本提前退出。
XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)
if [[ ${#PROVISIONING_ARGS[@]} -gt 0 ]]; then
  XCODEBUILD_ARGS+=("${PROVISIONING_ARGS[@]}")
fi
if [[ ${#SIGNING_ARGS[@]} -gt 0 ]]; then
  XCODEBUILD_ARGS+=("${SIGNING_ARGS[@]}")
fi
if [[ $# -gt 0 ]]; then
  XCODEBUILD_ARGS+=("$@")
fi
XCODEBUILD_ARGS+=(build)

"$XCODEBUILD_BIN" "${XCODEBUILD_ARGS[@]}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "构建成功但找不到产物：$APP_PATH" >&2
  exit 1
fi

if [[ "$SKIP_INSTALL" == "1" ]]; then
  echo "==> 已跳过安装，真机构建产物：$APP_PATH"
  exit 0
fi

if [[ "$REFRESH_INSTALL" == "1" ]]; then
  echo "==> 刷新安装：先卸载旧 App 以清理主屏图标缓存"
  "$XCRUN_BIN" devicectl device uninstall app \
    --device "$DEVICE_REF" \
    "$BUNDLE_ID" \
    --timeout "$TIMEOUT_SECONDS" || true
fi

echo "==> 安装到设备：$DEVICE_REF"
"$XCRUN_BIN" devicectl device install app \
  --device "$DEVICE_REF" \
  "$APP_PATH" \
  --timeout "$TIMEOUT_SECONDS"

if [[ "$SKIP_LAUNCH" == "1" ]]; then
  echo "==> 已跳过启动，App 已安装：$BUNDLE_ID"
  exit 0
fi

echo "==> 启动 App：$BUNDLE_ID"
"$XCRUN_BIN" devicectl device process launch \
  --device "$DEVICE_REF" \
  --terminate-existing \
  "$BUNDLE_ID" \
  --timeout "$TIMEOUT_SECONDS"

echo "==> 完成：已构建、安装并启动 $BUNDLE_ID"
