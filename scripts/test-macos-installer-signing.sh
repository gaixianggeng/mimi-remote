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
  local signing_policy="$ROOT_DIR/scripts/macos-installer-signing.sh"

  local embedded_list
  embedded_list="$(
    sed -nE 's/^[[:space:]]*([a-zA-Z0-9_]+)_output="\$\{?bundle_root\}?\/Resources\/([^"\/]+)"[[:space:]]*$/\1 \2/p' \
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

    grep -Fq "Contents/Resources/${binary_name}|com.gaixianggeng.mimi.mac." "$signing_policy" \
      || fail "共用固定入口校验缺少 ${binary_name} 的签名标识符。"
  done <<<"$embedded_list"

  if [[ "$binary_count" -lt 5 ]]; then
    fail "从 ${embed_script} 提取的内嵌二进制数量异常（${binary_count} < 5）。"
  fi

  grep -Fq 'verify_present_macos_fixed_machos "$APP_PATH"' "$check_script" \
    || fail "${check_script} 没有直接校验固定入口的切片签名策略。"
  grep -Fq 'verify_present_macos_fixed_machos "$physical_app_path"' "$build_script" \
    || fail "${build_script} 没有直接校验固定入口的切片签名策略。"
  grep -Fq 'verify_macho_slice_policy "$app/$path" "$path" "${entry#*|}"' "$signing_policy" \
    || fail "固定入口校验没有按固定路径和标识符调用逐切片签名策略。"

  grep -Fq 'find -H "$physical_app_path" -type f -print0 > "$manifest_file"' "$build_script" \
    || fail "${build_script} 未将全量文件遍历结果写入清单并校验 find 退出状态。"
  grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' "$build_script" \
    || fail "${build_script} 未对枚举到的全部 Mach-O 执行严格签名验证。"
  grep -Fq 'verify_macho_slice_policy \' "$build_script" \
    || fail "${build_script} 未逐架构切片核对签名策略元数据。"

  grep -Fq 'find -H "$APP_PATH" -type f -print0 > "$manifest_file"' "$check_script" \
    || fail "${check_script} 未将全量文件遍历结果写入清单并校验 find 退出状态。"
  grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' "$check_script" \
    || fail "${check_script} 未对枚举到的全部 Mach-O 执行严格签名验证。"
  grep -Fq 'verify_macho_slice_policy \' "$check_script" \
    || fail "${check_script} 未逐架构切片核对签名策略元数据。"
  grep -Fq 'read_codesign_details "$target" "$label" --arch "$slice_arch"' "$signing_policy" \
    || fail "共用签名策略未逐架构切片读取签名元数据。"
  grep -Fq 'verify_codesign_identifier "$target" "$label" "$details" "$expected_identifier" --arch "$slice_arch"' "$signing_policy" \
    || fail "共用签名策略未逐架构切片精确校验 identifier。"
  grep -Fq 'verify_codesign_team_id "$target" "$label" "$details" "$resolved_team" --arch "$slice_arch"' "$signing_policy" \
    || fail "共用签名策略未逐架构切片校验证书 Team ID。"
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

  printf '%s' '{"NAME":"mimi-agy-adapter","VERSION":"0.1.0","METHODS":["turn/start"],"FULLACCESS":true,"AGY":{"MINIMUMVERSION":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1 \
    || fail "Go 可匹配的大写键名被误拒：$(<"$log_file")"
  printf '%s' '{"VERSION":"0.3.0","METHODſ":["turn/start"],"CLAUDECODE":{"MINIMUMVERSION":"2.1.294"},"fullacceß":"ignored"}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json claude 0.3.0 >"$log_file" 2>&1 \
    || fail "Go SimpleFold 字段匹配不一致：$(<"$log_file")"

  local replacement_methods
  for replacement_methods in '[]' '["initialize"]'; do
    if printf '{"version":"0.1.0","methods":["turn/start"],"Methods":%s,"agy":{"minimumVersion":"1.5.0"}}' "$replacement_methods" \
      | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
      fail "大小写变体 Methods 可覆盖 turn/start，必须拒绝。"
    fi
    grep -Fq '拒绝重复声明' "$log_file" || fail "重复 Methods 报错不明确：$(<"$log_file")"
  done
  if printf '%s' '{"version":"0.3.0","methods":["turn/start"],"claudeCode":{"minimumVersion":"2.1.294","MINIMUMVERSION":"latest"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json claude 0.3.0 >"$log_file" 2>&1; then
    fail "允许大小写变体覆盖 minimumVersion。"
  fi

  if printf '%s\377' '{"version":"0.1.0","methods":["turn/start"],"agy":{"minimumVersion":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "未拒绝非法 UTF-8 字节。"
  fi
  grep -Fq '不是合法 UTF-8 JSON' "$log_file" || fail "非法 UTF-8 报错不明确：$(<"$log_file")"

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

  # 反例 7（P2-5）：fullAccess 为字符串 "true"（Go encoding/json 拒绝，必须为布尔值）-> 必败。
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["turn/start"],"fullAccess":"true","agy":{"minimumVersion":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail 'fullAccess="true"（字符串）未被拦截。'
  fi
  grep -Fq '必须是布尔值' "$log_file" \
    || fail "fullAccess 非布尔报错不明确：$(<"$log_file")"

  # 反例 7b（P2-5）：大小写变体 FullAccess 为字符串，或重复键首项非法（Go encoding/json 均拒绝）-> 必败。
  if printf '%s' '{"name":"mimi-claude-adapter","version":"0.3.0","methods":["turn/start"],"FullAccess":"true","claudeCode":{"minimumVersion":"2.1.294"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json claude 0.3.0 >"$log_file" 2>&1; then
    fail '大小写变体 FullAccess="true" 未被拦截。'
  fi
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["turn/start"],"fullAccess":"true","fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail '重复键首项 fullAccess="true" 未被拦截。'
  fi

  # 反例 8（P2-5）：额外字段包含非标准 JSON 常量 NaN / Infinity（Go 拒绝）-> 必败。
  if printf '%s' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["turn/start"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"},"extra":NaN}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "包含 NaN 的非标准 JSON 未被拦截。"
  fi
  grep -Fq '非标准 JSON 常量' "$log_file" \
    || fail "NaN 报错不明确：$(<"$log_file")"

  if printf '%s' '{"name":"mimi-claude-adapter","version":"0.3.0","methods":["turn/start"],"fullAccess":true,"claudeCode":{"minimumVersion":"2.1.294"},"extra":Infinity}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json claude 0.3.0 >"$log_file" 2>&1; then
    fail "包含 Infinity 的非标准 JSON 未被拦截。"
  fi

  # 反例 9（P2-5）：合法 JSON 后紧跟原始 NUL 字节 \x00（不能被 Bash 命令替换吞掉）-> 必败。
  if printf '%s\0' '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["turn/start"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}' \
    | bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-capabilities-json agy 0.1.0 >"$log_file" 2>&1; then
    fail "合法 JSON 后跟 NUL 字节未被拦截。"
  fi
  grep -Fq 'NUL' "$log_file" \
    || fail "尾随 NUL 字节报错不明确：$(<"$log_file")"
}

run_static_consistency_tests() {
  check_embedded_binary_coverage \
    "$ROOT_DIR/macos/MimiRemoteMac/Scripts/embed-agentd.sh" \
    "$ROOT_DIR/scripts/build-macos-installer.sh" \
    "$ROOT_DIR/scripts/check-macos-installer.sh"

  # 变异反例（快速静态提示）：覆盖 $bundle_root 与 ${bundle_root} 两种赋值拼写。
  local mutated_embed="$TEMP_DIR/embed-agentd-mutated.sh"
  local mutation_log="$TEMP_DIR/static-mutation.log"
  local mutation_line
  for mutation_line in \
    'rogue_sidecar_output="$bundle_root/Resources/mimi-rogue-sidecar"' \
    'rogue_output="${bundle_root}/Resources/mimi-rogue-sidecar"'; do
    cp "$ROOT_DIR/macos/MimiRemoteMac/Scripts/embed-agentd.sh" "$mutated_embed"
    printf '\n%s\n' "$mutation_line" >> "$mutated_embed"
    if (
      check_embedded_binary_coverage \
        "$mutated_embed" \
        "$ROOT_DIR/scripts/build-macos-installer.sh" \
        "$ROOT_DIR/scripts/check-macos-installer.sh"
    ) >"$mutation_log" 2>&1; then
      fail "静态一致性变异用例未拦截漏出签名列表的 mimi-rogue-sidecar（${mutation_line}）。"
    fi
    grep -Fq 'mimi-rogue-sidecar' "$mutation_log" \
      || fail "静态一致性变异用例报错未指出遗漏的 mimi-rogue-sidecar：$(<"$mutation_log")"
  done

  run_capabilities_json_tests

  echo "Mac 安装包签名静态一致性与能力 JSON 自测通过（含漏签变异与严格 Go JSON 反例）。"
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

  # 额外编译一个按可执行文件名响应 version/--version/--capabilities 的受控 universal Mach-O，
  # 用于端到端测试 build-macos-installer.sh 完整签名循环与 check-macos-installer.sh --app 完整验收。
  local probe_src="$out_dir/probe.c"
  cat > "$probe_src" <<'PROBE_C'
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

static const char *base_name(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

int main(int argc, char **argv) {
  const char *name = argc > 0 ? base_name(argv[0]) : "";
  const char *arg1 = argc > 1 ? argv[1] : "";

  if (strcmp(name, "agentd") == 0 && strcmp(arg1, "preflight") == 0) {
    char cwd[PATH_MAX], home[PATH_MAX], config[PATH_MAX], workspace[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) return 1;
    snprintf(home, sizeof(home), "%s/home", cwd);
    snprintf(config, sizeof(config), "%s/home/config.json", cwd);
    snprintf(workspace, sizeof(workspace), "%s/work", cwd);
    if (argc != 12 || !getenv("HOME") || strcmp(getenv("HOME"), home) || getenv("TEST_REPO_ROOT") ||
        strcmp(argv[2], "--json") || strcmp(argv[3], "--stage") || strcmp(argv[4], "setup") ||
        strcmp(argv[5], "--config") || strcmp(argv[6], config) || strcmp(argv[7], "--scan-root") ||
        strcmp(argv[8], workspace) || strcmp(argv[9], "--browse-root") || strcmp(argv[10], workspace) ||
        strcmp(argv[11], "--installer-smoke")) return 2;
    puts("{\"schema\":\"mimi.onboarding.preflight/v1\",\"stage\":\"setup\",\"ok\":true,"
         "\"configured\":false,\"workspace_confirmed\":false,\"scan_root_exists\":true,\"checks\":["
         "{\"id\":\"config_store\",\"state\":\"ok\"},{\"id\":\"workspace_root\",\"state\":\"ok\"},"
         "{\"id\":\"service_daemon\",\"code\":\"service_not_running\"},{\"id\":\"assistant_codex\"},"
         "{\"id\":\"assistant_claude\"},{\"id\":\"assistant_agy\"},{\"id\":\"assistant_deepseek\"}]}");
    return 0;
  }
  if (strcmp(name, "agentd") == 0 || strcmp(name, "mimi-tailcat-experiment") == 0) {
    if (strcmp(arg1, "version") == 0) {
      printf("%s 9.9.9\n", name);
      return 0;
    }
  } else if (strcmp(name, "alleycat-claude-bridge") == 0) {
    if (strcmp(arg1, "--version") == 0) {
      printf("alleycat-claude-bridge 9.9.9\n");
      return 0;
    }
  } else if (strcmp(name, "mimi-claude-adapter") == 0) {
    if (strcmp(arg1, "--version") == 0) {
      printf("mimi-claude-adapter 9.9.9\n");
      return 0;
    }
    if (strcmp(arg1, "--capabilities") == 0) {
      printf("{\"name\":\"mimi-claude-adapter\",\"version\":\"9.9.9\",\"methods\":[\"initialize\",\"turn/start\"],\"fullAccess\":true,\"claudeCode\":{\"minimumVersion\":\"2.1.294\"}}\n");
      return 0;
    }
  } else if (strcmp(name, "mimi-agy-adapter") == 0) {
    if (strcmp(arg1, "--version") == 0) {
      printf("mimi-agy-adapter 9.9.9\n");
      return 0;
    }
    if (strcmp(arg1, "--capabilities") == 0) {
      printf("{\"name\":\"mimi-agy-adapter\",\"version\":\"9.9.9\",\"methods\":[\"initialize\",\"turn/start\"],\"fullAccess\":true,\"agy\":{\"minimumVersion\":\"1.5.0\"}}\n");
      return 0;
    }
  }
  return 0;
}
PROBE_C

  run_logged "编译受控探针 arm64 Mach-O" \
    xcrun clang -arch arm64 -O0 "$probe_src" -o "$out_dir/probe-arm64"
  run_logged "编译受控探针 x86_64 Mach-O" \
    xcrun clang -arch x86_64 -O0 "$probe_src" -o "$out_dir/probe-x86_64"
  run_logged "合成受控探针 universal Mach-O" \
    lipo -create "$out_dir/probe-arm64" "$out_dir/probe-x86_64" -output "$out_dir/probe-universal"
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

assert_fast_entries_reject() {
  local app="$1" expected_error="$2" log_file="$TEMP_DIR/fixed-entry.log"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app" >"$log_file" 2>&1; then
    fail "checker 快速入口放行了固定入口反例：${app}。"
  fi
  grep -Fq "$expected_error" "$log_file" || fail "checker 固定入口报错不准确：$(<"$log_file")"
  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app" >"$log_file" 2>&1; then
    fail "builder 快速入口放行了固定入口反例：${app}。"
  fi
  grep -Fq "$expected_error" "$log_file" || fail "builder 固定入口报错不准确：$(<"$log_file")"
}

run_fixed_entry_path_tests() {
  local wrong_id_app="$1"
  local aliased_app="$TEMP_DIR/CaseAliased.app"
  local linked_app="$TEMP_DIR/LinkedResources.app"

  if [[ -d "$wrong_id_app/contents" ]]; then
    run_logged "复制固定标识符反例" ditto "$wrong_id_app" "$aliased_app"
    run_logged "改用不同目录项拼写" mv "$aliased_app/Contents/Resources" "$aliased_app/Contents/rename-temp"
    run_logged "设置真实目录名为 RESOURCES" mv "$aliased_app/Contents/rename-temp" "$aliased_app/Contents/RESOURCES"
    local renamed="$aliased_app/Contents/RESOURCES"
    run_logged "暂移小写文件名" mv "$renamed/mimi-agy-adapter" "$renamed/rename-temp"
    run_logged "设置真实文件名为 MIMI-AGY-ADAPTER" mv "$renamed/rename-temp" "$renamed/MIMI-AGY-ADAPTER"
    [[ "$renamed/MIMI-AGY-ADAPTER" -ef "$aliased_app/Contents/Resources/mimi-agy-adapter" ]] \
      || fail "测试卷的大小写路径未指向同一节点。"
    run_logged "重封大小写别名 App" codesign --force --sign - --options runtime --timestamp=none "$aliased_app"
    assert_fast_entries_reject "$aliased_app" 'com.gaixianggeng.mimi.mac.agy-adapter'
    echo "大小写不敏感卷的固定入口标识符反例通过。"
  fi

  run_logged "复制父目录链接反例" ditto "$wrong_id_app" "$linked_app"
  run_logged "移动真实 Resources" mv "$linked_app/Contents/Resources" "$linked_app/Contents/EmbeddedResources"
  run_logged "链接 Resources 到包内父目录" ln -s EmbeddedResources "$linked_app/Contents/Resources"
  run_logged "重封父目录链接 App" codesign --force --sign - --options runtime --timestamp=none "$linked_app"
  assert_fast_entries_reject "$linked_app" '固定入口的父目录'
}

run_multiline_signing_tests() {
  local valid_app="$1" sample="$2"
  local app="$TEMP_DIR/MultilineIdentifier.app"
  local expected='com.gaixianggeng.mimi.mac.agentd'
  local agent="$app/Contents/Resources/agentd"
  local log_file="$TEMP_DIR/multiline-signing.log"

  run_logged "复制多行 identifier 测试 App" ditto "$valid_app" "$app"
  run_logged "准备固定入口 agentd" cp "$sample" "$agent"
  run_logged "签入固定值后带换行的 identifier" \
    codesign --force --sign - --identifier "$expected"$'\nextra' --options runtime --timestamp=none "$agent"
  run_logged "重封包含多行 identifier 的 App" codesign --force --sign - --options runtime --timestamp=none "$app"
  run_logged "确认多行 identifier 样例签名本身完整" codesign --verify --deep --strict "$app"
  assert_fast_entries_reject "$app" "期望 $expected"

  # 移到未知入口，验证跨切片一致性检查不会接受文本截断的值。
  run_logged "将已签名 Mach-O 移到未知入口" mv "$agent" "$app/Contents/Resources/unlisted-helper"
  run_logged "重封包含未知入口的 App" codesign --force --sign - --options runtime --timestamp=none "$app"
  assert_fast_entries_reject "$app" 'unlisted-helper（'

  # 同一个有效 ad-hoc App，只变更父目录名。两个入口都使用系统 codesign。
  local parent="$TEMP_DIR/TeamPath"$'\nTeamIdentifier=XXXXXXXXXX\nsuffix'
  local relocated_app="$parent/Test.app"
  mkdir "$parent"
  run_logged "将正常 ad-hoc App 复制到含换行的父目录" ditto "$valid_app" "$relocated_app"
  run_logged "确认含换行路径的 App 签名本身完整" codesign --verify --deep --strict "$relocated_app"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$relocated_app" >"$log_file" 2>&1; then
    fail "含换行的父目录伪造 Team ID 后通过了 checker 开发签名校验。"
  fi
  grep -Fq 'Executable 路径含换行' "$log_file" || fail "checker 未指出含换行的 Executable：$(<"$log_file")"
  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$relocated_app" >"$log_file" 2>&1; then
    fail "含换行的父目录伪造 Team ID 后通过了 builder 开发签名校验。"
  fi
  grep -Fq 'Executable 路径含换行' "$log_file" || fail "builder 未指出含换行的 Executable：$(<"$log_file")"
  echo "真实 codesign 多行签名反例通过（固定及未知入口 identifier、Executable 路径中的 Team ID）。"
}

run_direct_builder_output_tests() {
  local fixture_bin="$1" probe="$2" valid_app="$3"
  local external="$TEMP_DIR/output-external" log_file="$TEMP_DIR/direct-builder.log"
  local output artifact conflict leaf sibling name mode
  local -a flags
  mkdir "$external"
  printf 'keep\n' > "$external/sentinel"

  for mode in app snapshot development formal; do
    case "$mode" in
      app) flags=(--snapshot --app-only); name='Mimi Remote Mac.app' ;;
      snapshot) flags=(--snapshot); name=Mimi-Remote-Mac.dmg ;;
      development) flags=(--development-signing); name=Mimi-Remote-Mac-Development.dmg ;;
      formal) flags=(); name=Mimi-Remote-Mac.dmg ;;
    esac
    for artifact in "$name" "$name.sha256"; do
      if [[ "$mode" == app && "$artifact" == *.sha256 ]]; then
        continue
      fi
      for conflict in type link directory; do
        if [[ "$conflict" == directory && "$mode" != app ]]; then
          continue
        fi
        output="$TEMP_DIR/builder-${mode}-${artifact}-${conflict}"
        mkdir "$output"
        leaf="$output/$artifact"
        sibling="$output/$name.sha256"
        if [[ "$artifact" == *.sha256 ]]; then
          sibling="$output/$name"
        fi
        printf 'old artifact\n' > "$sibling"
        if [[ "$conflict" == link ]]; then
          if [[ "$mode" == app ]]; then
            ln -s "$external" "$leaf"
          else
            ln -s "$external/sentinel" "$leaf"
          fi
        elif [[ "$mode" == app && "$conflict" == type ]]; then
          printf 'old file\n' > "$leaf"
        else
          mkdir "$leaf"
          printf 'old file\n' > "$leaf/sentinel"
        fi
        # 禁用凭据，目录冲突必须在构建和签名前被公开入口拒绝。
        if (
          unset MACOS_SIGN_P12 MACOS_SIGN_PASSWORD MACOS_NOTARY_KEY MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID
          if [[ "$mode" == formal ]]; then
            set -- --version 1.2.3
          else
            set -- --version 1.2.3 "${flags[@]}"
          fi
          bash "$ROOT_DIR/scripts/build-macos-installer.sh" "$@" --output-dir "$output"
        ) >"$log_file" 2>&1; then
          fail "直接 builder 放行了 ${mode} 的固定目标冲突：${artifact} / ${conflict}。"
        fi
        grep -Fq "$artifact" "$log_file" || fail "直接 builder 冲突诊断未指出产物：$(<"$log_file")"
        grep -Eq '拒绝覆盖|已被(普通目录)?占用' "$log_file" || fail "直接 builder 未在目标检查阶段拒绝：$(<"$log_file")"
        [[ "$(<"$sibling")" == "old artifact" ]] || fail "直接 builder 改写了已有产物。"
        [[ "$(<"$external/sentinel")" == keep ]] || fail "直接 builder 改写了链接目标。"
        case "$conflict:$mode" in
          link:*) [[ -L "$leaf" ]] || fail "直接 builder 改写了符号链接节点。" ;;
          type:app) [[ "$(<"$leaf")" == "old file" ]] || fail "直接 builder 改写了占用 App 路径的文件。" ;;
          type:*) [[ "$(<"$leaf/sentinel")" == "old file" ]] || fail "直接 builder 改写了占用产物路径的目录。" ;;
        esac
      done
    done
  done

  # 复制已创建部分内容才失败，正式路径仍应保留原有 App。
  cat > "$fixture_bin/ditto" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == */.Mimi-Remote-Mac.app.staging.*/"Mimi Remote Mac.app" ]]; then
  mkdir "$2"
  printf 'partial copy\n' > "$2/partial"
  echo 'injected App copy failure' >&2
  exit 1
