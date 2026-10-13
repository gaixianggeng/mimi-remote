#!/usr/bin/env bash
set -euo pipefail

# 自测 check-ios-localization.sh 的重复 key 检查：只用临时夹具，不读取 App 资源。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check-ios-localization.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-localization-check.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "本地化检查自测失败：$1" >&2
  exit 1
}

entry() {
  printf '"%s": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%s"}}}}' "$1" "$2"
}

printf '{"sourceLanguage": "en", "strings": {%s, %s}, "version": "1.1"}\n' \
  "$(entry ui.first First)" "$(entry ui.second Second)" > "$TEMP_DIR/clean.xcstrings"
printf '{"sourceLanguage": "en", "strings": {%s, %s, %s}, "version": "1.1"}\n' \
  "$(entry ui.first First)" "$(entry ui.second Second)" "$(entry ui.first first)" > "$TEMP_DIR/top-level.xcstrings"
printf '{"sourceLanguage": "en", "strings": {"ui.first": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "A", "value": "B"}}}}}, "version": "1.1"}\n' \
  > "$TEMP_DIR/nested.xcstrings"
printf '{"strings": {' > "$TEMP_DIR/invalid.xcstrings"

bash "$CHECK" --check-duplicates "$TEMP_DIR/clean.xcstrings" 2>"$TEMP_DIR/clean.err" \
  || fail "没有重复 key 的目录不应报错：$(cat "$TEMP_DIR/clean.err")"

for fixture in top-level nested; do
  if bash "$CHECK" --check-duplicates "$TEMP_DIR/$fixture.xcstrings" 2>"$TEMP_DIR/$fixture.err"; then
    fail "$fixture 重复 key 必须报错"
  fi
done
grep -q 'duplicate key.*: ui.first$' "$TEMP_DIR/top-level.err" || fail "顶层重复项需要指出 key：$(cat "$TEMP_DIR/top-level.err")"
grep -q 'duplicate key.*: value$' "$TEMP_DIR/nested.err" || fail "嵌套重复项需要指出 key：$(cat "$TEMP_DIR/nested.err")"

if bash "$CHECK" --check-duplicates "$TEMP_DIR/invalid.xcstrings" 2>"$TEMP_DIR/invalid.err"; then
  fail "无法解析的目录必须报错"
fi
grep -q 'Could not read String Catalog' "$TEMP_DIR/invalid.err" || fail "解析失败需要说明原因"

if bash "$CHECK" --check-duplicates 2>/dev/null; then
  fail "缺少文件参数时必须报错"
fi

# 仓库里的真实目录也必须通过，避免自测只覆盖夹具。
bash "$CHECK" --check-duplicates "$ROOT_DIR/ios/MimiRemote/Resources/Localizable.xcstrings" \
  || fail "仓库 Localizable.xcstrings 仍有重复 key"

echo "本地化检查自测通过"
