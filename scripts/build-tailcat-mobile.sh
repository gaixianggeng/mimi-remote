#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="${TAILCAT_MOBILE_MODULE_DIR:-$REPO_ROOT/experiments/tailcat}"
DEVELOPMENT_CACHE_ROOT="$(
  bash "$REPO_ROOT/scripts/development-cache-path.sh" "go/tailcat-mobile"
)"
TOOL_DIR="${TAILCAT_MOBILE_TOOL_DIR:-$DEVELOPMENT_CACHE_ROOT/tools}"
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

production_inputs() {
  local architecture
  local template='{{if and .Module .Module.Main}}{{$dir := .Dir}}
{{range .GoFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .CgoFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .CFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .CXXFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .MFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .HFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .FFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .SFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .SysoFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{range .EmbedFiles}}{{printf "%s/%s\n" $dir .}}{{end}}
{{end}}'
  (
    cd "$MODULE_DIR"
    # 按 gomobile 的 iOS 构建标签枚举两个架构的依赖，避免测试和无关命令触发重建。
    # 外部 module 由 go.mod/go.sum 锁定；本地 package 同时跟踪原生文件和 embed 资源。
    for architecture in arm64 amd64; do
      GOOS=ios GOARCH="$architecture" CGO_ENABLED=1 "$GO_BIN" list -mod=readonly -deps -tags=ios \
        -f "$template" \
        ./mobile/tailcatmobile || exit "$?"
    done
    printf '%s\n' "$MODULE_DIR/go.mod"
    [[ ! -f "$MODULE_DIR/go.sum" ]] || printf '%s\n' "$MODULE_DIR/go.sum"
  ) | LC_ALL=C sort -u
}

source_fingerprint() (
  # 命令替换默认不继承 errexit；输入枚举或哈希失败时必须停止，不能复用不完整指纹。
  set -e
  local source_file relative_path
  local inputs
  inputs="$(production_inputs)"
  {
    printf 'schema=3\n'
    printf 'gomobile=%s\n' "$GOMOBILE_VERSION"
    "$GO_BIN" version
    (
      cd "$MODULE_DIR"
      GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" "$GO_BIN" env GOVERSION GOHOSTOS GOHOSTARCH
    )
    "$XCRUN_BIN" --sdk iphoneos --show-sdk-build-version
    "$XCRUN_BIN" --sdk iphonesimulator --show-sdk-build-version
    while IFS= read -r source_file; do
      [[ -n "$source_file" ]] || continue
      relative_path="${source_file#"$MODULE_DIR"/}"
      printf 'file=%s\n' "$relative_path"
      shasum -a 256 < "$source_file"
    done <<< "$inputs"
    shasum -a 256 < "$0"
  } | shasum -a 256 | awk '{ print $1 }'
)

build_framework() {
  # 不同 Worktree 可能要求不同工具版本；直到 bind 完成前都不能让另一构建替换工具。
  bash "$SCRIPT_DIR/development-cache-lock.sh" "$TOOL_DIR/install.lock" -- \
    bash -euo pipefail -s -- "$GO_BIN" "$TOOL_DIR/bin" "$GOMOBILE_VERSION" "$MODULE_DIR" "$1" <<'TOOLS'
go_bin="$1"
tool_bin="$2"
expected_version="$3"
tool_matches() {
  [[ -x "$tool_bin/$1" ]] || return 1
  local version
  version="$("$go_bin" version -m "$tool_bin/$1" | awk '$1 == "mod" && $2 == "golang.org/x/mobile" { print $3 }')"
  [[ "$version" == "$expected_version" ]]
}
mkdir -p "$tool_bin"
for tool in gomobile gobind; do
  if ! tool_matches "$tool"; then
    GOBIN="$tool_bin" "$go_bin" install "golang.org/x/mobile/cmd/$tool@$expected_version"
    tool_matches "$tool" || { echo "Tailcat 工具版本不匹配：$tool" >&2; exit 1; }
  fi
done
cd "$4"
"$tool_bin/gomobile" bind \
  -target=ios,iossimulator \
  -o "$5" \
  ./mobile/tailcatmobile
TOOLS
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

for command_name in "$GO_BIN" "$XCRUN_BIN" "$NM_BIN" shasum awk grep sort; do
  require_command "$command_name"
done
[[ -d "$MODULE_DIR" ]] || fail "缺少 Tailcat module：$MODULE_DIR"
[[ -f "$BRIDGE_SOURCE" ]] || fail "缺少 iOS Tailcat bridge：$BRIDGE_SOURCE"
# go list 返回规范化目录；先统一符号链接和重复斜杠，才能稳定剥离绝对路径。
MODULE_DIR="$(cd "$MODULE_DIR" && pwd -P)"

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
TEMPORARY_DIR="$(mktemp -d "$OUTPUT_DIR/.tailcat-mobile.XXXXXX")"
TEMPORARY_OUTPUT="$TEMPORARY_DIR/TailcatMobile.xcframework"
# Apple 环境由 bind 自行准备；init 还会清理全局 gomobile 目录并安装 gobind@latest。
build_framework "$TEMPORARY_OUTPUT"

framework_is_complete "$TEMPORARY_OUTPUT" \
  || fail "生成的 XCFramework 缺少必要 slice、header 或原生符号"
rm -rf "$OUTPUT"
mv "$TEMPORARY_OUTPUT" "$OUTPUT"
printf '%s\n' "$fingerprint" > "$FINGERPRINT_FILE.tmp"
mv "$FINGERPRINT_FILE.tmp" "$FINGERPRINT_FILE"
# `__has_include` 不会始终跟踪之前不存在的头文件；更新时间戳以触发下一次增量编译。
touch "$BRIDGE_SOURCE"
echo "Tailcat iOS 框架已生成：$OUTPUT"
