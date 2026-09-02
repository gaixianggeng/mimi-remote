#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="${TAILCAT_MOBILE_MODULE_DIR:-$REPO_ROOT/experiments/tailcat}"
TOOL_DIR="${TAILCAT_MOBILE_TOOL_DIR:-$REPO_ROOT/.build/tailcat-mobile-tools}"
OUTPUT_DIR="${TAILCAT_MOBILE_OUTPUT_DIR:-$REPO_ROOT/ios/MimiRemote/Generated}"
OUTPUT="$OUTPUT_DIR/TailcatMobile.xcframework"
FINGERPRINT_FILE="$OUTPUT_DIR/.tailcat-mobile-fingerprint"
LOCK_DIR="$OUTPUT_DIR/.tailcat-mobile.lock"
BRIDGE_SOURCE="${TAILCAT_MOBILE_BRIDGE_SOURCE:-$REPO_ROOT/ios/MimiRemote/Sources/Core/Tailcat/MimiTailcatBridge.m}"
GOMOBILE_VERSION="v0.0.0-20260821190718-4776eadac327"
GO_BIN="${TAILCAT_MOBILE_GO_BIN:-go}"
XCRUN_BIN="${TAILCAT_MOBILE_XCRUN_BIN:-xcrun}"
NM_BIN="${TAILCAT_MOBILE_NM_BIN:-nm}"
LOCK_WAIT_SECONDS="${TAILCAT_MOBILE_LOCK_WAIT_SECONDS:-300}"
TEMPORARY_DIR=""
LOCK_HELD=0

cleanup() {
  [[ -z "$TEMPORARY_DIR" ]] || rm -rf "$TEMPORARY_DIR"
  if [[ "$LOCK_HELD" == "1" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "Tailcat iOS 框架构建失败：$1" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || [[ -x "$command_name" ]] \
    || fail "缺少命令 $command_name"
}

framework_is_complete() {
  local framework_root="${1:-$OUTPUT}"
  local slice framework binary
  for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    framework="$framework_root/$slice/TailcatMobile.framework"
    binary="$framework/TailcatMobile"
    [[ -f "$framework/Headers/TailcatMobile.h" && -f "$binary" ]] || return 1
    "$NM_BIN" -g "$binary" 2>/dev/null | grep -F '_TailcatmobileStartProxy' >/dev/null \
      || return 1
  done
}

source_fingerprint() {
  local source_file relative_path
  {
    printf 'schema=2\n'
    printf 'gomobile=%s\n' "$GOMOBILE_VERSION"
    "$GO_BIN" version
    (
      cd "$MODULE_DIR"
      GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" "$GO_BIN" env GOVERSION GOHOSTOS GOHOSTARCH
    )
    "$XCRUN_BIN" --sdk iphoneos --show-sdk-build-version
    "$XCRUN_BIN" --sdk iphonesimulator --show-sdk-build-version
    while IFS= read -r source_file; do
      relative_path="${source_file#"$MODULE_DIR"/}"
      printf 'file=%s\n' "$relative_path"
      shasum -a 256 "$source_file"
    done < <(
      find "$MODULE_DIR" -type f \
        \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) \
        | LC_ALL=C sort
    )
    shasum -a 256 "$0"
  } | shasum -a 256 | awk '{ print $1 }'
}

acquire_lock() {
  local waited=0 owner_pid=""
  mkdir -p "$OUTPUT_DIR"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -f "$LOCK_DIR/pid"
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    if (( waited >= LOCK_WAIT_SECONDS )); then
      fail "等待其他 Tailcat 构建完成超时"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCK_HELD=1
}

for command_name in "$GO_BIN" "$XCRUN_BIN" "$NM_BIN" find shasum awk grep sort; do
  require_command "$command_name"
done
[[ -d "$MODULE_DIR" ]] || fail "缺少 Tailcat module：$MODULE_DIR"
[[ -f "$BRIDGE_SOURCE" ]] || fail "缺少 iOS Tailcat bridge：$BRIDGE_SOURCE"

fingerprint="$(source_fingerprint)"
if framework_is_complete && [[ "$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)" == "$fingerprint" ]]; then
  echo "Tailcat iOS 框架未变化，复用缓存：$OUTPUT"
  exit 0
fi

acquire_lock
fingerprint="$(source_fingerprint)"
if framework_is_complete && [[ "$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)" == "$fingerprint" ]]; then
  echo "Tailcat iOS 框架已由其他构建更新，复用缓存：$OUTPUT"
  exit 0
fi

mkdir -p "$TOOL_DIR/bin" "$OUTPUT_DIR"
export PATH="$TOOL_DIR/bin:$PATH"
GOBIN="$TOOL_DIR/bin" "$GO_BIN" install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
GOBIN="$TOOL_DIR/bin" "$GO_BIN" install "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"
"$TOOL_DIR/bin/gomobile" init

TEMPORARY_DIR="$(mktemp -d "$OUTPUT_DIR/.tailcat-mobile.XXXXXX")"
TEMPORARY_OUTPUT="$TEMPORARY_DIR/TailcatMobile.xcframework"
cd "$MODULE_DIR"
"$TOOL_DIR/bin/gomobile" bind \
  -target=ios,iossimulator \
  -o "$TEMPORARY_OUTPUT" \
  ./mobile/tailcatmobile

framework_is_complete "$TEMPORARY_OUTPUT" \
  || fail "生成的 XCFramework 缺少必要 slice、header 或原生符号"
rm -rf "$OUTPUT"
mv "$TEMPORARY_OUTPUT" "$OUTPUT"
printf '%s\n' "$fingerprint" > "$FINGERPRINT_FILE.tmp"
mv "$FINGERPRINT_FILE.tmp" "$FINGERPRINT_FILE"
# `__has_include` 不会始终跟踪之前不存在的头文件；更新时间戳以触发下一次增量编译。
touch "$BRIDGE_SOURCE"
echo "Tailcat iOS 框架已生成：$OUTPUT"