fi
exec /usr/bin/ditto "$@"
STUB
  chmod 0755 "$fixture_bin/ditto"
  output="$TEMP_DIR/builder-copy-failure"
  mkdir "$output"
  ditto "$valid_app" "$output/Mimi Remote Mac.app"
  printf 'old app\n' > "$output/Mimi Remote Mac.app/keep"
  if PATH="$fixture_bin:$PATH" TEST_REPO_ROOT="$ROOT_DIR" TEST_PROBE_UNIVERSAL="$probe" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --snapshot --app-only --version 1.2.3 --output-dir "$output" >"$log_file" 2>&1; then
    fail "直接 builder 在 App 半复制后仍返回成功。"
  fi
  rm -- "$fixture_bin/ditto"
  grep -Fq 'injected App copy failure' "$log_file" || fail "没有命中 App 半复制反例：$(<"$log_file")"
  [[ "$(<"$output/Mimi Remote Mac.app/keep")" == "old app" ]] || fail "复制失败后旧 App 丢失。"
  [[ "$(ls -A "$output")" == "Mimi Remote Mac.app" ]] || fail "复制失败后残留暂存 App。"
}

run_macos_codesign_tests() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "真实 codesign 行为测试只能在 macOS (Darwin) 上运行；非 macOS 环境请传 --static-only。"
  fi
  for command_name in chmod codesign cp ditto file hdiutil lipo ln mktemp plutil python3 xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少 macOS 测试命令 ${command_name}。"
  done

  local sample_dir="$TEMP_DIR/samples"
  mkdir -p "$sample_dir"
  build_controlled_sample_machos "$sample_dir"

  local sample_universal="$sample_dir/sample-universal"
  local sample_arm64="$sample_dir/sample-arm64"
  local sample_x86_64="$sample_dir/sample-x86_64"
  local probe_universal="$sample_dir/probe-universal"
  local probe_arm64="$sample_dir/probe-arm64"
  local probe_x86_64="$sample_dir/probe-x86_64"
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
  run_multiline_signing_tests "$app_dir" "$sample_universal"

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

  # 5b. P1-1（单切片 false 反例）：arm64 带合法 JIT entitlements，仅 x86_64 为 allow-jit=<false/> -> 必拒。
  local jit_arm64="$TEMP_DIR/jit-arm64"
  local jit_x86_64="$TEMP_DIR/jit-x86_64"
  run_logged "准备单切片 JIT arm64" cp "$sample_arm64" "$jit_arm64"
  run_logged "准备单切片 JIT x86_64" cp "$sample_x86_64" "$jit_x86_64"
  run_logged "签名 JIT arm64（合法 true）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements" \
      "$jit_arm64"
  run_logged "签名 JIT x86_64（allow-jit=false）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_false" \
      "$jit_x86_64"
  run_logged "合成单切片 allow-jit=false universal 适配器" \
    lipo -create "$jit_arm64" "$jit_x86_64" -output "$agy_bin"
  run_logged "设置单切片 JIT 适配器权限" chmod 0755 "$agy_bin"
  run_logged "重封主 App（单切片 allow-jit=false 用例）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "仅 x86_64 为 allow-jit=false 的 mimi-agy-adapter 被 checker 放行。"
  fi
  grep -Fq 'x86_64' "$test_log" \
    || fail "单切片 allow-jit=false 报错未指出 x86_64：$(<"$test_log")"
  grep -Fq 'com.apple.security.cs.allow-jit' "$test_log" \
    || fail "单切片 allow-jit=false 报错未指出 allow-jit：$(<"$test_log")"

  # 5c. P1-1（包内符号链接绕过反例）：mimi-agy-adapter 指向同目录合法签名但 allow-jit=false 的文件 -> 必拒。
  local agy_real_bad="$app_dir/Contents/Resources/mimi-agy-adapter-real"
  run_logged "复制符号链接目标适配器" cp "$sample_universal" "$agy_real_bad"
  run_logged "设置符号链接目标权限" chmod 0755 "$agy_real_bad"
  run_logged "签名符号链接目标（allow-jit=false）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_false" \
      "$agy_real_bad"
  rm -f -- "$agy_bin"
  run_logged "创建包内适配器符号链接" ln -s "mimi-agy-adapter-real" "$agy_bin"
  run_logged "重封主 App（包内符号链接适配器用例）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "包内符号链接适配器（指向 allow-jit=false 文件）被 checker 快速模式放行。"
  fi
  grep -Fq '符号链接' "$test_log" \
    || fail "包内符号链接适配器报错未指出符号链接拒绝：$(<"$test_log")"
  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "包内符号链接适配器被 builder --verify-only 放行。"
  fi

  # 恢复合法普通文件 mimi-agy-adapter。
  rm -f -- "$agy_bin" "$agy_real_bad"
  run_logged "恢复合法普通文件 mimi-agy-adapter" cp "$sample_universal" "$agy_bin"
  run_logged "设置恢复后的 mimi-agy-adapter 权限" chmod 0755 "$agy_bin"
  run_logged "恢复签入正式 ClaudeAdapter.entitlements" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements" \
      "$agy_bin"
  run_logged "重封主 App（恢复合法适配器）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  # 5d. P2-4（已知入口错误固定 identifier）：两切片均具备合法 runtime/entitlements 且一致，但 identifier 偏离固定值 -> 两个快速入口均必拒。
  run_logged "给 mimi-agy-adapter 签入错误固定 identifier" \
    codesign --force --sign - \
      --identifier com.example.wrong.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements" \
      "$agy_bin"
  run_logged "重封主 App（已知入口错误 identifier 用例）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "已知入口 mimi-agy-adapter 使用错误 identifier 被 checker 快速模式放行。"
  fi
  grep -Fq 'com.gaixianggeng.mimi.mac.agy-adapter' "$test_log" \
    || fail "已知入口错误 identifier checker 报错未指出期望值：$(<"$test_log")"
  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "已知入口 mimi-agy-adapter 使用错误 identifier 被 builder --verify-only 放行。"
  fi
  grep -Fq 'com.gaixianggeng.mimi.mac.agy-adapter' "$test_log" \
    || fail "已知入口错误 identifier builder 报错未指出期望值：$(<"$test_log")"
  run_fixed_entry_path_tests "$app_dir"

  # 恢复正确固定 identifier。
  run_logged "恢复 mimi-agy-adapter 正确固定 identifier" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements" \
      "$agy_bin"
  run_logged "重封主 App（恢复正确固定 identifier）" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  # 6. P2-1 & P2-4：
  # 6a. 仅改变某切片 Identifier（两端均具备合法 runtime、同签名身份）-> checker 快速模式与 builder --verify-only 均必拒。
  local id_arm64="$TEMP_DIR/id-arm64"
  local id_x86_64="$TEMP_DIR/id-x86_64"
  local id_mismatch_bin="$app_dir/Contents/Resources/mimi-id-mismatch"
  run_logged "准备异 identifier 切片 arm64" cp "$sample_arm64" "$id_arm64"
  run_logged "准备异 identifier 切片 x86_64" cp "$sample_x86_64" "$id_x86_64"
  run_logged "签名异 identifier arm64（带 runtime）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.id-a \
      --options runtime --timestamp=none \
      "$id_arm64"
  run_logged "签名异 identifier x86_64（带 runtime、仅改 identifier）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.signing-test.id-b \
      --options runtime --timestamp=none \
      "$id_x86_64"
  run_logged "合成仅 identifier 不一致的 universal 二进制" \
    lipo -create "$id_arm64" "$id_x86_64" -output "$id_mismatch_bin"
  run_logged "设置异 identifier 二进制权限" chmod 0755 "$id_mismatch_bin"
  run_logged "重封含异 identifier 二进制的主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "仅切片 identifier 不一致（均带 runtime）的 universal Mach-O 被 checker 快速模式放行。"
  fi
  grep -Fq 'mimi-id-mismatch' "$test_log" \
    || fail "异 identifier checker 报错缺少文件名：$(<"$test_log")"
  grep -Fq 'x86_64' "$test_log" \
    || fail "异 identifier checker 报错未指出问题切片 x86_64：$(<"$test_log")"
  grep -Fq 'identifier' "$test_log" \
    || fail "异 identifier checker 报错未指出 identifier 不一致：$(<"$test_log")"

  if bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --snapshot "$app_dir" >"$test_log" 2>&1; then
    fail "仅切片 identifier 不一致（均带 runtime）的 universal Mach-O 被 builder --verify-only 放行。"
  fi
  grep -Fq 'mimi-id-mismatch' "$test_log" \
    || fail "异 identifier builder 报错缺少文件名：$(<"$test_log")"
  grep -Fq 'x86_64' "$test_log" \
    || fail "异 identifier builder 报错未指出问题切片 x86_64：$(<"$test_log")"

  rm -f -- "$id_mismatch_bin"
  run_logged "移除异 identifier 样例后重封主 App" \
    codesign --force --sign - --options runtime --timestamp=none "$app_dir"

  # 6b. lipo -create 拼接两个不同签名切片（arm64 带 runtime，x86_64 无 runtime）-> 必拒。
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

  # 完整性和 entitlements 使用系统 codesign。证书策略矩阵为 requirement 结果和元数据单独设桩。
  local fake_bin_dir="$TEMP_DIR/fake-bin"
  mkdir -p "$fake_bin_dir"
  cat > "$fake_bin_dir/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--verify" && "${4:-}" == --test-requirement==* ]]; then
  requirement="${4#*=}"
  [[ "$requirement" == *'anchor apple generic'* ]] || exit 75
  [[ "$requirement" == *'certificate 1[field.1.2.840.113635.100.6.2.6] exists'* ]] || exit 75
  [[ "$requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13] exists'* ]] || exit 75
  if [[ -n "${TEST_REQUIREMENT_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$TEST_REQUIREMENT_LOG"
  fi
  if [[ "${TEST_REAL_DEVELOPER_ID_REQUIREMENT:-0}" == "1" ]] \
    || [[ "${7:-}" == *"mimi-rogue-adhoc" && "${TEST_PASSTHROUGH_ROGUE_ADHOC:-0}" == "1" ]]; then
    exec /usr/bin/codesign "$@"
  fi
  [[ "${5:-}" == "--arch" && -n "${6:-}" && -n "${7:-}" ]] || exit 75
  if [[ "${7:-}" == *"mimi-leaky-adapter" && "$6" == "${TEST_REJECT_DEVELOPER_ID_ARCH:-}" ]]; then
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == "--verify" && "${3:-}" == '--test-requirement==certificate leaf[subject.OU] = '* ]]; then
  [[ "${4:-}" == "--arch" && -n "${5:-}" && -n "${6:-}" ]] || exit 75
  if [[ "$6" == *"mimi-rogue-adhoc" && "${TEST_PASSTHROUGH_ROGUE_ADHOC:-0}" == "1" ]]; then
    exec /usr/bin/codesign "$@"
  fi
  [[ "$3" == '--test-requirement==certificate leaf[subject.OU] = "TEAM123456"' ]] || exit 75
  if [[ "$6" == *"mimi-leaky-adapter" && "$5" == "${TEST_REJECT_TEAM_OU_ARCH:-}" ]]; then
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == "-d" && "${2:-}" == "--arch" && "${4:-}" == "--verbose=1" ]]; then
  arch="$3"
  target="$5"
  if [[ "$target" == *"mimi-rogue-adhoc" && "${TEST_PASSTHROUGH_ROGUE_ADHOC:-0}" == "1" ]]; then
    exec /usr/bin/codesign "$@"
  fi
  team="TEAM123456"
  timestamp="Nov 17, 2026 at 19:12:30"
  if [[ "$target" == *"mimi-leaky-adapter" && "$arch" == "${TEST_LEAKY_TARGET_ARCH:-}" ]]; then
    team="${TEST_LEAKY_TEAM:-not set}"
    timestamp="${TEST_LEAKY_TIMESTAMP:-}"
  fi
  details="$(/usr/bin/codesign "$@" 2>&1)" || exit $?
  # 保留系统给出的 Executable、Identifier 和 flags，只模拟需要证书的字段。
  printf '%s\n' "$details" | sed '/^TeamIdentifier=/d; /^Timestamp=/d; /^Signed Time=/d'
  if [[ -n "$timestamp" ]]; then
    printf 'Timestamp=%s\n' "$timestamp"
  fi
  printf 'TeamIdentifier=%s\n' "$team"
  exit 0
