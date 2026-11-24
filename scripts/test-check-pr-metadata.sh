#!/usr/bin/env bash
set -euo pipefail

# 自测 check-pr-metadata.sh：覆盖正常 Refs、空正文、仅标题有引用、
# 自动关闭词独立提示、shell 特殊字符防注入以及任意 cwd 运行。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check-pr-metadata.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-pr-metadata-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "PR 元数据检查自测失败：$1" >&2
  exit 1
}

run_case() {
  local case_name="$1"
  local expected_exit="$2"
  local title="$3"
  local body="$4"
  local workdir="${5:-$ROOT_DIR}"

  local out_file="$TEMP_DIR/${case_name}.out"
  local err_file="$TEMP_DIR/${case_name}.err"
  local status=0

  set +e
  (
    cd "$workdir"
    PR_TITLE="$title" PR_BODY="$body" bash "$CHECK" >"$out_file" 2>"$err_file"
  )
  status=$?
  set -e

  if [[ "$expected_exit" == "0" && "$status" -ne 0 ]]; then
    fail "${case_name} 预期成功，实际退出码 ${status}；stderr=$(cat "$err_file")；stdout=$(cat "$out_file")"
  fi
  if [[ "$expected_exit" != "0" && "$status" -eq 0 ]]; then
    fail "${case_name} 预期失败，实际成功；stdout=$(cat "$out_file")"
  fi
}

# 1. 正常正文含 Refs #（应成功，且不应触发自动关闭词提示）
run_case "valid_body_refs" "0" \
  "ci(github): add metadata check" \
  $'背景说明\n\nRefs #123\n'
grep -Fq "[PASS] PR 正文包含 Refs #<编号> 引用。" "$TEMP_DIR/valid_body_refs.out" \
  || fail "valid_body_refs 缺少通过输出：$(cat "$TEMP_DIR/valid_body_refs.out")"
if grep -Fq "[NOTICE]" "$TEMP_DIR/valid_body_refs.out"; then
  fail "valid_body_refs 不应输出自动关闭词提示：$(cat "$TEMP_DIR/valid_body_refs.out")"
fi

# 1b. 大小写不敏感、最小编号、多空白及中文带空白分隔（应成功）
run_case "valid_body_refs_lowercase_single_digit" "0" \
  "fix: lowercase refs" \
  "refs #1"
run_case "valid_body_refs_case_and_cjk_spaced" "0" \
  "fix: lowercase refs" \
  $'关联 refs   #456 说明'

# 1c. Unicode 空白分隔（U+00A0 不换行空格、U+3000 全角空格，应成功）
run_case "valid_body_refs_unicode_nbsp" "0" \
  "ci: unicode nbsp" \
  $'Refs\xc2\xa0#123'
run_case "valid_body_refs_unicode_ideographic_space" "0" \
  "ci: unicode ideographic space" \
  $'Refs\xe3\x80\x80#123'

# 1d. 非法边界形式与中文无分隔紧邻不得误通过（符合 Python 默认 Unicode \b 语义）
run_case "invalid_refs_prefix" "1" "ci: test" "XRefs #123"
run_case "invalid_refs_no_space" "1" "ci: test" "Refs#123"
run_case "invalid_refs_suffix" "1" "ci: test" "Refs #123abc"
run_case "invalid_refs_no_number" "1" "ci: test" "Refs #"
run_case "invalid_refs_cjk_adjacent" "1" "ci: test" "关联Refs #123说明"
run_case "invalid_refs_cjk_prefix" "1" "ci: test" "关联Refs #123"
run_case "invalid_refs_cjk_suffix" "1" "ci: test" "Refs #123说明"

# 2. 空正文（应失败）
run_case "empty_body" "1" "ci: empty body" ""
grep -Fq "PR 正文为空，缺少 Refs #<编号>" "$TEMP_DIR/empty_body.err" \
  || fail "empty_body 未报告正文为空：$(cat "$TEMP_DIR/empty_body.err")"
grep -Fq "PR 标题中也未检测到 Refs # 引用" "$TEMP_DIR/empty_body.err" \
  || fail "empty_body 未说明标题也缺少引用：$(cat "$TEMP_DIR/empty_body.err")"

