#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_CODE_IDENTIFIER="com.gaixianggeng.mimi-remote.agentd.dev"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/sign-agentd-dev-macos.sh <agentd 二进制>
  bash ./scripts/sign-agentd-dev-macos.sh --self-test

环境变量：
  MIMI_AGENTD_SIGN_IDENTITY   指定本机 codesign identity；默认选择 Apple Development。
  MIMI_AGENTD_CODE_IDENTIFIER 覆盖固定代码标识；默认 com.gaixianggeng.mimi-remote.agentd.dev。

本脚本只用于本机开发构建。正式 Release 使用 Developer ID 和 GoReleaser notarize 流水线。
EOF
}

fail() {
  echo "agentd 开发签名失败：$1" >&2
  exit 1
}

stable_requirement() {
  local requirement
  requirement="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$requirement" && "$requirement" == *"identifier"* && "$requirement" == *"anchor"* && "$requirement" != *"cdhash"* ]]
}

self_test() {
  stable_requirement 'designated => identifier "agentd" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID"'
  if stable_requirement 'designated => cdhash H"0123456789abcdef"'; then
    fail "cdhash-only 身份不应被判定为稳定签名"
  fi
  echo "agentd 开发签名判定自测通过。"
}

select_identity() {
  local identities
  local selected
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  selected="$(printf '%s\n' "$identities" | awk -F'"' '/"Apple Development:/ { print $2; exit }')"
  if [[ -z "$selected" ]]; then
    selected="$(printf '%s\n' "$identities" | awk -F'"' '/"Developer ID Application:/ { print $2; exit }')"
  fi
  [[ -n "$selected" ]] || fail "未找到 Apple Development 或 Developer ID Application 证书；请先在 Xcode 登录开发者账号"
  printf '%s\n' "$selected"
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    return
  fi
  if [[ $# -ne 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ $# -eq 1 ]] || exit 2
    return
  fi
  [[ "$(uname -s)" == "Darwin" ]] || fail "只支持 macOS"

  local binary="$1"
  local identity="${MIMI_AGENTD_SIGN_IDENTITY:-}"
  local identifier="${MIMI_AGENTD_CODE_IDENTIFIER:-$DEFAULT_CODE_IDENTIFIER}"
  local file_details
  local identities
  local requirement
  local signing_details
  [[ -f "$binary" && ! -L "$binary" ]] || fail "目标必须是普通文件：$binary"
  [[ -x "$binary" ]] || fail "目标没有可执行权限：$binary"
  [[ "$identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || fail "代码标识格式无效：$identifier"
  file_details="$(file "$binary")"
  grep -Fq 'Mach-O' <<<"$file_details" || fail "目标不是 macOS Mach-O：$binary"

  if [[ -z "$identity" ]]; then
    identity="$(select_identity)"
  fi
  identities="$(security find-identity -v -p codesigning)"
  grep -Fq "\"${identity}\"" <<<"$identities" \
    || fail "指定的签名 identity 不存在或无效：$identity"

  local timestamp=(--timestamp=none)
  if [[ "$identity" == Developer\ ID\ Application:* ]]; then
    timestamp=(--timestamp)
  fi
  codesign --force --options runtime "${timestamp[@]}" \
    --identifier "$identifier" --sign "$identity" "$binary"
  codesign --verify --strict --verbose=2 "$binary"

  requirement="$(codesign -d -r- "$binary" 2>&1 || true)"
  stable_requirement "$requirement" || fail "签名后仍没有稳定 designated requirement"
  signing_details="$(codesign -d --verbose=4 "$binary" 2>&1)"
  grep -Eq '^TeamIdentifier=[A-Z0-9]+' <<<"$signing_details" \
    || fail "签名后缺少 TeamIdentifier"

  echo "agentd 开发签名完成：identifier=${identifier} identity=${identity}"
}

main "$@"
