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
  --static-only  仅运行跨平台静态一致性自测（可在 Linux/macOS 的 check-packaging.sh 中执行）。
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

    grep -Fq "codesign -d --verbose=4 \"\$${check_var}\"" "$check_script" \
      || fail "${check_script} 未检查 ${binary_name}（\$${check_var}）的签名详情（Identifier / Team ID / Developer ID）。"
  done <<<"$embedded_list"

  if [[ "$binary_count" -lt 5 ]]; then
    fail "从 ${embed_script} 提取的内嵌二进制数量异常（${binary_count} < 5）。"
  fi

  grep -Fq 'find "$APP_PATH" -type f -print0' "$build_script" \
    || fail "${build_script} 未在封包/公证前枚举 App 内全部 Mach-O。"
  grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' "$build_script" \
    || fail "${build_script} 未对枚举到的全部 Mach-O 执行严格签名验证。"
  grep -Fq 'find "$APP_PATH" -type f -print0' "$check_script" \
    || fail "${check_script} 未枚举 App 内全部 Mach-O。"
  grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' "$check_script" \
    || fail "${check_script} 未对枚举到的全部 Mach-O 执行严格签名验证。"
  grep -Fq 'candidate_team_identifier' "$check_script" \
    || fail "${check_script} 未对枚举到的全部 Mach-O 检查 Team ID。"
  grep -Fq -- '--app-only 只能与 --snapshot 同时使用' "$build_script" \
    || fail "${build_script} 必须限制 --app-only 只能与 --snapshot 同时使用。"
  grep -Fq -- '--require-notarization 必须校验完整 DMG' "$check_script" \
    || fail "${check_script} 必须禁止 --app 绕过 --require-notarization 的完整 DMG 校验。"
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

  echo "Mac 安装包签名静态一致性自测通过（含漏签变异反例）。"
}

