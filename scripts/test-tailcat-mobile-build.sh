#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/scripts/testdata/tailcat-mobile"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-tailcat-mobile-build.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "Tailcat iOS 构建缓存测试失败：$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "${label}：期望 '$expected'，实际 '$actual'"
}

module_dir="$TEMP_DIR/module with spaces"
output_dir="$TEMP_DIR/output"
tool_dir="$TEMP_DIR/tools"
bridge_source="$TEMP_DIR/MimiTailcatBridge.m"
gomobile_log="$TEMP_DIR/gomobile.log"
install_log="$TEMP_DIR/install.log"
real_go="$(command -v go)"
builder_script="$ROOT_DIR/scripts/build-tailcat-mobile.sh"
mkdir -p "$module_dir/mobile/tailcatmobile" "$module_dir/internal/tunnel" "$module_dir/cmd/unrelated"
printf 'module example.invalid/tailcat\n\ngo 1.25\n' > "$module_dir/go.mod"
printf 'package tailcatmobile\nimport "example.invalid/tailcat/internal/tunnel"\nvar Value = tunnel.Value\n' \
  > "$module_dir/mobile/tailcatmobile/tailcatmobile.go"
printf 'package tunnel\nimport _ "embed"\n//go:embed value.txt\nvar Value string\n' \
  > "$module_dir/internal/tunnel/tunnel.go"
printf 'initial value\n' > "$module_dir/internal/tunnel/value.txt"
printf 'package main\nfunc main() {}\n' > "$module_dir/cmd/unrelated/main.go"
printf '#import "MimiTailcatBridge.h"\n' > "$bridge_source"
: > "$gomobile_log"
: > "$install_log"

run_builder() {
  TAILCAT_MOBILE_MODULE_DIR="$module_dir" \
  TAILCAT_MOBILE_OUTPUT_DIR="$output_dir" \
  TAILCAT_MOBILE_TOOL_DIR="$tool_dir" \
  TAILCAT_MOBILE_BRIDGE_SOURCE="$bridge_source" \
  TAILCAT_MOBILE_GO_BIN="$FIXTURE_DIR/fake-go.sh" \
  TAILCAT_MOBILE_XCRUN_BIN="$FIXTURE_DIR/fake-xcrun.sh" \
  TAILCAT_MOBILE_NM_BIN="$FIXTURE_DIR/fake-nm.sh" \
  TAILCAT_TEST_FAKE_GOMOBILE="$FIXTURE_DIR/fake-gomobile.sh" \
  TAILCAT_TEST_GOMOBILE_LOG="$gomobile_log" \
  TAILCAT_TEST_INSTALL_LOG="$install_log" \
  TAILCAT_TEST_REAL_GO="$real_go" \
  MIMI_DEVELOPMENT_CACHE_REPO_ROOT="$ROOT_DIR" \
  bash "$builder_script"
}

bind_count() {
  awk '$0 == "bind" { count += 1 } END { print count + 0 }' "$gomobile_log"
}

install_count() {
  wc -l < "$install_log" | tr -d ' '
}

run_builder >/dev/null
assert_equal "1" "$(bind_count)" "首次执行必须生成 XCFramework"
[[ -f "$output_dir/.tailcat-mobile-fingerprint" ]] || fail "首次执行缺少源码指纹"
[[ -x "$tool_dir/bin/gomobile" ]] || fail "首次执行没有安装固定版本的 gomobile"
[[ -x "$tool_dir/bin/gobind" ]] || fail "首次执行没有安装固定版本的 gobind"
assert_equal "2" "$(install_count)" "首次执行只安装两个固定版本工具"

run_builder >/dev/null
assert_equal "1" "$(bind_count)" "源码未变化时必须复用缓存"

printf 'package tunnel\n// new test\n' > "$module_dir/internal/tunnel/tunnel_test.go"
printf '// unrelated command changed\n' >> "$module_dir/cmd/unrelated/main.go"
run_builder >/dev/null
assert_equal "1" "$(bind_count)" "测试和无关命令变化不得重建框架"

cp -R "$module_dir" "$TEMP_DIR/relocated module"
module_dir="$TEMP_DIR/relocated module"
mkdir -p "$TEMP_DIR/relocated repo/scripts"
cp "$builder_script" "$ROOT_DIR/scripts/development-cache-path.sh" \
  "$ROOT_DIR/scripts/development-cache-lock.sh" "$TEMP_DIR/relocated repo/scripts/"
