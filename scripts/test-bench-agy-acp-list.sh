#!/usr/bin/env bash
# 定向回归测试：校验 scripts/bench-agy-acp-list.ts 的保留行为与 Phase 0 范围收窄：
# 1) 正常运行时精确统计 git spawn 与 ACP RPC，标注 processScan 为“Phase 0 未计量，留待后续 issue”，
#    延迟结果一律标为 informational 且不作为 Phase 1 门槛判定依据；
# 2) 计时路径不注入 ps 包装器、临时文件或 MIMI_BENCH_PS_* 环境变量（启动基准前清掉探测输入环境里的 MIMI_BENCH_PS_* 前缀）；
# 3) 外部 ps 异常退出时基准仍可完成，且延迟结果保持 informational（不标为 valid）；
# 4) 调用方传入脏 GIT_* 环境变量时仍可隔离运行；
# 5) 基准用例提前非零退出时，在清理临时目录前打印用例名与捕获的 stderr。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for cmd in bun git python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令：${cmd}" >&2; exit 127; }
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-test-bench-agy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

make_fake_cmd() {
  local dir="$1"
  local cmd_name="$2"
  local body="$3"
  mkdir -p "$dir"
  cat > "$dir/$cmd_name" <<EOF
#!/bin/sh
set -u
$body
EOF
  chmod +x "$dir/$cmd_name"
}

run_case() {
  local name="$1"
  local extra_path="$2"
  shift 2
  local out_json="$TMP_DIR/${name}.json"
  local err_log="$TMP_DIR/${name}.stderr"
  local run_path="$PATH"
  if [[ -n "$extra_path" ]]; then
    run_path="${extra_path}:${PATH}"
  fi
  local -a unset_ps_args=()
  local ps_var
  while IFS= read -r ps_var; do
    [[ -n "$ps_var" ]] && unset_ps_args+=(-u "$ps_var")
  done < <(python3 -c 'import os; [print(k) for k in os.environ if k.startswith("MIMI_BENCH_PS_")]')
  local rc=0
  PATH="$run_path" env ${unset_ps_args[@]+"${unset_ps_args[@]}"} "$@" bun "$ROOT_DIR/scripts/bench-agy-acp-list.ts" \
    --batches 1 --cold 1 --warm 2 --concurrency 1 \
    --json-out "$out_json" >/dev/null 2>"$err_log" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "[FAIL] 基准用例提前退出：case=${name}, exit=${rc}" >&2
    if [[ -s "$err_log" ]]; then
      echo "--- ${name} stderr ---" >&2
      cat "$err_log" >&2
      echo "--- end ${name} stderr ---" >&2
    else
      echo "（${name} 未输出 stderr）" >&2
    fi
    return "$rc"
  fi
}

# 用例 1：默认运行（验证 git 计数、ACP RPC、processScan 未计量标注与延迟 informational 标注）
run_case "default-unmeasured-ps" ""