find_sample_macho() {
  local candidate
  for candidate in /usr/bin/true /bin/echo; do
    if [[ -x "$candidate" ]] && [[ "$(file -b "$candidate")" == Mach-O* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
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

  cp "$sample_macho" "$app_dir/Contents/MacOS/TestApp"
  chmod 0755 "$app_dir/Contents/MacOS/TestApp"
  cp "$sample_macho" "$app_dir/Contents/Resources/helper-signed"
  chmod 0755 "$app_dir/Contents/Resources/helper-signed"

  codesign --force --sign - \
    --identifier com.gaixianggeng.mimi.mac.signing-test.helper \
    --options runtime --timestamp=none \
    "$app_dir/Contents/Resources/helper-signed" >/dev/null 2>&1
  codesign --force --sign - \
    --options runtime --timestamp=none \
    "$app_dir" >/dev/null 2>&1
}

run_macos_codesign_tests() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "真实 codesign 行为测试只能在 macOS (Darwin) 上运行；非 macOS 环境请传 --static-only。"
  fi
  for command_name in chmod codesign cp file mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少 macOS 测试命令 ${command_name}。"
  done

  local sample_macho
  sample_macho="$(find_sample_macho || true)"
  [[ -n "$sample_macho" ]] || fail "未找到可用的本机 Mach-O 样例二进制。"

  local app_dir="$TEMP_DIR/Test.app"
  local test_log="$TEMP_DIR/codesign-test.log"

  # 1. 基线：所有内嵌 Mach-O 与主 App 均正确签名 -> 必过。
  create_test_app_bundle "$app_dir" "$sample_macho"
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "合法签名的测试 App 未通过校验：$(<"$test_log")"

  # 2. 复现 v1.1.16 故障：内嵌 Mach-O 带被篡改/失效的残留签名（类似未重签的 Bun 产物），
  # 即使重新 seal 了主 App，枚举校验仍必须失败；重签该内嵌二进制并重封主 App 后必过。
  local leaky_bin="$app_dir/Contents/Resources/mimi-leaky-adapter"
  cp "$sample_macho" "$leaky_bin"
  chmod 0755 "$leaky_bin"
  codesign --force --sign - --identifier com.gaixianggeng.mimi.mac.signing-test.leaky --timestamp=none "$leaky_bin" >/dev/null 2>&1
  # 在已签名的文件主体中段篡改字节（保持 Mach-O 头部可识别），真实触发签名哈希失效。
  local leaky_size leaky_offset
  leaky_size="$(wc -c < "$leaky_bin" | tr -d '[:space:]')"
  leaky_offset=$((leaky_size / 2))
  printf 'TAMPERED_PAYLOAD' | dd of="$leaky_bin" bs=1 seek="$leaky_offset" conv=notrunc >/dev/null 2>&1
  [[ "$(file -b "$leaky_bin")" == Mach-O* ]] \
    || fail "篡改测试样例后无法继续识别为 Mach-O。"
  codesign --force --sign - --options runtime --timestamp=none "$app_dir" >/dev/null 2>&1

  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "包含损坏签名内嵌 Mach-O 的 App 被放行（未捕获类似 mimi-agy-adapter 的漏签问题）。"
  fi
  grep -Fq 'mimi-leaky-adapter' "$test_log" \
    || fail "损坏签名用例失败输出未包含 mimi-leaky-adapter：$(<"$test_log")"
  grep -Eq 'invalid signature|failed strict validation' "$test_log" \
    || fail "损坏签名用例失败输出未包含签名校验失败原因：$(<"$test_log")"

  codesign --force --sign - \
    --identifier com.gaixianggeng.mimi.mac.signing-test.leaky \
    --options runtime --timestamp=none \
    "$leaky_bin" >/dev/null 2>&1
  codesign --force --sign - --options runtime --timestamp=none "$app_dir" >/dev/null 2>&1
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "修复损坏签名内嵌 Mach-O 后仍校验失败：$(<"$test_log")"

  # 3. 完全未签名的内嵌 Mach-O -> 必败；补签并重封主 App 后必过。
  local unsigned_bin="$app_dir/Contents/Resources/mimi-unsigned-sidecar"
  cp "$sample_macho" "$unsigned_bin"
  chmod 0755 "$unsigned_bin"
  codesign --remove-signature "$unsigned_bin" >/dev/null 2>&1
  codesign --force --sign - --options runtime --timestamp=none "$app_dir" >/dev/null 2>&1

  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1; then
    fail "包含未签名内嵌 Mach-O 的 App 被放行。"
  fi
  grep -Fq 'mimi-unsigned-sidecar' "$test_log" \
    || fail "未签名用例失败输出未包含 mimi-unsigned-sidecar：$(<"$test_log")"

  codesign --force --sign - \
    --identifier com.gaixianggeng.mimi.mac.signing-test.unsigned \
    --options runtime --timestamp=none \
    "$unsigned_bin" >/dev/null 2>&1
  codesign --force --sign - --options runtime --timestamp=none "$app_dir" >/dev/null 2>&1
  bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures "$app_dir" >"$test_log" 2>&1 \
    || fail "补签未签名内嵌 Mach-O 后仍校验失败：$(<"$test_log")"

  # 4. ad-hoc 签名在 --require-team-signing 下必败。
  if bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "ad-hoc 签名在 --require-team-signing 下被放行。"
  fi
  grep -Fq '缺少有效的非空 Team ID' "$test_log" \
    || fail "--require-team-signing 未报告主 App 缺少有效 Team ID：$(<"$test_log")"

  # 5. 验证全量 Mach-O 枚举下的 Team ID 与 Developer ID Authority 校验：
  # --verify 仍然走真实 /usr/bin/codesign，仅对 -d --verbose=4 注入受控 Team/Authority 元数据，
  # 模拟无证书环境下「内嵌二进制漏出正式签名列表，仅带 ad-hoc / 第三方 Team / Apple Development 签名」的场景。
  local fake_bin_dir="$TEMP_DIR/fake-bin"
  mkdir -p "$fake_bin_dir"
  cat > "$fake_bin_dir/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--verbose=4" ]]; then
  target="${3:-}"
  if [[ "$target" == *"mimi-leaky-adapter" ]]; then
    printf 'Executable=%s\n' "$target"
    printf 'Identifier=com.gaixianggeng.mimi.mac.signing-test.leaky\n'
    if [[ -n "${TEST_LEAKY_AUTHORITY:-}" ]]; then
      printf 'Authority=%s\n' "$TEST_LEAKY_AUTHORITY"
    fi
    printf 'TeamIdentifier=%s\n' "${TEST_LEAKY_TEAM:-not set}"
    exit 0
  fi
  printf 'Executable=%s\n' "$target"
  printf 'Identifier=com.gaixianggeng.mimi.mac.signing-test\n'
  printf 'Authority=Developer ID Application: Mimi Test (TEAM123456)\n'
  printf 'TeamIdentifier=TEAM123456\n'
  exit 0
