#!/usr/bin/env bash
set -euo pipefail

# 自测 check-source-size.sh：覆盖正常批量计数、含换行/控制字符路径回退、
# 不可读文件失败与批量 wc 异常输出防呆校验。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check-source-size.sh"
BASH_BIN="${BASH:-bash}"
REAL_WC="$(command -v wc)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-source-size-check.XXXXXX")"
trap 'chmod -R u+rX "$TEMP_DIR" 2>/dev/null || true; rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "源码体积检查自测失败：$1" >&2
  exit 1
}

make_fixture() {
  local name="$1"
  local dir="$TEMP_DIR/$name"
  mkdir -p "$dir/scripts"
  cp "$CHECK" "$dir/scripts/check-source-size.sh"
  printf '%s' "$dir"
}

write_lines() {
  local target="$1"
  local count="$2"
  awk -v n="$count" 'BEGIN { for (i = 1; i <= n; i++) print "line" }' > "$target"
}

run_fixture() {
  local dir="$1"
  local out_file="$2"
  local err_file="$3"
  local custom_path="${4:-$PATH}"
  local status=0
  PATH="$custom_path" "$BASH_BIN" "$dir/scripts/check-source-size.sh" >"$out_file" 2>"$err_file" || status=$?
  return "$status"
}

# 1. 空仓库（0 候选文件）应通过，验证空数组在 Bash 3.2 + set -u 下安全。
fixture="$(make_fixture empty)"
run_fixture "$fixture" "$TEMP_DIR/empty.out" "$TEMP_DIR/empty.err" \
  || fail "空仓库不应失败：$(cat "$TEMP_DIR/empty.err")"
grep -q '源码体积检查通过' "$TEMP_DIR/empty.out" \
  || fail "空仓库应输出通过信息：$(cat "$TEMP_DIR/empty.out")"

# 2. 正常多文件批次（含空格路径、测试文件上限、排除路径）通过且保持批量 wc 收益。
fixture="$(make_fixture normal-batch)"
mkdir -p "$fixture/pkg with space" "$fixture/vendor/dep"
write_lines "$fixture/a.go" 10
write_lines "$fixture/b.go" 2000
write_lines "$fixture/pkg with space/c.swift" 25
write_lines "$fixture/d_test.go" 2500
write_lines "$fixture/e.cs" 5
write_lines "$fixture/vendor/dep/huge.go" 3000
write_lines "$fixture/generated.pb.go" 3000

count_bin="$TEMP_DIR/bin-count"
mkdir -p "$count_bin"
wc_count_log="$TEMP_DIR/wc-normal.log"
cat > "$count_bin/wc" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$wc_count_log"
exec "$REAL_WC" "\$@"
SH
chmod +x "$count_bin/wc"

run_fixture "$fixture" "$TEMP_DIR/normal.out" "$TEMP_DIR/normal.err" "$count_bin:$PATH" \
  || fail "正常批次不应失败：$(cat "$TEMP_DIR/normal.err")"
wc_invocations="$(awk 'END { print NR + 0 }' "$wc_count_log")"
[[ "$wc_invocations" -eq 1 ]] \
  || fail "5 个普通文件应合并为 1 次批量 wc，实际调用了 $wc_invocations 次"

# 3. 跨批次边界（201 个普通文件 -> 200 文件带 total + 1 文件无 total）。
fixture="$(make_fixture multi-batch)"
for (( i = 1; i <= 201; i++ )); do
  printf 'package p\n' > "$fixture/f_${i}.go"
done
wc_multi_log="$TEMP_DIR/wc-multi.log"
cat > "$count_bin/wc" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$wc_multi_log"
exec "$REAL_WC" "\$@"
SH
chmod +x "$count_bin/wc"
run_fixture "$fixture" "$TEMP_DIR/multi.out" "$TEMP_DIR/multi.err" "$count_bin:$PATH" \
  || fail "跨批次（201 文件）不应失败：$(cat "$TEMP_DIR/multi.err")"