fi
exec /usr/bin/codesign "$@"
STUB
  run_logged "设置 fake codesign 权限" chmod 0755 "$fake_bin_dir/codesign"

  # 真实 ad-hoc App 即使显示了合格名称、Team ID 和时间戳，仍必须在 Apple 信任链检查失败。
  local requirement_log="$TEMP_DIR/developer-id-requirement.log"
  if PATH="$fake_bin_dir:$PATH" TEST_REAL_DEVELOPER_ID_REQUIREMENT=1 TEST_REQUIREMENT_LOG="$requirement_log" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1; then
    fail "伪造显示元数据的 ad-hoc App 通过了 checker Developer ID。"
  fi
  grep -Fq -- '--arch arm64' "$requirement_log" || grep -Fq -- '--arch x86_64' "$requirement_log" \
    || fail "checker 没有将逐片 Apple 证书要求交给系统 codesign。"
  grep -Fq '未通过 Apple 证书要求' "$test_log" || fail "checker 缺少证书链诊断：$(<"$test_log")"
  grep -Eq 'test-requirement: .*failed to satisfy.*requirement' "$test_log" \
    || fail "系统 codesign 未实际求值 checker 的内联要求：$(<"$test_log")"
  : > "$requirement_log"
  if PATH="$fake_bin_dir:$PATH" TEST_REAL_DEVELOPER_ID_REQUIREMENT=1 TEST_REQUIREMENT_LOG="$requirement_log" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1; then
    fail "伪造显示元数据的 ad-hoc App 通过了 builder 正式验收。"
  fi
  grep -Fq -- '--test-requirement=' "$requirement_log" || fail "builder 未使用系统 codesign 检查证书链。"
  grep -Fq '未通过 Apple 证书要求' "$test_log" || fail "builder 缺少证书链诊断：$(<"$test_log")"
  grep -Eq 'test-requirement: .*failed to satisfy.*requirement' "$test_log" \
    || fail "系统 codesign 未实际求值 builder 的内联要求：$(<"$test_log")"

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
    TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "仅 x86_64 切片带第三方 Team ID 时 checker 未拦截。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）的 Team ID' "$test_log" \
    || fail "第三方 Team ID 切片报错不准确：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="7FRXF46ZSN" \
    TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$app_dir" >"$test_log" 2>&1; then
    fail "仅 x86_64 切片带第三方 Team ID 时 builder 未拦截。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）的 Team ID' "$test_log" \
    || fail "builder 第三方 Team ID 切片报错不准确：$(<"$test_log")"

  # 显示值一致也必须向系统核对证书 OU。
  if PATH="$fake_bin_dir:$PATH" TEST_REJECT_TEAM_OU_ARCH="x86_64" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "证书 OU 不一致的 x86_64 切片被 checker 放行。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）的 Team ID（TEAM123456）与签名证书不一致' "$test_log" \
    || fail "证书 OU 校验报错不准确：$(<"$test_log")"

  # 9c. 同 Team ID 但 x86_64 切片为 Apple Development -> --require-team-signing 必过，--require-developer-id 与 builder 正式策略必拒。
  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1 \
    || fail "同 Team ID 的开发签名应通过 checker --require-team-signing：$(<"$test_log")"

  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only --development-signing "$app_dir" >"$test_log" 2>&1 \
    || fail "同 Team ID 的开发签名应通过 builder --verify-only --development-signing：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_REJECT_DEVELOPER_ID_ARCH="x86_64" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1; then
    fail "非 Developer ID Application 签名在 checker --require-developer-id 下被放行。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）不是有效的 Developer ID Application 签名' "$test_log" \
    || fail "Developer ID 校验报错不准确：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_REJECT_DEVELOPER_ID_ARCH="x86_64" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1; then
    fail "非 Developer ID Application 签名在 builder 正式策略下被放行。"
  fi

  # 9d. 同 Team ID 且为 Developer ID Application，但 x86_64 切片 Timestamp=none -> 必拒。
  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="none" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1; then
    fail "Timestamp=none 在 checker --require-developer-id 下被放行。"
  fi
  grep -Fq 'mimi-leaky-adapter（x86_64）缺少有效的安全时间戳' "$test_log" \
    || fail "Timestamp=none 校验报错不准确：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="none" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1; then
    fail "Timestamp=none 在 builder 正式策略下被放行。"
  fi

  # 9e. 全部 Mach-O 全部切片同 Team ID + Developer ID Application + 有效 Timestamp -> checker 与 builder 均必过。
  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-developer-id "$app_dir" >"$test_log" 2>&1 \
    || fail "全部 Mach-O 具备同 Team ID Developer ID 与安全时间戳时应通过 checker --require-developer-id：$(<"$test_log")"

  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TARGET_ARCH="x86_64" TEST_LEAKY_TEAM="TEAM123456" \
    TEST_LEAKY_TIMESTAMP="Nov 17, 2026 at 19:12:30" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --verify-only "$app_dir" >"$test_log" 2>&1 \
    || fail "全部 Mach-O 具备同 Team ID Developer ID 与安全时间戳时应通过 builder 正式策略：$(<"$test_log")"

  # 10. P2-6 / P1-1 / P2-4 端到端集成测试：
  # 仅对 xcodebuild 做受控替换以输出最小完整 universal Mimi Remote Mac.app，不打桩跳过
  # build-macos-installer.sh 的真实生产签名循环、封包前检验与 check-macos-installer.sh --app 完整验收。
  local fake_xcode_dir="$TEMP_DIR/fake-xcodebuild-bin"
  mkdir -p "$fake_xcode_dir"
  cat > "$fake_xcode_dir/xcodebuild" <<'XCODE_STUB'