# 2b. 未设置 PR_BODY / PR_TITLE 环境变量时应按空正文安全失败，不得因 set -u 异常
set +e
env -u PR_BODY -u PR_TITLE bash "$CHECK" >"$TEMP_DIR/unset_env.out" 2>"$TEMP_DIR/unset_env.err"
unset_status=$?
set -e
if [[ "$unset_status" -eq 0 ]]; then
  fail "unset_env 预期失败，实际成功"
fi
grep -Fq "PR 正文为空，缺少 Refs #<编号>" "$TEMP_DIR/unset_env.err" \
  || fail "unset_env 未按空正文正常报告：$(cat "$TEMP_DIR/unset_env.err")"

# 3. 只有标题有引用而正文缺失（应失败，且输出明确区分标题/正文并提示补入正文）
run_case "title_only_refs" "1" \
  "feat: example change (Refs #789)" \
  "这里写了改动说明，但没有写 issue 引用。"
grep -Fq "PR 正文缺少 Refs #<编号>；仅在 PR 标题中检测到 Refs # 引用" "$TEMP_DIR/title_only_refs.err" \
  || fail "title_only_refs 未区分标题有引用而正文缺失：$(cat "$TEMP_DIR/title_only_refs.err")"
grep -Fq "补入正文" "$TEMP_DIR/title_only_refs.err" \
  || fail "title_only_refs 未提示补入正文：$(cat "$TEMP_DIR/title_only_refs.err")"

# 3b. 空正文但标题有引用（应失败，同样区分标题与空正文）
run_case "empty_body_title_refs" "1" \
  "Refs #790" \
  "   "
grep -Fq "PR 正文为空，缺少 Refs #<编号>；但 PR 标题中检测到 Refs # 引用" "$TEMP_DIR/empty_body_title_refs.err" \
  || fail "empty_body_title_refs 未区分空正文与标题引用：$(cat "$TEMP_DIR/empty_body_title_refs.err")"

# 3c. 仅标题使用 Unicode 空格写 Refs #（正文缺失仍应失败，但应识别标题中的引用）
run_case "title_only_refs_unicode_nbsp" "1" \
  $'feat: example change (Refs\xc2\xa0#791)' \
  "正文缺少引用。"
grep -Fq "PR 正文缺少 Refs #<编号>；仅在 PR 标题中检测到 Refs # 引用" "$TEMP_DIR/title_only_refs_unicode_nbsp.err" \
  || fail "title_only_refs_unicode_nbsp 未识别标题中的 U+00A0 Refs 引用：$(cat "$TEMP_DIR/title_only_refs_unicode_nbsp.err")"
run_case "title_only_refs_unicode_ideographic_space" "1" \
  $'feat: example change (Refs\xe3\x80\x80#792)' \
  "正文缺少引用。"
grep -Fq "PR 正文缺少 Refs #<编号>；仅在 PR 标题中检测到 Refs # 引用" "$TEMP_DIR/title_only_refs_unicode_ideographic_space.err" \
  || fail "title_only_refs_unicode_ideographic_space 未识别标题中的 U+3000 Refs 引用：$(cat "$TEMP_DIR/title_only_refs_unicode_ideographic_space.err")"

# 4. 正文有 Refs 但含自动关闭词（应成功，且输出独立提示及范围/commit message 说明）
run_case "valid_refs_with_autoclose" "0" \
  "fix: sample change" \
  $'Refs #101\nFixes #101\nCloses: owner/repo#202\nresolved #303'
grep -Fq "[PASS] PR 正文包含 Refs #<编号> 引用。" "$TEMP_DIR/valid_refs_with_autoclose.out" \
  || fail "valid_refs_with_autoclose 缺少通过输出：$(cat "$TEMP_DIR/valid_refs_with_autoclose.out")"
grep -Fq "[NOTICE] 独立提示（不单独导致检查失败）" "$TEMP_DIR/valid_refs_with_autoclose.out" \
  || fail "valid_refs_with_autoclose 缺少独立提示：$(cat "$TEMP_DIR/valid_refs_with_autoclose.out")"
for fragment in \
  "Fixes #101" \
  "Closes: owner/repo#202" \
  "resolved #303" \
  "fix/fixed/fixes" \
  "close/closed/closes" \
  "resolve/resolved/resolves" \
  "带冒号形式" \
  "owner/repo#123" \
  "commit message"; do
  grep -Fq "$fragment" "$TEMP_DIR/valid_refs_with_autoclose.out" \
    || fail "valid_refs_with_autoclose 输出缺少必要说明 ${fragment}：$(cat "$TEMP_DIR/valid_refs_with_autoclose.out")"