multi_invocations="$(awk 'END { print NR + 0 }' "$wc_multi_log")"
[[ "$multi_invocations" -eq 2 ]] \
  || fail "201 个普通文件应拆成 2 次批量 wc，实际调用了 $multi_invocations 次"

# 4. 正常生产文件超限（2001 行）必须拦截。
fixture="$(make_fixture over-limit)"
write_lines "$fixture/ok.go" 10
write_lines "$fixture/too_big.go" 2001
if run_fixture "$fixture" "$TEMP_DIR/over.out" "$TEMP_DIR/over.err"; then
  fail "2001 行生产文件必须拦截"
fi
grep -q '源码体积超限：too_big.go (2001 行，上限 2000)' "$TEMP_DIR/over.err" \
  || fail "超限错误未准确报告 too_big.go：$(cat "$TEMP_DIR/over.err")"

# 5a. 误放行回归 1：含换行文件名排在 2001 行的 b.go 前，b.go 仍必须被准确拦截。
fixture="$(make_fixture newline-before-over)"
nl_name_1=$'a\n0.go'
nl_name_2=$'a\nfoo.go'
write_lines "$fixture/$nl_name_1" 1
write_lines "$fixture/$nl_name_2" 2
write_lines "$fixture/b.go" 2001
if run_fixture "$fixture" "$TEMP_DIR/nl1.out" "$TEMP_DIR/nl1.err"; then
  fail "含换行文件排在超限 b.go 前时不得误放行"
fi
grep -q '源码体积超限：b.go (2001 行，上限 2000)' "$TEMP_DIR/nl1.err" \
  || fail "含换行文件存在时未报告 b.go 超限：$(cat "$TEMP_DIR/nl1.err")"

# 5b. 含换行文件本身超限（2001 行）也必须被准确拦截。
fixture="$(make_fixture newline-over-itself)"
nl_over=$'a\nover.go'
write_lines "$fixture/$nl_over" 2001
write_lines "$fixture/b.go" 1
if run_fixture "$fixture" "$TEMP_DIR/nl2.out" "$TEMP_DIR/nl2.err"; then
  fail "含换行文件本身超过 2000 行时必须拦截"
fi
grep -q '2001 行，上限 2000' "$TEMP_DIR/nl2.err" \
  || fail "含换行文件自身超限未报告行数：$(cat "$TEMP_DIR/nl2.err")"

# 5c. 含换行/回车/制表符且未超限的文件，与普通文件混排时应正常通过。
fixture="$(make_fixture special-chars-ok)"
write_lines "$fixture/"$'a\nb.go' 10
write_lines "$fixture/"$'a\rb.go' 10
write_lines "$fixture/"$'a\tb.go' 10
write_lines "$fixture/normal.go" 10
run_fixture "$fixture" "$TEMP_DIR/special.out" "$TEMP_DIR/special.err" \
  || fail "未超限的特殊字符路径不应失败：$(cat "$TEMP_DIR/special.err")"

# 6. 误放行回归 2：不可读文件必须返回非零且不得报告通过。
if [[ "$(id -u)" -ne 0 ]]; then
  # 6a. 唯一候选文件不可读。
  fixture="$(make_fixture unreadable-only)"
  write_lines "$fixture/only.go" 5
  chmod 000 "$fixture/only.go"
  [[ ! -r "$fixture/only.go" ]] || fail "测试夹具未能构造不可读文件"
  if run_fixture "$fixture" "$TEMP_DIR/unr1.out" "$TEMP_DIR/unr1.err"; then
    fail "唯一候选源文件不可读时不得返回 0"
  fi
  if grep -q '源码体积检查通过' "$TEMP_DIR/unr1.out"; then
    fail "唯一候选源文件不可读时不得报告通过"
  fi

  # 6b. 同一批次包含可读文件与不可读文件。
  fixture="$(make_fixture unreadable-mixed)"
  write_lines "$fixture/a.go" 5
  write_lines "$fixture/locked.go" 5
  write_lines "$fixture/z.go" 5
  chmod 000 "$fixture/locked.go"
  if run_fixture "$fixture" "$TEMP_DIR/unr2.out" "$TEMP_DIR/unr2.err"; then
    fail "批次内存在不可读文件时不得返回 0"
  fi
  if grep -q '源码体积检查通过' "$TEMP_DIR/unr2.out"; then
    fail "批次内存在不可读文件时不得报告通过"
  fi

  # 6c. 含换行且不可读的文件（单文件回退分支）。
  fixture="$(make_fixture unreadable-newline)"
  nl_locked=$'a\nlocked.go'
  write_lines "$fixture/$nl_locked" 5
  chmod 000 "$fixture/$nl_locked"
  if run_fixture "$fixture" "$TEMP_DIR/unr3.out" "$TEMP_DIR/unr3.err"; then
    fail "含换行且不可读的文件不得返回 0"
  fi
  if grep -q '源码体积检查通过' "$TEMP_DIR/unr3.out"; then
    fail "含换行且不可读的文件不得报告通过"
  fi