#!/usr/bin/env bash
set -euo pipefail
derived_data=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data="${2:-}"
    shift 2
  else
    shift
  fi
done
if [[ -z "$derived_data" ]]; then
  echo "fake xcodebuild 缺少 -derivedDataPath" >&2
  exit 2
fi
app_out="$derived_data/Build/Products/Release/Mimi Remote Mac.app"
mkdir -p \
  "$app_out/Contents/MacOS" \
  "$app_out/Contents/Resources" \
  "$app_out/Contents/Library/LaunchAgents"

cat > "$app_out/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Mimi Remote Mac</string>
  <key>CFBundleIdentifier</key>
  <string>com.gaixianggeng.mimi.mac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Mimi Remote Mac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.3</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Photo library test description</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Desktop folder test description</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Documents folder test description</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Downloads folder test description</string>
</dict>
</plist>
PLIST

cp "$TEST_REPO_ROOT/THIRD_PARTY_NOTICES.md" "$app_out/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$TEST_REPO_ROOT/macos/MimiRemoteMac/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist" \
  "$app_out/Contents/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"

for rel_bin in \
  "Contents/MacOS/Mimi Remote Mac" \
  "Contents/Resources/agentd" \
  "Contents/Resources/alleycat-claude-bridge" \
  "Contents/Resources/mimi-claude-adapter" \
  "Contents/Resources/mimi-agy-adapter" \
  "Contents/Resources/mimi-tailcat-experiment"; do
  cp "$TEST_PROBE_UNIVERSAL" "$app_out/$rel_bin"
  chmod 0755 "$app_out/$rel_bin"
