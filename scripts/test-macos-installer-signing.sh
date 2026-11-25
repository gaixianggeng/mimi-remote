#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STATIC_ONLY=0
TEMP_DIR=""

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/test-macos-installer-signing.sh [--static-only]

说明：
  --static-only  仅运行跨平台静态一致性与能力 JSON 解析自测（可在 Linux/macOS 的 check-packaging.sh 中执行）。
  默认           同时运行跨平台静态自测与 macOS 真实 codesign 行为防回归测试。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only)
      STATIC_ONLY=1
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

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

fail() {
  echo "Mac 安装包签名防回归测试失败：$1" >&2
  exit 1
}

run_logged() {
  local stage="$1"
  shift
  local log_file="$TEMP_DIR/run-logged.out"
  local exit_code=0
  "$@" >"$log_file" 2>&1 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    {
      echo "Mac 安装包签名防回归测试失败：[${stage}] 命令意外失败（退出码 ${exit_code}）。"
      printf '命令：'
      printf '%q ' "$@"
      printf '\n输出：\n'
      cat "$log_file"
    } >&2
    exit 1
  fi
}

check_embedded_binary_coverage() {
  local embed_script="$1"
  local build_script="$2"
  local check_script="$3"

  local embedded_list
  embedded_list="$(
    sed -nE 's/^[[:space:]]*([a-zA-Z0-9_]+)_output="\$bundle_root\/Resources\/([^"\/]+)"[[:space:]]*$/\1 \2/p' \
      "$embed_script"
  )"
  [[ -n "$embedded_list" ]] || fail "无法从 ${embed_script} 提取内嵌 Resources 二进制列表。"

  local binary_count=0
  local embed_prefix binary_name build_var check_var sign_count jit_sign_count
  while read -r embed_prefix binary_name; do
    [[ -n "$binary_name" ]] || continue
    binary_count=$((binary_count + 1))

    build_var="$(
      sed -nE "s/^[[:space:]]*([A-Z0-9_]+)=\"\\\$APP_PATH\/Contents\/Resources\/${binary_name}\"[[:space:]]*$/\1/p" \
        "$build_script" | head -n 1
    )"
    [[ -n "$build_var" ]] \
      || fail "${build_script} 缺少内嵌二进制 ${binary_name} 的路径定义（已漏出打包/签名流程）。"

    grep -Fq "lipo -archs \"\$${build_var}\"" "$build_script" \
      || fail "${build_script} 未对内嵌二进制 ${binary_name}（\$${build_var}）检查 universal 架构。"

    sign_count="$(
      awk -v target="\"\$${build_var}\"" '
        /codesign --force/ { in_sign = 1 }
        in_sign && index($0, target) > 0 { count++; in_sign = 0; next }
        in_sign && !/\\$/ { in_sign = 0 }
        END { print count + 0 }
      ' "$build_script"
    )"
    if [[ "$sign_count" -lt 2 ]]; then
      fail "${build_script} 对 ${binary_name}（\$${build_var}）的 codesign --force 次数不足（实际 ${sign_count}，期望 >= 2：Snapshot/Development 与正式 Developer ID）。"
    fi

    grep -Fq "\"\$${build_var}\"" <<<"$(grep 'for binary_path in ' "$build_script" || true)" \
      || fail "${build_script} 的显式签名验证列表缺少 ${binary_name}（\$${build_var}）。"

    # 若 embed-agentd.sh 对该二进制使用 ClaudeAdapter.entitlements（Bun 适配器），
    # 打包脚本的两个签名分支必须携带 --entitlements "$ADAPTER_ENTITLEMENTS"。
    if awk -v target="\"\$${embed_prefix}_output\"" '
      /codesign --force/ { in_sign = 1; has_ent = 0 }
      in_sign && index($0, "ClaudeAdapter.entitlements") > 0 { has_ent = 1 }
      in_sign && index($0, target) > 0 { found = has_ent; in_sign = 0; next }
      in_sign && !/\\$/ { in_sign = 0; has_ent = 0 }
      END { exit(found ? 0 : 1) }
    ' "$embed_script"; then
      jit_sign_count="$(
        awk -v target="\"\$${build_var}\"" '
          /codesign --force/ { in_sign = 1; has_ent = 0 }
          in_sign && index($0, "--entitlements \"$ADAPTER_ENTITLEMENTS\"") > 0 { has_ent = 1 }
          in_sign && index($0, target) > 0 { if (has_ent) count++; in_sign = 0; has_ent = 0; next }
          in_sign && !/\\$/ { in_sign = 0; has_ent = 0 }
          END { print count + 0 }
        ' "$build_script"
      )"
      if [[ "$jit_sign_count" -lt 2 ]]; then
        fail "${build_script} 对 Bun 适配器 ${binary_name} 的 JIT entitlements 签名次数不足（实际 ${jit_sign_count}，期望 >= 2）。"
      fi
    fi

    check_var="$(
      sed -nE "s/^[[:space:]]*([A-Z0-9_]+)=\"\\\$APP_PATH\/Contents\/Resources\/${binary_name}\"[[:space:]]*$/\1/p" \
        "$check_script" | head -n 1
    )"
    [[ -n "$check_var" ]] \
      || fail "${check_script} 缺少内嵌二进制 ${binary_name} 的路径定义。"

    grep -Fq "\"\$${check_var}\"" <<<"$(grep 'for binary_path in ' "$check_script" || true)" \
      || fail "${check_script} 的 universal 架构校验列表缺少 ${binary_name}（\$${check_var}）。"

    grep -Fq "verify_macho_slice_policy \"\$${check_var}\"" "$check_script" \
      || fail "${check_script} 未对 ${binary_name}（\$${check_var}）执行逐切片签名策略校验（Identifier / Runtime / Team ID / Developer ID）。"
  done <<<"$embedded_list"

  if [[ "$binary_count" -lt 5 ]]; then
    fail "从 ${embed_script} 提取的内嵌二进制数量异常（${binary_count} < 5）。"
  fi

  grep -Fq 'find -H "$physical_app_path" -type f -print0 > "$manifest_file"' "$build_script" \
    || fail "${build_script} 未将全量文件遍历结果写入清单并校验 find 退出状态。"
  grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' "$build_script" \
    || fail "${build_script} 未对枚举到的全部 Mach-O 执行严格签名验证。"
  grep -Fq 'codesign -d --arch "$slice_arch" --verbose=4' "$build_script" \
    || fail "${build_script} 未逐架构切片核对签名策略元数据。"

  grep -Fq 'find -H "$APP_PATH" -type f -print0 > "$manifest_file"' "$check_script" \
    || fail "${check_script} 未将全量文件遍历结果写入清单并校验 find 退出状态。"
  grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' "$check_script" \
    || fail "${check_script} 未对枚举到的全部 Mach-O 执行严格签名验证。"
  grep -Fq 'codesign -d --arch "$slice_arch" --verbose=4' "$check_script" \
    || fail "${check_script} 未逐架构切片核对签名策略元数据。"
  grep -Fq 'plistlib.loads' "$check_script" \
    || fail "${check_script} 未通过真实 plist 解析器校验布尔 true entitlements。"
  grep -Fq 'candidate_team_identifier' "$check_script" \
    || fail "${check_script} 未对枚举到的全部 Mach-O 检查 Team ID。"
  grep -Fq -- '--app-only 只能与 --snapshot 同时使用' "$build_script" \
    || fail "${build_script} 必须限制 --app-only 只能与 --snapshot 同时使用。"
  grep -Fq -- '--require-notarization 必须校验完整 DMG，不能与 --app 同时使用' "$check_script" \
    || fail "${check_script} 必须禁止 --app 绕过 --require-notarization 的完整 DMG 校验。"
  grep -Fq -- '--require-notarization 必须校验完整 DMG，不能与 --verify-app-macho-signatures 同时使用' "$check_script" \
    || fail "${check_script} 必须禁止 --verify-app-macho-signatures 接受 --require-notarization。"
}