builder_script="$TEMP_DIR/relocated repo/scripts/build-tailcat-mobile.sh"
run_builder >/dev/null
assert_equal "1" "$(bind_count)" "相同源码与脚本移动目录后必须复用框架"

printf '// source changed\n' >> "$module_dir/mobile/tailcatmobile/tailcatmobile.go"
run_builder >/dev/null
assert_equal "2" "$(bind_count)" "Tailcat 源码变化后必须重新生成"
assert_equal "2" "$(install_count)" "框架失效不得重复安装已有工具"

printf '// dependency changed\n' >> "$module_dir/internal/tunnel/tunnel.go"
run_builder >/dev/null
assert_equal "3" "$(bind_count)" "生产依赖变化必须重建"
printf 'changed embedded value\n' > "$module_dir/internal/tunnel/value.txt"
run_builder >/dev/null
assert_equal "4" "$(bind_count)" "embed 输入变化必须重建"
printf '// module changed\n' >> "$module_dir/go.mod"
run_builder >/dev/null
assert_equal "5" "$(bind_count)" "module 输入变化必须重建"

export TAILCAT_TEST_SDK_VERSION=next-sdk
run_builder >/dev/null
assert_equal "6" "$(bind_count)" "SDK 变化必须重建"
export TAILCAT_TEST_GO_VERSION=go1.27.0
run_builder >/dev/null
assert_equal "7" "$(bind_count)" "Go 工具链变化必须重建"
assert_equal "2" "$(install_count)" "SDK 和编译工具链变化无需重装同版本 mobile 工具"

printf 'wrong-version\n' > "$tool_dir/bin/gobind.version"
printf '// rebuild with repaired tool\n' >> "$module_dir/internal/tunnel/tunnel.go"
run_builder >/dev/null
assert_equal "8" "$(bind_count)" "修复工具版本后正常构建"
assert_equal "3" "$(install_count)" "仅重装版本不符的工具"
rm "$tool_dir/bin/gomobile"

rm -f "$output_dir/TailcatMobile.xcframework/ios-arm64/TailcatMobile.framework/Headers/TailcatMobile.h"
run_builder >/dev/null
assert_equal "9" "$(bind_count)" "缓存缺少 header 时必须重新生成"
assert_equal "4" "$(install_count)" "仅重装缺失的工具"

set +e
TAILCAT_TEST_LIST_EXIT_CODE=92 run_builder >"$TEMP_DIR/failed-inputs.log" 2>&1
input_status=$?
set -e
assert_equal "92" "$input_status" "输入枚举失败必须中止"
assert_equal "9" "$(bind_count)" "输入枚举失败不得开始构建"

fingerprint_before="$(cat "$output_dir/.tailcat-mobile-fingerprint")"
binary_before="$(cat "$output_dir/TailcatMobile.xcframework/ios-arm64/TailcatMobile.framework/TailcatMobile")"
printf '// failing source change\n' >> "$module_dir/mobile/tailcatmobile/tailcatmobile.go"
set +e
TAILCAT_TEST_BIND_EXIT_CODE=91 run_builder >"$TEMP_DIR/failed-build.log" 2>&1
failed_status=$?
set -e
assert_equal "91" "$failed_status" "gomobile bind 失败码必须原样返回"
assert_equal "$fingerprint_before" "$(cat "$output_dir/.tailcat-mobile-fingerprint")" \
  "失败构建不得更新源码指纹"
assert_equal "$binary_before" \
  "$(cat "$output_dir/TailcatMobile.xcframework/ios-arm64/TailcatMobile.framework/TailcatMobile")" \
  "失败构建不得破坏最后一个有效 XCFramework"

run_builder >/dev/null
before="$(bind_count)"
printf '// existing test changed\n' >> "$module_dir/internal/tunnel/tunnel_test.go"
printf 'package tunnel\nconst LinuxOnly = true\n' > "$module_dir/internal/tunnel/extra_linux.go"
run_builder >/dev/null
assert_equal "$before" "$(bind_count)" "修改测试和非 iOS 输入不得重建"

printf 'package tunnel\nconst SimulatorOnly = true\n' > "$module_dir/internal/tunnel/extra_amd64.go"
run_builder >/dev/null
assert_equal "$((before + 1))" "$(bind_count)" "amd64 模拟器专用生产输入必须重建"
printf '\n' > "$module_dir/go.sum"
run_builder >/dev/null
assert_equal "$((before + 2))" "$(bind_count)" "go.sum 输入变化必须重建"

echo "Tailcat iOS 框架生成、缓存失效和失败保留检查通过。"