# 用例 2：验证计时路径不再注入 ps 包装器或 MIMI_BENCH_PS_* 环境变量（仅保留 git 包装器），
# 并主动携带继承的 MIMI_BENCH_PS_* 前缀以验证启动基准前已从探测输入环境清除。
CASE2_BIN="$TMP_DIR/case2-bin"
CASE2_PROBE_LOG="$TMP_DIR/case2-ps-probe.log"
make_fake_cmd "$CASE2_BIN" "ps" "
first_path=\"\${PATH%%:*}\"
has_ps_wrapper=0
if [ -e \"\$first_path/ps\" ]; then
  has_ps_wrapper=1
fi
has_git_wrapper=0
if [ -e \"\$first_path/git\" ]; then
  has_git_wrapper=1
fi
has_ps_env=0
if env | grep -q '^MIMI_BENCH_PS_'; then
  has_ps_env=1
fi
printf 'ps_wrapper=%s git_wrapper=%s ps_env=%s\\n' \"\$has_ps_wrapper\" \"\$has_git_wrapper\" \"\$has_ps_env\" >> '$CASE2_PROBE_LOG'
printf '  101 /usr/bin/init\\n'
exit 0
"
(
  export MIMI_BENCH_PS_LOG_FILE="review-inherited-sentinel"
  export MIMI_BENCH_PS_EXTRA="inherited-check"
  run_case "no-ps-wrapper-in-timed-path" "$CASE2_BIN"
)

# 用例 3：外部 ps 失败（exit 1）时，基准仍成功且延迟结果保持 informational（不标为 valid）
CASE3_BIN="$TMP_DIR/case3-bin"
make_fake_cmd "$CASE3_BIN" "ps" "exit 1"
run_case "ps-failing-stays-informational" "$CASE3_BIN"

# 用例 4：调用方携带脏 GIT_* 变量时，仍正确隔离并完成 git 计数
run_case "dirty-git-env-isolated" "" \
  "GIT_DIR=$TMP_DIR/nonexistent-git-dir" \
  "GIT_WORK_TREE=$TMP_DIR/nonexistent-work-tree"

# 用例 5：验证 run_case 在基准提前非零退出（exit 7）时会打印用例名与捕获的 stderr
CASE5_BIN="$TMP_DIR/case5-bin"
make_fake_cmd "$CASE5_BIN" "bun" "
echo 'simulated-early-exit-stderr-line' >&2
exit 7
"
CASE5_CAPTURED="$TMP_DIR/case5-captured.stderr"
CASE5_RC=0
(run_case "early-exit-reports-stderr" "$CASE5_BIN") 2>"$CASE5_CAPTURED" || CASE5_RC=$?
if [[ "$CASE5_RC" -ne 7 ]]; then
  echo "断言失败：case5 期望退出码 7，实际 ${CASE5_RC}" >&2
  exit 1
fi

python3 - "$TMP_DIR" "$CASE2_PROBE_LOG" "$CASE5_CAPTURED" <<'PY'
import json
import pathlib
import sys

tmp_dir = pathlib.Path(sys.argv[1])
probe_log_path = pathlib.Path(sys.argv[2])
case5_stderr = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")

EXPECTED_PROCESS_SCAN_NOTE = "Phase 0 未计量，留待后续 issue"
EXPECTED_LATENCY_NOTE = "基线与对比运行的扫描条件对齐前，延迟仅供参考"


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(f"断言失败：{msg}")


def load(name: str) -> dict:
    return json.loads((tmp_dir / f"{name}.json").read_text(encoding="utf-8"))


def assert_common_informational_report(name: str, report: dict) -> None:
    ps = report["processScan"]
    require(ps["status"] == "unmeasured", f"{name} processScan.status 应为 unmeasured：{ps}")
    require(ps["note"] == EXPECTED_PROCESS_SCAN_NOTE, f"{name} processScan.note 不符：{ps}")
    require("affectsPhase1Comparison" not in ps, f"{name} processScan 不应包含 affectsPhase1Comparison：{ps}")

    summary = report["summary"]
    require(summary["processScanStatus"] == "unmeasured", f"{name} summary.processScanStatus 不符：{summary}")
    require(summary["latencyStatus"] == "informational", f"{name} summary.latencyStatus 应为 informational：{summary}")
    require(summary["latencyNote"] == EXPECTED_LATENCY_NOTE, f"{name} summary.latencyNote 不符：{summary}")
    require("phase1Comparison" not in summary, f"{name} summary 不应再输出 phase1Comparison valid 门槛判定：{summary}")
    require(summary["concurrentColdGitSpawnsMeanPerRun"] > 0, f"{name} 冷查 git spawn 应 > 0：{summary}")
    require(summary["sequentialWarmGitSpawnsAbsoluteAcrossAllBatches"] == 0, f"{name} 热态 git spawn 应为 0：{summary}")
    require(summary["concurrentColdAcpRpcsMeanPerRun"] > 0, f"{name} 冷查 ACP RPC 应 > 0：{summary}")
    require(isinstance(summary["concurrentColdP95MsMean"], (int, float)) and summary["concurrentColdP95MsMean"] > 0, f"{name} 冷查 p95 应为正数：{summary}")
    require(isinstance(summary["sequentialWarmP95MsMean"], (int, float)) and summary["sequentialWarmP95MsMean"] > 0, f"{name} 热态 p95 应为正数：{summary}")

    lat = summary["latency"]
    require(lat["status"] == "informational", f"{name} summary.latency.status 应为 informational：{lat}")
    require(lat["usedForPhase1Gate"] is False, f"{name} summary.latency.usedForPhase1Gate 应为 False：{lat}")
    require(lat["note"] == EXPECTED_LATENCY_NOTE, f"{name} summary.latency.note 不符：{lat}")
    require(lat["processScanStatus"] == "unmeasured", f"{name} summary.latency.processScanStatus 应为 unmeasured：{lat}")
    require(lat["processScanNote"] == EXPECTED_PROCESS_SCAN_NOTE, f"{name} summary.latency.processScanNote 不符：{lat}")
    require(lat["concurrentColdP95MsMean"] == summary["concurrentColdP95MsMean"], f"{name} latency 冷查 p95 应与 summary 一致：{lat}")
    require(lat["sequentialWarmP95MsMean"] == summary["sequentialWarmP95MsMean"], f"{name} latency 热态 p95 应与 summary 一致：{lat}")

    require(len(report["batches"]) == 1, f"{name} 批次数应为 1")
    batch = report["batches"][0]
    require("processScanStatus" not in batch, f"{name} batch 不应包含 processScanStatus：{batch}")
    require("processScan" not in batch["concurrentCold"], f"{name} concurrentCold 不应包含 processScan")
    require("processScan" not in batch["sequentialWarm"], f"{name} sequentialWarm 不应包含 processScan")


# 1) default run
assert_common_informational_report("default-unmeasured-ps", load("default-unmeasured-ps"))

# 2) no ps wrapper in timed path (and inherited MIMI_BENCH_PS_* stripped before launch)
assert_common_informational_report("no-ps-wrapper-in-timed-path", load("no-ps-wrapper-in-timed-path"))
probe_lines = [line.strip() for line in probe_log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
require(len(probe_lines) > 0, "case2 未观测到生产链路调用 ps，无法验证未插入 ps 包装器")
for idx, line in enumerate(probe_lines, start=1):
    require(
        line == "ps_wrapper=0 git_wrapper=1 ps_env=0",
        f"case2 第 {idx} 次 ps 调用检测到残留包装器或环境变量：{line}",
    )

# 3) failing ps still completes cleanly and latency stays informational
assert_common_informational_report("ps-failing-stays-informational", load("ps-failing-stays-informational"))

# 4) dirty GIT_* env isolated
assert_common_informational_report("dirty-git-env-isolated", load("dirty-git-env-isolated"))

# 5) early exit prints case name and captured stderr before cleanup
require("case=early-exit-reports-stderr" in case5_stderr, f"case5 未输出用例名：{case5_stderr!r}")
require("exit=7" in case5_stderr, f"case5 未输出退出码：{case5_stderr!r}")
require("simulated-early-exit-stderr-line" in case5_stderr, f"case5 未输出捕获的 stderr：{case5_stderr!r}")

print("Agy 基准回归测试全部通过：5/5 用例")
PY