run_capabilities_json_tests() {
  command -v python3 >/dev/null 2>&1 || fail "缺少 python3，无法执行 --capabilities JSON 解析自测。"
  local log_file="$TEMP_DIR/capabilities-json.log"

  # 合法 Antigravity 与 Claude 能力声明 -> 必过。
  printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["initialize","turn/start"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1 \
    || fail "合法 Antigravity capabilities JSON 未通过校验：$(<"$log_file")"

  printf '%s' '{"name":"mimi-claude-adapter","version":"0.3.0","methods":["initialize","turn/start"],"fullAccess":true,"claudeCode":{"minimumVersion":"2.1.294"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json claude 0.3.0 >"$log_file" 2>&1 \
    || fail "合法 Claude capabilities JSON 未通过校验：$(<"$log_file")"

  # 反例 1：坏 JSON 但包含 "turn/start" 与 "minimumVersion" 字面量 -> 必败。
  if printf '%s' '{"broken": "turn/start", "minimumVersion": "1.5.0"' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "包含字面量的非法 JSON 未被拦截。"
  fi
  grep -Fq '不是合法 JSON' "$log_file" \
    || fail "非法 JSON 报错不明确：$(<"$log_file")"

  # 反例 2：错放字段位置（"turn/start" 在描述字段，minimumVersion 在顶层而非 agy 对象内）-> 必败。
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["initialize"],"description":"turn/start","minimumVersion":"1.5.0","agy":{}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "错放 turn/start 与 minimumVersion 的 JSON 未被拦截。"
  fi

  # 反例 3：methods 含 turn/start，但 minimumVersion 放错层级（不在 agy.minimumVersion）-> 必败。
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["turn/start"],"minimumVersion":"1.5.0","agy":{}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "缺少 agy.minimumVersion 的 JSON 未被拦截。"
  fi
  grep -Fq 'agy.minimumVersion' "$log_file" \
    || fail "缺少 agy.minimumVersion 报错不明确：$(<"$log_file")"

  # 反例 4：version 与 --version 不一致 -> 必败。
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.2.0","methods":["turn/start"],"agy":{"minimumVersion":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "capabilities.version 与 --version 不一致时未被拦截。"
  fi

  # 反例 5：agy.minimumVersion 非合法版本号 -> 必败。
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["turn/start"],"agy":{"minimumVersion":"latest"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "非合法版本号的 agy.minimumVersion 未被拦截。"
  fi

  # 反例 6：Claude claudeCode.minimumVersion 放错层级 -> 必败。
  if printf '%s' '{"name":"mimi-claude-adapter","version":"0.3.0","methods":["turn/start"],"minimumVersion":"2.1.294","claudeCode":{}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json claude 0.3.0 >"$log_file" 2>&1; then
    fail "缺少 claudeCode.minimumVersion 的 JSON 未被拦截。"
  fi
}

run_static_consistency_tests() {
  check_embedded_binary_coverage \
    "$ROOT_DIR/macos/MimiRemoteMac/Scripts/embed-agentd.sh" \
    "$ROOT_DIR/scripts/build-macos-installer.sh" \
    "$ROOT_DIR/scripts/check-macos-installer.sh"

  # 变异反例：向 embed-agentd.sh 注入未加入签名列表的新内嵌二进制，校验器必须拦截。
  local mutated_embed="$TEMP_DIR/embed-agentd-mutated.sh"
  cp "$ROOT_DIR/macos/MimiRemoteMac/Scripts/embed-agentd.sh" "$mutated_embed"
  printf '\nrogue_sidecar_output="$bundle_root/Resources/mimi-rogue-sidecar"\n' >> "$mutated_embed"
  local mutation_log="$TEMP_DIR/static-mutation.log"
  if (
    check_embedded_binary_coverage \
      "$mutated_embed" \
      "$ROOT_DIR/scripts/build-macos-installer.sh" \
      "$ROOT_DIR/scripts/check-macos-installer.sh"
  ) >"$mutation_log" 2>&1; then
    fail "静态一致性变异用例未拦截漏出签名列表的 mimi-rogue-sidecar。"
  fi
  grep -Fq 'mimi-rogue-sidecar' "$mutation_log" \
    || fail "静态一致性变异用例报错未指出遗漏的 mimi-rogue-sidecar：$(<"$mutation_log")"

  run_capabilities_json_tests

  echo "Mac 安装包签名静态一致性与能力 JSON 自测通过（含漏签变异与非法 JSON 反例）。"
}

build_controlled_sample_machos() {
  local out_dir="$1"
  local src_file="$out_dir/sample.c"
  cat > "$src_file" <<'C_SRC'
static volatile const char kPayload[] = "MIMI_SIGNING_TEST_PAYLOAD_0123456789";

int main(void) {
  return kPayload[0] == 0 ? 1 : 0;
}
C_SRC

  run_logged "编译受控 arm64 Mach-O 样例" \
    xcrun clang -arch arm64 -O0 "$src_file" -o "$out_dir/sample-arm64"
  run_logged "编译受控 x86_64 Mach-O 样例" \
    xcrun clang -arch x86_64 -O0 "$src_file" -o "$out_dir/sample-x86_64"
  run_logged "合成受控 universal Mach-O 样例" \
    lipo -create "$out_dir/sample-arm64" "$out_dir/sample-x86_64" -output "$out_dir/sample-universal"

  [[ "$(file -b "$out_dir/sample-universal")" == Mach-O* ]] \
    || fail "编译生成的 sample-universal 不是 Mach-O。"
}

tamper_payload_in_binary() {
  local binary_path="$1"
  run_logged "精确篡改已签名 Mach-O 的受保护常量负载（${binary_path}）" \
    python3 - "$binary_path" <<'PY'
import sys

path = sys.argv[1]
needle = b"MIMI_SIGNING_TEST_PAYLOAD_0123456789"
replacement = b"MIMI_SIGNING_TEST_TAMPERE_9876543210"
assert len(needle) == len(replacement)

with open(path, "r+b") as fh:
    data = fh.read()
    offsets = []
    start = 0
    while True:
        idx = data.find(needle, start)
        if idx == -1:
            break
        offsets.append(idx)
        start = idx + len(needle)
    if not offsets:
        print(f"未在 {path} 中找到目标负载常量。", file=sys.stderr)
        sys.exit(1)
    for offset in offsets:
        fh.seek(offset)
        fh.write(replacement)
PY
}

write_entitlements_plist() {
  local plist_path="$1"
  local allow_jit_xml="$2"
  local allow_unsigned_xml="$3"
  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key>
  ${allow_jit_xml}
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  ${allow_unsigned_xml}
</dict>
</plist>
PLIST
}

create_test_app_bundle() {
  local app_dir="$1"
  local sample_macho="$2"

  rm -rf -- "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
  cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>TestApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.gaixianggeng.mimi.mac.signing-test</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>TestApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST

  run_logged "复制主测试二进制" cp "$sample_macho" "$app_dir/Contents/MacOS/TestApp"
  run_logged "设置主测试二进制权限" chmod 0755 "$app_dir/Contents/MacOS/TestApp"
  run_logged "复制测试 helper 二进制" cp "$sample_macho" "$app_dir/Contents/Resources/helper-signed"
  run_logged "设置测试 helper 权限" chmod 0755 "$app_dir/Contents/Resources/helper-signed"

  run_logged "基线签名 helper-signed" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.helper \
      --options runtime --timestamp=none \
      "$app_dir/Contents/Resources/helper-signed"
  run_logged "基线签名 Test.app" \
    codesign --force --sign - \
      --options runtime --timestamp=none \
      "$app_dir"
}

run_macos_codesign_tests() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "真实 codesign 行为测试只能在 macOS (Darwin) 上运行；非 macOS 环境请传 --static-only。"
  fi
  for command_name in chmod codesign cp file lipo ln mktemp plutil python3 xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少 macOS 测试命令 ${command_name}。"
  done

  local sample_dir="$TEMP_DIR/samples"
  mkdir -p "$sample_dir"
  build_controlled_sample_machos "$sample_dir"

  local sample_universal="$sample_dir/sample-universal"
  local sample_arm64="$sample_dir/sample-arm64"
  local sample_x86_64="$sample_dir/sample-x86_64"
  local app_dir="$TEMP_DIR/Test.app"
  local test_log="$TEMP_DIR/codesign-test.log"

  # 1. 基线：受控编译的 universal App 与 helper 均正确签名 -> checker 与 builder 封包前校验均必过。
  create_test_app_bundle "$app_dir" "$sample_universal"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "合法签名的测试 App 未通过 checker 校验：$(<"$test_log")"
  local baseline_summary
  baseline_summary="$(cat "$test_log")"
  bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1 \
    || fail "合法签名的测试 App 未通过 builder 封包前校验：$(<"$test_log")"

  # 2. P2-4：目录符号链接指向 .app 与真实路径等价（并抗 CDPATH 污染）。
  local symlink_app="$TEMP_DIR/Symlinked.app"
  run_logged "创建 .app 目录符号链接" ln -s "$app_dir" "$symlink_app"
  CDPATH="/" bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$symlink_app" >"$test_log" 2>&1 \
    || fail "通过符号链接传入 .app 校验失败：$(<"$test_log")"
  local symlink_summary
  symlink_summary="$(cat "$test_log")"
  [[ "$symlink_summary" == "$baseline_summary" ]] \
    || fail "符号链接路径与真实路径的校验结果不一致（真实：${baseline_summary}；链接：${symlink_summary}）。"
  CDPATH="/" bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$symlink_app" >"$test_log" 2>&1 \
    || fail "builder --verify-only 通过符号链接传入 .app 校验失败：$(<"$test_log")"

  # 3. 复现 v1.1.16 故障：精确篡改已签名二进制的受保护常量负载，先用 codesign --verify 确认其确实失效，
  # 即使重新 seal 了主 App，checker 与 builder 封包前校验仍必须拒绝；重签修复后均必过。
  local leaky_bin="$app_dir/Contents/Resources/mimi-leaky-adapter"
  run_logged "复制损坏签名样例" cp "$sample_universal" "$leaky_bin"
  run_logged "设置损坏签名样例权限" chmod 0755 "$leaky_bin"
  run_logged "初签损坏签名样例" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.leaky \
      --options runtime --timestamp=none \
      "$leaky_bin"
  tamper_payload_in_binary "$leaky_bin"
  [[ "$(file -b "$leaky_bin")" == Mach-O* ]] \
    || fail "篡改测试样例后无法继续识别为 Mach-O。"
  if codesign --verify --strict "$leaky_bin" >"$test_log" 2>&1; then
    fail "篡改常量负载后 codesign --verify --strict 仍返回 0，损坏样例未生效。"
  fi
  run_logged "仅重封主 App（模拟漏重签侧车）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "包含损坏签名内嵌 Mach-O 的 App 被 checker 放行。"
  fi
  grep -Fq 'mimi-leaky-adapter' "$test_log" \
    || fail "损坏签名用例 checker 失败输出未包含 mimi-leaky-adapter：$(<"$test_log")"
  grep -Eq 'invalid signature|failed strict validation' "$test_log" \
    || fail "损坏签名用例 checker 失败输出未包含签名校验失败原因：$(<"$test_log")"

  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "包含损坏签名内嵌 Mach-O 的 App 被 builder 封包前校验放行。"
  fi
  grep -Fq 'mimi-leaky-adapter' "$test_log" \
    || fail "损坏签名用例 builder 失败输出未包含 mimi-leaky-adapter：$(<"$test_log")"

  run_logged "修复重签 mimi-leaky-adapter" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.leaky \
      --options runtime --timestamp=none \
      "$leaky_bin"
  run_logged "修复后重封主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "修复损坏签名内嵌 Mach-O 后 checker 仍校验失败：$(<"$test_log")"
  bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1 \
    || fail "修复损坏签名内嵌 Mach-O 后 builder 仍校验失败：$(<"$test_log")"

  # 4. 完全未签名的内嵌 Mach-O -> checker 与 builder 均必败；补签并重封主 App 后均必过。
  local unsigned_bin="$app_dir/Contents/Resources/mimi-unsigned-sidecar"
  run_logged "复制未签名样例" cp "$sample_universal" "$unsigned_bin"
  run_logged "设置未签名样例权限" chmod 0755 "$unsigned_bin"
  run_logged "移除未签名样例的签名" codesign --remove-signature "$unsigned_bin"
  if codesign --verify --strict "$unsigned_bin" >"$test_log" 2>&1; then
    fail "移除签名后 codesign --verify --strict 仍返回 0，未签名样例构造失败。"
  fi
  run_logged "重封含未签名侧车的主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "包含未签名内嵌 Mach-O 的 App 被 checker 放行。"
  fi
  grep -Fq 'mimi-unsigned-sidecar' "$test_log" \
    || fail "未签名用例 checker 失败输出未包含 mimi-unsigned-sidecar：$(<"$test_log")"

  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "包含未签名内嵌 Mach-O 的 App 被 builder 放行。"
  fi
  grep -Fq 'mimi-unsigned-sidecar' "$test_log" \
    || fail "未签名用例 builder 失败输出未包含 mimi-unsigned-sidecar：$(<"$test_log")"

  run_logged "补签 mimi-unsigned-sidecar" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.unsigned \
      --options runtime --timestamp=none \
      "$unsigned_bin"
  run_logged "补签后重封主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "补签未签名内嵌 Mach-O 后 checker 仍校验失败：$(<"$test_log")"

  # 5. P1-3：JIT entitlements 校验必须用真实 plist 解析器，严格要求布尔 true（拒绝 <false/> 与 <string>true</string>）。
  local agy_bin="$app_dir/Contents/Resources/mimi-agy-adapter"
  local bad_ent_false="$TEMP_DIR/ent-false.plist"
  local bad_ent_string="$TEMP_DIR/ent-string.plist"
  local bad_ent_mem_false="$TEMP_DIR/ent-mem-false.plist"
  write_entitlements_plist "$bad_ent_false" "<false/>" "<true/>"
  write_entitlements_plist "$bad_ent_string" "<string>true</string>" "<true/>"
  write_entitlements_plist "$bad_ent_mem_false" "<true/>" "<false/>"

  run_logged "复制 mimi-agy-adapter 测试样例" cp "$sample_universal" "$agy_bin"
  run_logged "设置 mimi-agy-adapter 权限" chmod 0755 "$agy_bin"

  run_logged "给 mimi-agy-adapter 签入 allow-jit=<false/>" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_false" \
      "$agy_bin"
  run_logged "重封主 App（allow-jit=false 用例）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "allow-jit=<false/> 的 mimi-agy-adapter 被放行。"
  fi
  grep -Fq 'com.apple.security.cs.allow-jit' "$test_log" \
    || fail "allow-jit=<false/> 报错未指出缺失/非真键名：$(<"$test_log")"

  run_logged "给 mimi-agy-adapter 签入 allow-jit=<string>true</string>" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_string" \
      "$agy_bin"
  run_logged "重封主 App（allow-jit=string 用例）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "allow-jit=<string>true</string> 的 mimi-agy-adapter 被放行。"
  fi
  grep -Fq '必须为布尔 true' "$test_log" \
    || fail "字符串 true 报错未指出必须为布尔 true：$(<"$test_log")"

  run_logged "给 mimi-agy-adapter 签入 allow-unsigned-executable-memory=<false/>" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_mem_false" \
      "$agy_bin"
  run_logged "重封主 App（allow-unsigned-executable-memory=false 用例）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "allow-unsigned-executable-memory=<false/> 的 mimi-agy-adapter 被放行。"
  fi
  grep -Fq 'com.apple.security.cs.allow-unsigned-executable-memory' "$test_log" \
    || fail "allow-unsigned-executable-memory=<false/> 报错不准确：$(<"$test_log")"

  run_logged "给 mimi-agy-adapter 签入正式 ClaudeAdapter.entitlements" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements" \
      "$agy_bin"
  run_logged "重封主 App（合法 JIT entitlements）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "合法 JIT entitlements 的 mimi-agy-adapter 未通过校验：$(<"$test_log")"

  # 6. P2-1：lipo -create 拼接两个不同签名切片（arm64 带 runtime，x86_64 无 runtime）-> 必拒。
  local mixed_arm64="$TEMP_DIR/mixed-arm64"
  local mixed_x86_64="$TEMP_DIR/mixed-x86_64"
  local mixed_bin="$app_dir/Contents/Resources/mimi-mixed-slices"
  run_logged "准备混合切片 arm64" cp "$sample_arm64" "$mixed_arm64"
  run_logged "准备混合切片 x86_64" cp "$sample_x86_64" "$mixed_x86_64"
  run_logged "签名混合切片 arm64（带 runtime）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.mixed \
      --options runtime --timestamp=none \
      "$mixed_arm64"
  run_logged "签名混合切片 x86_64（无 runtime、异 identifier）" \
    codesign --force --sign - \
      --identifier com.example.rogue.x86 \
      --timestamp=none \
      "$mixed_x86_64"
  run_logged "拼接混合签名 universal 二进制" \
    lipo -create "$mixed_arm64" "$mixed_x86_64" -output "$mixed_bin"
  run_logged "设置混合签名二进制权限" chmod 0755 "$mixed_bin"
  run_logged "重封含混合签名切片的主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "混合签名切片（x86_64 缺少 runtime）被 checker 放行。"
  fi
  grep -Fq 'mimi-mixed-slices' "$test_log" \
    || fail "混合签名切片 checker 报错缺少文件名：$(<"$test_log")"
  grep -Fq 'x86_64' "$test_log" \
    || fail "混合签名切片 checker 报错未指出问题切片 x86_64：$(<"$test_log")"

  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "混合签名切片（x86_64 缺少 runtime）被 builder 封包前校验放行。"
  fi
  grep -Fq 'x86_64' "$test_log" \
    || fail "混合签名切片 builder 报错未指出问题切片 x86_64：$(<"$test_log")"

  run_logged "统一重签 mimi-mixed-slices 全部切片" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.mixed \
      --options runtime --timestamp=none \
      "$mixed_bin"
  run_logged "重封主 App（混合切片修复后）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "统一重签混合切片后 checker 仍校验失败：$(<"$test_log")"
  bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1 \
    || fail "统一重签混合切片后 builder 仍校验失败：$(<"$test_log")"

  # 7. P2-2：find 输出部分路径后退出 1 -> checker 与 builder 均必须拒绝，绝不假通过。
  local fake_find_dir="$TEMP_DIR/fake-find-bin"
  mkdir -p "$fake_find_dir"
  cat > "$fake_find_dir/find" <<'FIND_STUB'
#!/usr/bin/env bash
set -euo pipefail
# 只输出主可执行文件（已合法签名）后返回 1，模拟遍历中段权限/IO 失败。
printf '%s\0' "${TEST_PARTIAL_MACHO}"
exit 1
FIND_STUB
  run_logged "设置 fake find 权限" chmod 0755 "$fake_find_dir/find"

  if PATH="$fake_find_dir:$PATH" TEST_PARTIAL_MACHO="$app_dir/Contents/MacOS/TestApp" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "find 部分输出后返回 1 时 checker 误报通过。"
  fi
  grep -Fq 'find 失败' "$test_log" \
    || fail "find 失败时 checker 报错不准确：$(<"$test_log")"

  if PATH="$fake_find_dir:$PATH" TEST_PARTIAL_MACHO="$app_dir/Contents/MacOS/TestApp" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "find 部分输出后返回 1 时 builder 误报通过。"
  fi
  grep -Fq 'find 失败' "$test_log" \
    || fail "find 失败时 builder 报错不准确：$(<"$test_log")"

  # 8. P2-3：--verify-app-macho-signatures 与 --app 都必须拒绝 --require-notarization。
  local opt_exit=0
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-notarization "$app_dir" >"$test_log" 2>&1 || opt_exit=$?
  [[ "$opt_exit" -eq 2 ]] \
    || fail "--verify-app-macho-signatures --require-notarization 应以退出码 2 拒绝（实际 ${opt_exit}）：$(<"$test_log")"
  grep -Fq -- '--require-developer-id' "$test_log" \
    || fail "--verify-app-macho-signatures --require-notarization 拒绝提示应引导使用 --require-developer-id：$(<"$test_log")"

  opt_exit=0
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --app --require-notarization "$app_dir" >"$test_log" 2>&1 || opt_exit=$?
  [[ "$opt_exit" -eq 2 ]] \
    || fail "--app --require-notarization 应以退出码 2 拒绝（实际 ${opt_exit}）：$(<"$test_log")"

  # 9. P1-1 / P2-1 / P2-3 / P2-7：ad-hoc、有效 ad-hoc 漏签 sidecar、逐切片 Team ID / Developer ID / Timestamp 校验。
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "ad-hoc 签名在 checker --require-team-signing 下被放行。"
  fi
  grep -Fq '缺少有效的非空 Team ID' "$test_log" \
    || fail "checker --require-team-signing 未报告主 App 缺少有效 Team ID：$(<"$test_log")"

  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$app_dir" >"$test_log" 2>&1; then
    fail "ad-hoc 签名在 builder --verify-only --development-signing 下被放行。"
  fi
  grep -Fq '缺少有效的非空 Team ID' "$test_log" \
    || fail "builder --verify-only --development-signing 未报告主 App 缺少有效 Team ID：$(<"$test_log")"

  # 构造真实有效 ad-hoc 签名的漏签侧车（已重新 seal 主 App）：
  # fake codesign 对 mimi-rogue-adhoc 直接透传真实 /usr/bin/codesign 输出，验证正式策略必拒真实有效 ad-hoc 侧车。
  local rogue_adhoc_bin="$app_dir/Contents/Resources/mimi-rogue-adhoc"
  run_logged "复制有效 ad-hoc 漏签侧车" cp "$sample_universal" "$rogue_adhoc_bin"
  run_logged "设置有效 ad-hoc 漏签侧车权限" chmod 0755 "$rogue_adhoc_bin"
  run_logged "给漏签侧车做合法 ad-hoc + runtime 签名" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.rogue-adhoc \
      --options runtime --timestamp=none \
      "$rogue_adhoc_bin"
  run_logged "重封主 App（含合法 ad-hoc 漏签侧车）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  # --verify 与 --entitlements 始终走真实 /usr/bin/codesign；仅对 -d --arch <arch> --verbose=4 按用例注入受控切片元数据。
  local fake_bin_dir="$TEMP_DIR/fake-bin"
  mkdir -p "$fake_bin_dir"
  cat > "$fake_bin_dir/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--arch" && "${4:-}" == "--verbose=4" ]]; then
  arch="${3:-}"
  target="${5:-}"
  if [[ "$target" == *"mimi-rogue-adhoc" && "${TEST_PASSTHROUGH_ROGUE_ADHOC:-0}" == "1" ]]; then
    exec /usr/bin/codesign "$@"
  fi
  if [[ -n "${TEST_LEAKY_TARGET_ARCH:-}" && "$target" == *"mimi-leaky-adapter" && "$arch" == "$TEST_LEAKY_TARGET_ARCH" ]]; then
    printf 'Executable=%s\n' "$target"
    printf 'Identifier=com.gaixianggeng.mimi.mac.signing-test.leaky\n'
    printf 'Format=Mach-O thin (%s)\n' "$arch"
    printf 'CodeDirectory v=20500 size=401 flags=0x10000(runtime) hashes=2+7 location=embedded\n'
    if [[ -n "${TEST_LEAKY_AUTHORITY:-}" ]]; then
      printf 'Authority=%s\n' "$TEST_LEAKY_AUTHORITY"
    fi
    if [[ -n "${TEST_LEAKY_TIMESTAMP:-}" ]]; then
      printf 'Timestamp=%s\n' "$TEST_LEAKY_TIMESTAMP"
    fi
    printf 'TeamIdentifier=%s\n' "${TEST_LEAKY_TEAM:-not set}"
    exit 0
  fi
  printf 'Executable=%s\n' "$target"
  printf 'Identifier=com.gaixianggeng.mimi.mac.signing-test\n'
  printf 'Format=Mach-O thin (%s)\n' "$arch"
  printf 'CodeDirectory v=20500 size=401 flags=0x10000(runtime) hashes=2+7 location=embedded\n'
  printf 'Authority=Developer ID Application: Mimi Test (TEAM123456)\n'
  printf 'Timestamp=Nov 17, 2026 at 19:12:30\n'
  printf 'TeamIdentifier=TEAM123456\n'
  exit 0
