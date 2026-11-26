#!/usr/bin/env bash
# 定向回归测试：校验 scripts/bench-agy-acp-list.ts 的 ps 包装器不会把 exit 0 误判为扫描成功：
# 1) 自检探测通过后，后续快照为空或无有效 pid args 行（exit 0）时，必须标记 degraded 且 phase1Comparison.status != valid；
# 2) 自检探测通过后，异步 stdout/stderr 超过 maxBuffer（2 MiB，exit 0）被拒绝时，必须记为失败/降级而非 ok；
# 3) 自检探测本身返回空快照或超 maxBuffer（exit 0）时，必须记录自检降级而不误记 ok 或触发计数异常；
# 4) 正常有效 ps 快照时，保持 status=ok 与 phase1Comparison.status=valid。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for cmd in bun git python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令：${cmd}" >&2; exit 127; }
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-test-bench-agy-ps.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

make_fake_ps() {
  local dir="$1"
  local body="$2"
  mkdir -p "$dir"
  cat > "$dir/ps" <<EOF
#!/bin/sh
set -u
$body
EOF
  chmod +x "$dir/ps"
}

run_case() {
  local name="$1"
  local fake_bin="$2"
  local out_json="$TMP_DIR/${name}.json"
  local err_log="$TMP_DIR/${name}.stderr"
  PATH="$fake_bin:$PATH" bun "$ROOT_DIR/scripts/bench-agy-acp-list.ts" \
    --batches 1 --cold 1 --warm 2 --concurrency 1 \
    --json-out "$out_json" >/dev/null 2>"$err_log"
}

# 用例 1：探测通过，但后续快照全部为空（exit 0）
CASE1_BIN="$TMP_DIR/case1-bin"
CASE1_MARKER="$TMP_DIR/case1.probe-done"
make_fake_ps "$CASE1_BIN" "
if mkdir '$CASE1_MARKER' 2>/dev/null; then
  printf '  101 /usr/bin/init\\n'
fi
exit 0
"
run_case "probe-ok-then-empty" "$CASE1_BIN"

# 用例 2：探测通过，但后续快照仅含无效/不可解析行（exit 0）
CASE2_BIN="$TMP_DIR/case2-bin"
CASE2_MARKER="$TMP_DIR/case2.probe-done"
make_fake_ps "$CASE2_BIN" "
if mkdir '$CASE2_MARKER' 2>/dev/null; then
  printf '  101 /usr/bin/init\\n'
else
  printf '  PID COMMAND\\n  0 /sbin/kernel\\n  123   \\n   \\n'
fi
exit 0
"
run_case "probe-ok-then-unparseable" "$CASE2_BIN"

