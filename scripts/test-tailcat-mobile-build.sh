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

module_dir="$TEMP_DIR/module"
output_dir="$TEMP_DIR/output"
tool_dir="$TEMP_DIR/tools"
bridge_source="$TEMP_DIR/MimiTailcatBridge.m"
gomobile_log="$TEMP_DIR/gomobile.log"
mkdir -p "$module_dir/mobile/tailcatmobile"
printf 'module example.invalid/tailcat\n\ngo 1.26\n' > "$module_dir/go.mod"
printf 'package tailcatmobile\n' > "$module_dir/mobile/tailcatmobile/tailcatmobile.go"
printf '#import "MimiTailcatBridge.h"\n' > "$bridge_source"
: > "$gomobile_log"

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
  bash "$ROOT_DIR/scripts/build-tailcat-mobile.sh"
}

bind_count() {
  awk '$0 == "bind" { count += 1 } END { print count + 0 }' "$gomobile_log"
}

run_builder >/dev/null
assert_equal "1" "$(bind_count)" "首次执行必须生成 XCFramework"
[[ -f "$output_dir/.tailcat-mobile-fingerprint" ]] || fail "首次执行缺少源码指纹"
[[ -x "$tool_dir/bin/gomobile" ]] || fail "首次执行没有安装固定版本的 gomobile"
[[ -x "$tool_dir/bin/gobind" ]] || fail "首次执行没有安装固定版本的 gobind"

run_builder >/dev/null
assert_equal "1" "$(bind_count)" "源码未变化时必须复用缓存"

printf '// source changed\n' >> "$module_dir/mobile/tailcatmobile/tailcatmobile.go"
run_builder >/dev/null
assert_equal "2" "$(bind_count)" "Tailcat 源码变化后必须重新生成"

rm -f "$output_dir/TailcatMobile.xcframework/ios-arm64/TailcatMobile.framework/Headers/TailcatMobile.h"
run_builder >/dev/null
assert_equal "3" "$(bind_count)" "缓存缺少 header 时必须重新生成"

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

echo "Tailcat iOS 框架生成、缓存失效和失败保留检查通过。"
