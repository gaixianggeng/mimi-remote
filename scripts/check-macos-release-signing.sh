#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=""

cleanup() {
  # Bash 3.2 在 main 返回后会销毁 local 变量，因此清理路径必须保存在全局作用域。
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-macos-release-signing.sh
  bash ./scripts/check-macos-release-signing.sh --self-test

正式校验需要以下 GitHub Actions Secrets：
  MACOS_SIGN_P12             Developer ID Application 证书和私钥的 base64 PKCS#12。
  MACOS_SIGN_PASSWORD        PKCS#12 导出密码。
  MACOS_NOTARY_KEY           App Store Connect API .p8 文件的 base64 内容。
  MACOS_NOTARY_KEY_ID        10 位 API Key ID。
  MACOS_NOTARY_ISSUER_ID     App Store Connect Issuer UUID。

脚本只检查凭据结构和证书类型，不打印证书正文、私钥或密码。
EOF
}

fail() {
  echo "macOS Release 签名门禁失败：$1" >&2
  exit 1
}

valid_key_id() {
  [[ "$1" =~ ^[A-Z0-9]{10}$ ]]
}

valid_issuer_id() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

decode_base64() {
  local value="$1"
  local output="$2"
  if printf '%s' "$value" | base64 --decode > "$output" 2>/dev/null; then
    return
  fi
  printf '%s' "$value" | base64 -D > "$output" 2>/dev/null
}

self_test() {
  valid_key_id "ABC123DEF4"
  ! valid_key_id "too-short"
  valid_issuer_id "12345678-1234-abcd-9876-1234567890ab"
  ! valid_issuer_id "not-a-uuid"
  echo "macOS Release 签名门禁自测通过。"
}

main() {
  case "${1:-}" in
    "") ;;
    --self-test) self_test; return ;;
    -h|--help) usage; return ;;
    *) usage >&2; exit 2 ;;
  esac

  for name in MACOS_SIGN_P12 MACOS_SIGN_PASSWORD MACOS_NOTARY_KEY MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID; do
    [[ -n "${!name:-}" ]] || fail "缺少 ${name}"
  done
  valid_key_id "$MACOS_NOTARY_KEY_ID" || fail "MACOS_NOTARY_KEY_ID 格式无效"
  valid_issuer_id "$MACOS_NOTARY_ISSUER_ID" || fail "MACOS_NOTARY_ISSUER_ID 格式无效"

  for command_name in base64 mktemp openssl; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 ${command_name}"
  done

  local p12_path
  local certificate_path
  local certificate_subject
  local key_path
  WORK_DIR="$(mktemp -d -t mimi-macos-signing-check)"
  p12_path="${WORK_DIR}/developer-id.p12"
  certificate_path="${WORK_DIR}/developer-id.pem"
  key_path="${WORK_DIR}/notary-key.p8"
  trap cleanup EXIT

  decode_base64 "$MACOS_SIGN_P12" "$p12_path" || fail "MACOS_SIGN_P12 不是有效 base64"
  decode_base64 "$MACOS_NOTARY_KEY" "$key_path" || fail "MACOS_NOTARY_KEY 不是有效 base64"
  chmod 600 "$p12_path" "$key_path"

  if ! openssl pkcs12 -in "$p12_path" -passin env:MACOS_SIGN_PASSWORD -clcerts -nokeys \
    -out "$certificate_path" >/dev/null 2>&1; then
    # OpenSSL 3 默认不会加载 RC2/3DES；Apple Keychain 兼容的 P12 需要 legacy provider。
    openssl pkcs12 -legacy -in "$p12_path" -passin env:MACOS_SIGN_PASSWORD -clcerts -nokeys \
      -out "$certificate_path" >/dev/null 2>&1 \
      || fail "MACOS_SIGN_P12 无法用 MACOS_SIGN_PASSWORD 解密"
  fi
  certificate_subject="$(openssl x509 -in "$certificate_path" -noout -subject 2>/dev/null)"
  grep -Fq 'Developer ID Application:' <<<"$certificate_subject" \
    || fail "PKCS#12 不是 Developer ID Application 证书"
  openssl pkey -in "$key_path" -noout >/dev/null 2>&1 \
    || fail "MACOS_NOTARY_KEY 不是有效的 PKCS#8 私钥"

  echo "macOS Release 签名门禁通过：Developer ID 与 Notary API 凭据结构有效。"
}

main "$@"