# 用例 3：探测通过，但后续异步 stdout 超过 2 MiB（exit 0，触发 execFileAsync maxBuffer 拒绝）
CASE3_BIN="$TMP_DIR/case3-bin"
CASE3_MARKER="$TMP_DIR/case3.probe-done"
CASE3_OVERFLOW="$TMP_DIR/case3-overflow.txt"
python3 - "$CASE3_OVERFLOW" <<'PY'
import pathlib, sys
line = "  4242 /usr/bin/fake-agy --arg=" + ("x" * 900) + "\n"
target = 2 * 1024 * 1024 + 4096
repeats = (target // len(line)) + 1
pathlib.Path(sys.argv[1]).write_text(line * repeats, encoding="utf-8")
PY
make_fake_ps "$CASE3_BIN" "
if mkdir '$CASE3_MARKER' 2>/dev/null; then
  printf '  101 /usr/bin/init\\n'
else
  cat '$CASE3_OVERFLOW'
fi
exit 0
"
run_case "probe-ok-then-stdout-maxbuffer" "$CASE3_BIN"

# 用例 4：探测通过，但后续异步 stderr 超过 2 MiB（stdout 有效且 exit 0，仍触发 maxBuffer 拒绝）
CASE4_BIN="$TMP_DIR/case4-bin"
CASE4_MARKER="$TMP_DIR/case4.probe-done"
make_fake_ps "$CASE4_BIN" "
if mkdir '$CASE4_MARKER' 2>/dev/null; then
  printf '  101 /usr/bin/init\\n'
else
  printf '  101 /usr/bin/init\\n'
  cat '$CASE3_OVERFLOW' >&2
fi
exit 0
"
run_case "probe-ok-then-stderr-maxbuffer" "$CASE4_BIN"

# 用例 5：探测本身返回空快照（exit 0）
CASE5_BIN="$TMP_DIR/case5-bin"
make_fake_ps "$CASE5_BIN" "exit 0"
run_case "probe-empty" "$CASE5_BIN"

# 用例 6：探测本身 stdout 超 2 MiB（exit 0）
CASE6_BIN="$TMP_DIR/case6-bin"
make_fake_ps "$CASE6_BIN" "cat '$CASE3_OVERFLOW'; exit 0"
run_case "probe-maxbuffer" "$CASE6_BIN"

# 用例 7：正常有效 ps 快照（exit 0）
CASE7_BIN="$TMP_DIR/case7-bin"
make_fake_ps "$CASE7_BIN" "printf '  101 /usr/bin/init\\n  202 /usr/bin/shell\\n'; exit 0"
run_case "healthy-ps" "$CASE7_BIN"

python3 - "$TMP_DIR" <<'PY'
import json
import pathlib
import sys

tmp_dir = pathlib.Path(sys.argv[1])


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(f"断言失败：{msg}")


def load(name: str) -> dict:
    return json.loads((tmp_dir / f"{name}.json").read_text(encoding="utf-8"))


# 1) probe ok + empty snapshots
r1 = load("probe-ok-then-empty")
require(r1["processScan"]["selfTest"]["status"] == "ok", f"case1 selfTest 应为 ok：{r1['processScan']['selfTest']}")
require(r1["processScan"]["status"] == "degraded", f"case1 processScan 应为 degraded：{r1['processScan']}")
require(r1["processScan"]["totals"]["succeeded"] == 0, f"case1 空快照不得计入 succeeded：{r1['processScan']['totals']}")
require(r1["processScan"]["totals"]["failed"] > 0, f"case1 空快照应计入 failed：{r1['processScan']['totals']}")
require(r1["summary"]["phase1Comparison"]["status"] == "excluded_degraded", f"case1 phase1Comparison 不得为 valid：{r1['summary']['phase1Comparison']}")
require(r1["summary"]["phase1Comparison"]["eligible"] is False, "case1 eligible 必须为 False")
require(r1["summary"]["concurrentColdP95MsMean"] is None and r1["summary"]["sequentialWarmP95MsMean"] is None, "case1 延迟汇总必须为 null")
require("empty" in (r1["processScan"]["exclusionReason"] or ""), f"case1 exclusionReason 应标明 empty：{r1['processScan']['exclusionReason']}")

# 2) probe ok + unparseable snapshots
r2 = load("probe-ok-then-unparseable")
require(r2["processScan"]["selfTest"]["status"] == "ok", f"case2 selfTest 应为 ok：{r2['processScan']['selfTest']}")
require(r2["processScan"]["status"] == "degraded", f"case2 processScan 应为 degraded：{r2['processScan']}")
require(r2["processScan"]["totals"]["succeeded"] == 0, f"case2 无效行快照不得计入 succeeded：{r2['processScan']['totals']}")
require(r2["processScan"]["totals"]["failed"] > 0, f"case2 无效行快照应计入 failed：{r2['processScan']['totals']}")
require(r2["summary"]["phase1Comparison"]["status"] == "excluded_degraded", f"case2 phase1Comparison 不得为 valid：{r2['summary']['phase1Comparison']}")

# 3) probe ok + async stdout maxBuffer rejection
r3 = load("probe-ok-then-stdout-maxbuffer")
require(r3["processScan"]["selfTest"]["status"] == "ok", f"case3 selfTest 应为 ok：{r3['processScan']['selfTest']}")
require(r3["processScan"]["status"] == "degraded", f"case3 stdout maxBuffer 拒绝应为 degraded：{r3['processScan']}")
require(r3["processScan"]["totals"]["succeeded"] == 0, f"case3 stdout maxBuffer 拒绝不得计入 succeeded：{r3['processScan']['totals']}")
require(r3["processScan"]["totals"]["failed"] > 0, f"case3 stdout maxBuffer 拒绝应计入 failed：{r3['processScan']['totals']}")
require(r3["summary"]["phase1Comparison"]["status"] == "excluded_degraded", f"case3 phase1Comparison 应为 excluded_degraded：{r3['summary']['phase1Comparison']}")
require("maxbuffer" in (r3["processScan"]["exclusionReason"] or ""), f"case3 exclusionReason 应标明 maxbuffer：{r3['processScan']['exclusionReason']}")

# 4) probe ok + async stderr maxBuffer rejection
r4 = load("probe-ok-then-stderr-maxbuffer")
require(r4["processScan"]["selfTest"]["status"] == "ok", f"case4 selfTest 应为 ok：{r4['processScan']['selfTest']}")
require(r4["processScan"]["status"] == "degraded", f"case4 stderr maxBuffer 拒绝应为 degraded：{r4['processScan']}")
require(r4["processScan"]["totals"]["succeeded"] == 0, f"case4 stderr maxBuffer 拒绝不得计入 succeeded：{r4['processScan']['totals']}")
require(r4["processScan"]["totals"]["failed"] > 0, f"case4 stderr maxBuffer 拒绝应计入 failed：{r4['processScan']['totals']}")
require(r4["summary"]["phase1Comparison"]["status"] == "excluded_degraded", f"case4 phase1Comparison 应为 excluded_degraded：{r4['summary']['phase1Comparison']}")
require("maxbuffer" in (r4["processScan"]["exclusionReason"] or ""), f"case4 exclusionReason 应标明 maxbuffer：{r4['processScan']['exclusionReason']}")

# 5) probe empty
r5 = load("probe-empty")
require(r5["processScan"]["selfTest"]["status"] == "degraded", f"case5 selfTest 应为 degraded：{r5['processScan']['selfTest']}")
require(r5["processScan"]["selfTest"]["reason"] == "ps_empty_process_list", f"case5 reason 异常：{r5['processScan']['selfTest']}")
require(r5["processScan"]["totals"]["succeeded"] == 0, f"case5 succeeded 应为 0：{r5['processScan']['totals']}")
require(r5["summary"]["phase1Comparison"]["status"] == "excluded_degraded", f"case5 phase1Comparison 应为 excluded_degraded：{r5['summary']['phase1Comparison']}")

# 6) probe maxBuffer
r6 = load("probe-maxbuffer")
require(r6["processScan"]["selfTest"]["status"] == "degraded", f"case6 selfTest 应为 degraded：{r6['processScan']['selfTest']}")
require(r6["processScan"]["totals"]["succeeded"] == 0, f"case6 succeeded 应为 0：{r6['processScan']['totals']}")
require(r6["summary"]["phase1Comparison"]["status"] == "excluded_degraded", f"case6 phase1Comparison 应为 excluded_degraded：{r6['summary']['phase1Comparison']}")

# 7) healthy ps
r7 = load("healthy-ps")
require(r7["processScan"]["selfTest"]["status"] == "ok", f"case7 selfTest 应为 ok：{r7['processScan']['selfTest']}")
require(r7["processScan"]["status"] == "ok", f"case7 processScan 应为 ok：{r7['processScan']}")
require(r7["processScan"]["totals"]["succeeded"] > 0, f"case7 succeeded 应 > 0：{r7['processScan']['totals']}")
require(r7["processScan"]["totals"]["failed"] == 0 and r7["processScan"]["totals"]["incomplete"] == 0, f"case7 不应有失败：{r7['processScan']['totals']}")
require(r7["summary"]["phase1Comparison"]["status"] == "valid", f"case7 phase1Comparison 应为 valid：{r7['summary']['phase1Comparison']}")
require(r7["summary"]["phase1Comparison"]["eligible"] is True, "case7 eligible 应为 True")

print("Agy 基准 ps 包装器回归测试全部通过：7/7 用例")
PY