fi

# 7. 批量 wc 异常输出防呆校验（即使伪造 wc 返回 0，计数缺失/错位/格式异常也必须失败）。
assert_fake_wc_fails() {
  local case_name="$1"
  local fake_body="$2"
  local fixture_dir fake_bin
  fixture_dir="$(make_fixture "fake-$case_name")"
  write_lines "$fixture_dir/a.go" 3
  write_lines "$fixture_dir/b.go" 4
  fake_bin="$TEMP_DIR/bin-$case_name"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/wc" <<SH
#!/usr/bin/env bash
$fake_body
SH
  chmod +x "$fake_bin/wc"
  if run_fixture "$fixture_dir" "$TEMP_DIR/fake-$case_name.out" "$TEMP_DIR/fake-$case_name.err" "$fake_bin:$PATH"; then
    fail "异常 wc 场景 [$case_name] 必须返回非零"
  fi
  if grep -q '源码体积检查通过' "$TEMP_DIR/fake-$case_name.out"; then
    fail "异常 wc 场景 [$case_name] 不得报告通过"
  fi
}

assert_fake_wc_fails "nonzero-exit" '
shift 2
printf "  3 %s\n  4 %s\n  7 total\n" "$1" "$2"
exit 1
'

assert_fake_wc_fails "empty-stdout" '
exit 0
'

assert_fake_wc_fails "missing-record" '
shift 2
printf "  3 %s\n  3 total\n" "$1"
exit 0
'

assert_fake_wc_fails "missing-total" '
shift 2
printf "  3 %s\n  4 %s\n" "$1" "$2"
exit 0
'

assert_fake_wc_fails "swapped-paths" '
shift 2
printf "  4 %s\n  3 %s\n  7 total\n" "$2" "$1"
exit 0
'

assert_fake_wc_fails "non-numeric-count" '
shift 2
printf "  abc %s\n  4 %s\n  4 total\n" "$1" "$2"
exit 0
'

assert_fake_wc_fails "bad-total-sum" '
shift 2
printf "  3 %s\n  4 %s\n  99 total\n" "$1" "$2"
exit 0
'

assert_fake_wc_fails "extra-line" '
shift 2
printf "  3 %s\n  4 %s\n  7 total\n  0 extra\n" "$1" "$2"
exit 0
'

assert_fake_wc_fails "truncated-no-newline" '
shift 2
printf "  3 %s\n  4 %s\n  7 total" "$1" "$2"
exit 0
'

# 8. 真实仓库工作树也必须通过。
"$BASH_BIN" "$CHECK" >"$TEMP_DIR/repo.out" 2>"$TEMP_DIR/repo.err" \
  || fail "当前仓库运行 check-source-size.sh 失败：$(cat "$TEMP_DIR/repo.err")"
grep -q '源码体积检查通过' "$TEMP_DIR/repo.out" \
  || fail "当前仓库未输出通过信息：$(cat "$TEMP_DIR/repo.out")"

echo "源码体积检查自测通过（${BASH_BIN}）。"