fi
exec /usr/bin/codesign "$@"
STUB
  chmod 0755 "$fake_bin_dir/codesign"

  # 5a. 内嵌 Mach-O 为 TeamIdentifier=not set（例如漏签的 linker ad-hoc 二进制）-> 必败。
  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TEAM="not set" TEST_LEAKY_AUTHORITY="" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "内嵌 Mach-O 缺少 Team ID 时 --require-team-signing 未拦截。"
  fi
  grep -Fq 'mimi-leaky-adapter 的 Team ID' "$test_log" \
    || fail "Team ID 不一致报错缺少目标二进制名：$(<"$test_log")"

  # 5b. 内嵌 Mach-O 残留第三方 Developer ID（例如上游预编译运行时）-> 必败。
  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TEAM="7FRXF46ZSN" TEST_LEAKY_AUTHORITY="Developer ID Application: Upstream (7FRXF46ZSN)" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1; then
    fail "内嵌 Mach-O 带第三方 Team ID 时 --require-team-signing 未拦截。"
  fi
  grep -Fq 'mimi-leaky-adapter 的 Team ID' "$test_log" \
    || fail "第三方 Team ID 报错缺少目标二进制名：$(<"$test_log")"

  # 5c. 同 Team ID 但非 Developer ID Application（例如 Apple Development）-> team 校验通过，但 notarization 校验必败。
  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TEAM="TEAM123456" TEST_LEAKY_AUTHORITY="Apple Development: Mimi Test (TEAM123456)" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-team-signing "$app_dir" >"$test_log" 2>&1 \
    || fail "同 Team ID 的开发签名应通过 --require-team-signing：$(<"$test_log")"

  if PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TEAM="TEAM123456" TEST_LEAKY_AUTHORITY="Apple Development: Mimi Test (TEAM123456)" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-notarization "$app_dir" >"$test_log" 2>&1; then
    fail "非 Developer ID Application 签名在 --require-notarization 下被放行。"
  fi
  grep -Fq 'mimi-leaky-adapter 不是有效的 Developer ID Application 签名' "$test_log" \
    || fail "Developer ID 校验报错不准确：$(<"$test_log")"

  # 5d. 全部 Mach-O 同 Team ID 且为 Developer ID Application -> 必过。
  PATH="$fake_bin_dir:$PATH" TEST_LEAKY_TEAM="TEAM123456" TEST_LEAKY_AUTHORITY="Developer ID Application: Mimi Test (TEAM123456)" \
    bash "$ROOT_DIR/scripts/check-macos-installer.sh" --verify-app-macho-signatures --require-notarization "$app_dir" >"$test_log" 2>&1 \
    || fail "全部 Mach-O 具备同 Team ID Developer ID 签名时应通过 --require-notarization：$(<"$test_log")"

  echo "Mac 安装包真实 codesign 防回归测试通过（损坏签名、未签名、Team ID 与 Developer ID 枚举校验均符合预期）。"
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-signing-test.XXXXXX")"
run_static_consistency_tests
if [[ "$STATIC_ONLY" != "1" ]]; then
  run_macos_codesign_tests
fi