done

# 4b. 标题含自动关闭词而正文有 Refs（应成功，并提示标题中的关闭词）
run_case "title_autoclose_body_refs" "0" \
  "Fixes: #404" \
  "Refs #404"
grep -Fq "PR 标题" "$TEMP_DIR/title_autoclose_body_refs.out" \
  || fail "title_autoclose_body_refs 未标明在 PR 标题命中关闭词：$(cat "$TEMP_DIR/title_autoclose_body_refs.out")"

# 4c. 正文缺 Refs 且含自动关闭词（因缺 Refs 失败，并同时输出独立关闭词提示）
run_case "missing_refs_and_autoclose" "1" \
  "fix: missing refs" \
  "Closes #505"
grep -Fq "[FAIL] PR 正文缺少 Refs #<编号>" "$TEMP_DIR/missing_refs_and_autoclose.err" \
  || fail "missing_refs_and_autoclose 未因缺 Refs 失败：$(cat "$TEMP_DIR/missing_refs_and_autoclose.err")"
grep -Fq "[NOTICE] 独立提示（不单独导致检查失败）" "$TEMP_DIR/missing_refs_and_autoclose.out" \
  || fail "missing_refs_and_autoclose 缺 Refs 时也应同时输出独立关闭词提示：$(cat "$TEMP_DIR/missing_refs_and_autoclose.out")"
grep -Fq "Closes #505" "$TEMP_DIR/missing_refs_and_autoclose.out" \
  || fail "missing_refs_and_autoclose 未指出命中的关闭词：$(cat "$TEMP_DIR/missing_refs_and_autoclose.out")"

# 5. 包含 $(id)、反引号、引号、换行等 shell 特殊字符的负例（不得被当成命令执行）
subshell_marker="$TEMP_DIR/pwned-subshell"
backtick_marker="$TEMP_DIR/pwned-backtick"
title_marker="$TEMP_DIR/pwned-title"
# 刻意在单引号中保留字面量的 $() / 反引号 / $HOME，验证检查脚本不会将其求值。
# shellcheck disable=SC2016
evil_title='$(id) `touch "'"$title_marker"'"` "quoted" '\''single'\'''
# shellcheck disable=SC2016
evil_body='第一行 $(id) $(touch "'"$subshell_marker"'")
第二行 `touch "'"$backtick_marker"'"`
第三行 "双引号" '\''单引号'\'' \反斜杠 $HOME * ? [a]
::error::injected'

run_case "shell_metacharacters_negative" "1" "$evil_title" "$evil_body"
[[ ! -e "$subshell_marker" ]] || fail "PR_BODY 中的 \$() 被当作命令执行"
[[ ! -e "$backtick_marker" ]] || fail "PR_BODY 中的反引号被当作命令执行"
[[ ! -e "$title_marker" ]] || fail "PR_TITLE 中的反引号被当作命令执行"
if grep -Fq "uid=" "$TEMP_DIR/shell_metacharacters_negative.out" "$TEMP_DIR/shell_metacharacters_negative.err"; then
  fail "输入中的 \$(id) 被意外求值"
fi
if grep -Fq "::error::injected" "$TEMP_DIR/shell_metacharacters_negative.out" "$TEMP_DIR/shell_metacharacters_negative.err"; then
  fail "不应回显不可信正文中的 workflow command"
fi

# 5b. 含 shell 特殊字符但正文确实包含 Refs # 时仍按文本规则通过且不执行命令
pass_marker="$TEMP_DIR/pwned-pass"
# shellcheck disable=SC2016
evil_valid_body='$(id) $(touch "'"$pass_marker"'") `uname -a` "quotes" '\''single'\''
Refs #606'
run_case "shell_metacharacters_positive" "0" "$evil_title" "$evil_valid_body"
[[ ! -e "$pass_marker" ]] || fail "正例中 PR_BODY 的 \$() 被当作命令执行"
[[ ! -e "$title_marker" ]] || fail "正例中 PR_TITLE 的反引号被当作命令执行"

# 6. 在非仓库目录（任意 cwd）下也必须正常运行
run_case "arbitrary_cwd_pass" "0" "ci: cwd test" "Refs #707" "$TEMP_DIR"
run_case "arbitrary_cwd_fail" "1" "ci: cwd test" "no refs here" "$TEMP_DIR"

echo "PR 元数据检查自测通过。"