done

if [[ -n "${TEST_EMPTY_PREFLIGHT_PROBE:-}" ]]; then
  cp "$TEST_EMPTY_PREFLIGHT_PROBE" "$app_out/Contents/Resources/agentd"
fi
if [[ "${TEST_INJECT_ROGUE_SIDECAR:-0}" == "1" ]]; then
  # 模拟 embed-agentd.sh 新增了一个未进入 build-macos-installer.sh 签名列表的未签侧车。
  rogue_path="$app_out/Contents/Resources/mimi-rogue-sidecar"
  cp "$TEST_PROBE_UNIVERSAL" "$rogue_path"
  chmod 0755 "$rogue_path"
  /usr/bin/codesign --remove-signature "$rogue_path"
fi
XCODE_STUB
  run_logged "设置 fake xcodebuild 权限" chmod 0755 "$fake_xcode_dir/xcodebuild"

  # 10a. 端到端正向：真实运行 build-macos-installer.sh --snapshot --app-only 签名循环 + check-macos-installer.sh --app 完整验收。
  local e2e_ok_out="$TEMP_DIR/e2e-ok-out"
  mkdir -p "$e2e_ok_out"
  PATH="$fake_xcode_dir:$PATH" TEST_REPO_ROOT="$ROOT_DIR" TEST_PROBE_UNIVERSAL="$probe_universal" \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --snapshot --app-only --version 1.2.3 --output-dir "$e2e_ok_out" >"$test_log" 2>&1 \
    || fail "端到端 build-macos-installer.sh --snapshot --app-only 失败：$(<"$test_log")"
  local e2e_app="$e2e_ok_out/Mimi Remote Mac.app"
  [[ -d "$e2e_app" ]] || fail "端到端构建未生成 Mimi Remote Mac.app。"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --app "$e2e_app" >"$test_log" 2>&1 \
    || fail "端到端生成的 Mimi Remote Mac.app 未通过完整 check-macos-installer.sh --app 校验：$(<"$test_log")"
  run_direct_builder_output_tests "$fake_xcode_dir" "$probe_universal" "$e2e_app"

  local failed_smoke_out="$TEMP_DIR/e2e-failed-smoke"
  mkdir "$failed_smoke_out"
  if PATH="$fake_xcode_dir:$PATH" TEST_REPO_ROOT="$ROOT_DIR" TEST_PROBE_UNIVERSAL="$probe_universal" \
    TEST_EMPTY_PREFLIGHT_PROBE="$sample_universal" bash "$ROOT_DIR/scripts/build-macos-installer.sh" \
    --snapshot --app-only --version 1.2.3 --output-dir "$failed_smoke_out" >"$test_log" 2>&1; then
    fail "agentd 未返回预检报告时仍发布了 App。"
  fi
  grep -Fq '隔离预检报告或临时目录异常' "$test_log" || fail "未检测到无效的预检报告。"
  [[ ! -e "$failed_smoke_out/Mimi Remote Mac.app" ]] || fail "预检失败后仍发布了 App。"

  # 10b. P2-6 端到端漏签集成反例：模拟 embed-agentd.sh 注入未签侧车进入真实 build-macos-installer.sh 封包流程 -> 封包前检验必须失败并指出文件名。
  local e2e_bad_out="$TEMP_DIR/e2e-bad-out"
  mkdir -p "$e2e_bad_out"
  if PATH="$fake_xcode_dir:$PATH" TEST_REPO_ROOT="$ROOT_DIR" TEST_PROBE_UNIVERSAL="$probe_universal" TEST_INJECT_ROGUE_SIDECAR=1 \
    bash "$ROOT_DIR/scripts/build-macos-installer.sh" --snapshot --app-only --version 1.2.3 --output-dir "$e2e_bad_out" >"$test_log" 2>&1; then
    fail "端到端集成反例：包含漏签侧车 mimi-rogue-sidecar 时 build-macos-installer.sh 未阻断发布。"
  fi
  grep -Fq 'mimi-rogue-sidecar' "$test_log" \
    || fail "端到端漏签集成反例报错未指出 mimi-rogue-sidecar：$(<"$test_log")"
  [[ ! -e "$e2e_bad_out/Mimi Remote Mac.app" ]] \
    || fail "端到端漏签集成反例失败后不应输出 Mimi Remote Mac.app。"

  # 10c. P1-1 完整 --app 验收反例：包内符号链接适配器指向同目录合法签名但 allow-jit=false 的文件 -> 完整 --app 必拒。
  local full_app_symlink_case="$TEMP_DIR/full-app-symlink/Mimi Remote Mac.app"
  mkdir -p "$(dirname "$full_app_symlink_case")"
  run_logged "复制完整测试 App（P1-1 链接反例）" ditto "$e2e_app" "$full_app_symlink_case"
  local full_agy_real="$full_app_symlink_case/Contents/Resources/mimi-agy-adapter-real"
  run_logged "准备完整 App 符号链接目标" cp "$probe_universal" "$full_agy_real"
  run_logged "设置完整 App 符号链接目标权限" chmod 0755 "$full_agy_real"
  run_logged "签名完整 App 符号链接目标（allow-jit=false）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_false" \
      "$full_agy_real"
  rm -f -- "$full_app_symlink_case/Contents/Resources/mimi-agy-adapter"
  run_logged "创建完整 App 包内适配器符号链接" \
    ln -s "mimi-agy-adapter-real" "$full_app_symlink_case/Contents/Resources/mimi-agy-adapter"
  run_logged "重封完整 App（P1-1 链接反例）" \
    codesign --force --sign - --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
      "$full_app_symlink_case"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --app "$full_app_symlink_case" >"$test_log" 2>&1; then
    fail "完整 --app 验收放行了包内符号链接适配器（指向 allow-jit=false 文件）。"
  fi
  grep -Fq '符号链接' "$test_log" \
    || fail "完整 --app 包内符号链接报错不准确：$(<"$test_log")"

  # 10d. P1-1 完整 --app 单切片 allow-jit=false 反例 -> 完整 --app 必拒。
  local full_app_slice_case="$TEMP_DIR/full-app-slice/Mimi Remote Mac.app"
  mkdir -p "$(dirname "$full_app_slice_case")"
  run_logged "复制完整测试 App（P1-1 单切片反例）" ditto "$e2e_app" "$full_app_slice_case"
  local full_jit_arm64="$TEMP_DIR/full-jit-arm64"
  local full_jit_x86_64="$TEMP_DIR/full-jit-x86_64"
  run_logged "准备完整 App 单切片 arm64" cp "$probe_arm64" "$full_jit_arm64"
  run_logged "准备完整 App 单切片 x86_64" cp "$probe_x86_64" "$full_jit_x86_64"
  run_logged "签名完整 App 单切片 arm64（合法 true）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/ClaudeAdapter.entitlements" \
      "$full_jit_arm64"
  run_logged "签名完整 App 单切片 x86_64（allow-jit=false）" \
    codesign --force --sign - \
      --identifier com.gaixianggeng.mimi.mac.agy-adapter \
      --options runtime --timestamp=none \
      --entitlements "$bad_ent_false" \
      "$full_jit_x86_64"
  run_logged "合成完整 App 单切片 false 适配器" \
    lipo -create "$full_jit_arm64" "$full_jit_x86_64" -output "$full_app_slice_case/Contents/Resources/mimi-agy-adapter"
  run_logged "设置完整 App 单切片适配器权限" chmod 0755 "$full_app_slice_case/Contents/Resources/mimi-agy-adapter"
  run_logged "重封完整 App（单切片 allow-jit=false）" \
    codesign --force --sign - --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
      "$full_app_slice_case"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --app "$full_app_slice_case" >"$test_log" 2>&1; then
    fail "完整 --app 验收放行了仅 x86_64 为 allow-jit=false 的适配器。"
  fi
  grep -Fq 'x86_64' "$test_log" \
    || fail "完整 --app 单切片 allow-jit=false 报错未指出 x86_64：$(<"$test_log")"

  # 10e. P2-4 完整 --app 仅改变某切片 Identifier 反例 -> 完整 --app 必拒。
  local full_app_id_case="$TEMP_DIR/full-app-id-mismatch/Mimi Remote Mac.app"
  mkdir -p "$(dirname "$full_app_id_case")"
  run_logged "复制完整测试 App（P2-4 异 identifier 反例）" ditto "$e2e_app" "$full_app_id_case"
  local full_id_bin="$full_app_id_case/Contents/Resources/mimi-id-mismatch"
  run_logged "合成完整 App 异 identifier 二进制" lipo -create "$id_arm64" "$id_x86_64" -output "$full_id_bin"
  run_logged "设置完整 App 异 identifier 权限" chmod 0755 "$full_id_bin"
  run_logged "重封完整 App（P2-4 异 identifier 反例）" \
    codesign --force --sign - --options runtime --timestamp=none \
      --entitlements "$ROOT_DIR/macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements" \
      "$full_app_id_case"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --app "$full_app_id_case" >"$test_log" 2>&1; then
    fail "完整 --app 验收放行了仅切片 identifier 不一致的 universal Mach-O。"
  fi
  grep -Fq 'mimi-id-mismatch' "$test_log" \
    || fail "完整 --app 异 identifier 报错缺少文件名：$(<"$test_log")"
  grep -Fq 'x86_64' "$test_log" \
    || fail "完整 --app 异 identifier 报错未指出 x86_64：$(<"$test_log")"

  # 11. P2-9 真实 DMG 卷内链接逃逸反例：DMG 内的 Mimi Remote Mac.app 是指向卷外 App 的符号链接 -> 必拒。
  local dmg_escape_root="$TEMP_DIR/dmg-escape-root"
  local dmg_escape_path="$TEMP_DIR/Mimi-Escape.dmg"
  mkdir -p "$dmg_escape_root"
  run_logged "在 DMG 源目录放置指向卷外 App 的符号链接" ln -s "$e2e_app" "$dmg_escape_root/Mimi Remote Mac.app"
  run_logged "生成卷外链接测试 DMG" \
    hdiutil create -quiet -volname "MimiEscapeTest" -srcfolder "$dmg_escape_root" -format UDZO "$dmg_escape_path"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" "$dmg_escape_path" >"$test_log" 2>&1; then
    fail "DMG 卷内符号链接指向卷外 App 时被 checker 放行。"
  fi
  grep -Fq '不得为符号链接' "$test_log" \
    || fail "DMG 卷内符号链接报错不准确：$(<"$test_log")"

  # 12. P2-10 DMG 单独传 --require-developer-id 必须检查镜像本体签名（未签名 DMG / ad-hoc DMG 均必拒）。
  local dmg_unsigned_root="$TEMP_DIR/dmg-unsigned-root"
  local dmg_unsigned_path="$TEMP_DIR/Mimi-Unsigned.dmg"
  mkdir -p "$dmg_unsigned_root"
  run_logged "复制已签名 App 到未签名 DMG 源目录" ditto "$e2e_app" "$dmg_unsigned_root/Mimi Remote Mac.app"
  run_logged "生成未签名测试 DMG" \
    hdiutil create -quiet -volname "MimiUnsignedTest" -srcfolder "$dmg_unsigned_root" -format UDZO "$dmg_unsigned_path"
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --require-developer-id "$dmg_unsigned_path" >"$test_log" 2>&1; then
    fail "未签名 DMG 在 --require-developer-id 下被 checker 放行。"
  fi
  grep -Eq 'not signed at all|DMG 镜像' "$test_log" \
    || fail "未签名 DMG 在 --require-developer-id 下的报错不准确：$(<"$test_log")"

  run_logged "给测试 DMG 签入 ad-hoc 签名" codesign --force --sign - "$dmg_unsigned_path"
  : > "$requirement_log"
  if PATH="$fake_bin_dir:$PATH" TEST_REAL_DEVELOPER_ID_REQUIREMENT=1 TEST_REQUIREMENT_LOG="$requirement_log" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --require-developer-id "$dmg_unsigned_path" >"$test_log" 2>&1; then
    fail "ad-hoc 签名 DMG 在 --require-developer-id 下被 checker 放行。"
  fi
  grep -Fq 'DMG 镜像' "$test_log" \
    || fail "ad-hoc 签名 DMG 在 --require-developer-id 下的报错未指出 DMG 镜像策略失败：$(<"$test_log")"
  grep -Fq -- '--test-requirement=' "$requirement_log" || fail "签名 DMG 没有交给系统 codesign 校验 Apple 证书链。"
  grep -Eq 'test-requirement: .*failed to satisfy.*requirement' "$test_log" \
    || fail "系统 codesign 未实际求值 DMG 的内联要求：$(<"$test_log")"

  echo "Mac 安装包真实 codesign 防回归测试通过（受控编译样例、符号链接、损坏/未签名、JIT entitlements 布尔与单切片/链接校验、混合切片与异 identifier、find 失败、选项边界、有效 ad-hoc 漏签、端到端集成漏签、DMG 卷外链接与 DMG 镜像签名全覆盖）。"
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-signing-test.XXXXXX")"
run_static_consistency_tests
if [[ "$STATIC_ONLY" != "1" ]]; then
  run_macos_codesign_tests
fi