fi
exec /usr/bin/codesign "$@"
STUB
  run_logged "设置 fake codesign 权限" chmod 0755 "$fake_bin_dir/codesign"

  # 9a. 有效 ad-hoc 漏签 sidecar 在正式/开发策略下必被 checker 和 builder 拒绝并指出文件名。
  if PATH="$fake_bin_dir:$PATH" TEST_PASSTHROUGH_ROGUE_ADHOC=1 \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "有效 ad-hoc 漏签 sidecar 在 checker --require-team-signing 下被放行。"
  fi
  grep -Fq 'mimi-rogue-adhoc' "$test_log" \
    || fail "有效 ad-hoc 漏签 sidecar checker --require-team-signing 报错缺少文件名：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_PASSTHROUGH_ROGUE_ADHOC=1 \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1; then
    fail "有效 ad-hoc 漏签 sidecar 在 checker --require-developer-id 下被放行。"
  fi
  grep -Fq 'mimi-rogue-adhoc' "$test_log" \
    || fail "有效 ad-hoc 漏签 sidecar checker --require-developer-id 报错缺少文件名：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_PASSTHROUGH_ROGUE_ADHOC=1 \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$app_dir" >"$test_log" 2>&1; then
    fail "有效 ad-hoc 漏签 sidecar 在 builder --verify-only --development-signing 下被放行。"
  fi
  grep -Fq 'mimi-rogue-adhoc' "$test_log" \
    || fail "有效 ad-hoc 漏签 sidecar builder --development-signing 报错缺少文件名：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_PASSTHROUGH_ROGUE_ADHOC=1 \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1; then
    fail "有效 ad-hoc 漏签 sidecar 在 builder 正式策略 --verify-only 下被放行。"
  fi
  grep -Fq 'mimi-rogue-adhoc' "$test_log" \
    || fail "有效 ad-hoc 漏签 sidecar builder 正式策略报错缺少文件名：$(<"$test_log")"

  # 移除临时 rogue-adhoc 并重封主 App，继续测切片级 Team ID / Developer ID / Timestamp 策略。
  rm -f -- "$rogue_adhoc_bin"
  run_logged "移除 rogue-adhoc 后重封主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  # 9b. 仅 x86_64 切片残留第三方 Team ID（arm64 切片为己方 TEAM123456）-> 逐片校验必须拒绝。
  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="7FRXF46ZSN" \
    TEST_LEAKY_AUTHORITY="Developer ID Application: Upstream (7FRXF46ZSN)" TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "仅 x86_64 切片带第三方 Team ID 时 checker 未拦截。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）的 Team ID' "$test_log" \
    || fail "第三方 Team ID 切片报错不准确：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="7FRXF46ZSN" \
    TEST_LEAKY_AUTHORITY="Developer ID Application: Upstream (7FRXF46ZSN)" TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$app_dir" >"$test_log" 2>&1; then
    fail "仅 x86_64 切片带第三方 Team ID 时 builder 未拦截。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）的 Team ID' "$test_log" \
    || fail "builder 第三方 Team ID 切片报错不准确：$(<"$test_log")"

  # 9c. 同 Team ID 但 x86_64 切片为 Apple Development -> --require-team-signing 必过，--require-developer-id 与 builder 正式策略必拒。
  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Apple Development: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1 \
    || fail "同 Team ID 的开发签名应通过 checker --require-team-signing：$(<"$test_log")"

  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Apple Development: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$app_dir" >"$test_log" 2>&1 \
    || fail "同 Team ID 的开发签名应通过 builder --verify-only --development-signing：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Apple Development: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1; then
    fail "非 Developer ID Application 签名在 checker --require-developer-id 下被放行。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）不是有效的 Developer ID Application 签名' "$test_log" \
    || fail "Developer ID 校验报错不准确：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Apple Development: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1; then
    fail "非 Developer ID Application 签名在 builder 正式策略下被放行。"
  fi

  # 9d. 同 Team ID 且为 Developer ID Application，但 x86_64 切片 Timestamp=none -> 必拒。
  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Developer ID Application: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="none" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1; then
    fail "Timestamp=none 在 checker --require-developer-id 下被放行。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）缺少有效的安全时间戳' "$test_log" \
    || fail "Timestamp=none 校验报错不准确：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Developer ID Application: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="none" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1; then
    fail "Timestamp=none 在 builder 正式策略下被放行。"
  fi

  # 9e. 全部 Mach-O 全部切片同 Team ID + Developer ID Application + 有效 Timestamp -> checker 与 builder 均必过。
  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Developer ID Application: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1 \
    || fail "全部 Mach-O 具备同 Team ID Developer ID 与安全时间戳时应通过 checker --require-developer-id：$(<"$test_log")"

  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_AUTHORITY="Developer ID Application: Mimi Test (TEAM123456)" TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1 \
    || fail "全部 Mach-O 具备同 Team ID Developer ID 与安全时间戳时应通过 builder 正式策略：$(<"$test_log")"

  echo "Mac 安装包真实 codesign 防回归测试通过（受控编译样例、符号链接、损坏/未签名、JIT entitlements 布尔校验、混合切片、find 失败、选项边界、有效 ad-hoc 漏签与 builder/checker 逐片策略全覆盖）。"
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-signing-test.XXXXXX")"
run_static_consistency_tests
if [[ "$STATIC_ONLY" != "1" ]]; then
  run_macos_codesign_tests
fi
