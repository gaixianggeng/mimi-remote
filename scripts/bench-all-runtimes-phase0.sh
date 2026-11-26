#!/usr/bin/env bash
# 全部运行时 Phase 0 可复跑性能基准入口：
# 默认使用固定种子 20260410，连续执行 3 批，每批冷 5 次、热 20 次，
# 分别采集 Agy 并发冷查 / 顺序热态 Git spawn 与耗时，以及 Claude SDK 200+ 会话热态次页 p95 与目录处理耗时占比。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SEED=20260410
BATCHES=3
COLD=5
WARM=20
CONCURRENCY=4
TARGET_SESSIONS=240
OTHER_SESSIONS=40
JSON_DIR=""

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/bench-all-runtimes-phase0.sh [选项]

选项：
  --seed <int>             固定随机种子（默认 20260410）
  --batches <int>          批次数（默认 3）
  --cold <int>             每批冷态次数（默认 5）
  --warm <int>             每批热态次数（默认 20）
  --concurrency <int>      Agy 冷查并发度（默认 4）
  --target-sessions <int>  Claude SDK 目标仓会话数（默认 240，>= 200）
  --other-sessions <int>   Claude SDK 其他仓会话数（默认 40）
  --json-dir <dir>         可选：输出 agy-acp.json 与 claude-sdk.json 的目录
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --seed) SEED="$2"; shift 2 ;;
    --batches) BATCHES="$2"; shift 2 ;;
    --cold) COLD="$2"; shift 2 ;;
    --warm) WARM="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --target-sessions) TARGET_SESSIONS="$2"; shift 2 ;;
    --other-sessions) OTHER_SESSIONS="$2"; shift 2 ;;
    --json-dir) JSON_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 1 ;;
  esac
done

for cmd in bun git python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令：${cmd}" >&2; exit 127; }
done

# 仅在缺少依赖时按锁文件安装，不改动锁文件且不下载可选原生二进制。
if [[ ! -d "$ROOT_DIR/bridges/agy-acp/node_modules" ]]; then
  (cd "$ROOT_DIR/bridges/agy-acp" && bun install --frozen-lockfile --omit optional >/dev/null)
fi
if [[ ! -d "$ROOT_DIR/bridges/claude-sdk/node_modules" ]]; then
  (cd "$ROOT_DIR/bridges/claude-sdk" && bun install --frozen-lockfile --omit optional >/dev/null)
fi

TMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/mimi-phase0-bench-out.XXXXXX")"
trap 'rm -rf "$TMP_OUT"' EXIT

AGY_JSON="$TMP_OUT/agy-acp.json"
CLAUDE_JSON="$TMP_OUT/claude-sdk.json"
if [[ -n "$JSON_DIR" ]]; then
  mkdir -p "$JSON_DIR"
  AGY_JSON="$JSON_DIR/agy-acp.json"
  CLAUDE_JSON="$JSON_DIR/claude-sdk.json"
fi

echo "==> [1/2] 运行 Antigravity (bridges/agy-acp) 基准（seed=${SEED}, batches=${BATCHES}, cold=${COLD}, warm=${WARM}, concurrency=${CONCURRENCY}）"
bun "$ROOT_DIR/scripts/bench-agy-acp-list.ts" \
  --seed "$SEED" \
  --batches "$BATCHES" \
  --cold "$COLD" \
  --warm "$WARM" \
  --concurrency "$CONCURRENCY" \
  --json-out "$AGY_JSON" >/dev/null

echo "==> [2/2] 运行 Claude SDK (bridges/claude-sdk) 基准（seed=${SEED}, batches=${BATCHES}, cold=${COLD}, warm=${WARM}, target=${TARGET_SESSIONS}, other=${OTHER_SESSIONS}）"
bun "$ROOT_DIR/scripts/bench-claude-sdk-list.ts" \
  --seed "$SEED" \
  --batches "$BATCHES" \
  --cold "$COLD" \
  --warm "$WARM" \
  --target-sessions "$TARGET_SESSIONS" \
  --other-sessions "$OTHER_SESSIONS" \
  --json-out "$CLAUDE_JSON" >/dev/null

python3 - "$AGY_JSON" "$CLAUDE_JSON" <<'PY'
import json
import pathlib
import sys

agy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
claude = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))

print("\n=== Phase 0 性能基线摘要 ===")
print(f"固定种子：{agy['seed']} | 批次：{agy['config']['batches']} × (冷 {agy['config']['cold']} / 热 {agy['config']['warm']})")
print("\n[Antigravity bridges/agy-acp]")
print(
    f"- 数据集：{agy['dataset']['totalSummaries']} 全局 / {agy['dataset']['targetRepoSessions']} 目标仓 "
    f"(非孤儿唯一 raw cwd={agy['dataset']['uniqueNonOrphanRawCwds']}, 可查 Git 目录={agy['dataset']['existingUniqueCwdsEligibleForGitInspect']})"
)
for b in agy["batches"]:
    cc = b["concurrentCold"]
    sw = b["sequentialWarm"]
    print(
        f"  Batch {b['batch']}: 并发冷查(x{cc['concurrency']}) git_spawns={cc['gitSpawnsPerRun']} (mean={cc['gitSpawnsMean']}), "
        f"p50={cc['latencyMs']['p50']}ms, p95={cc['latencyMs']['p95']}ms | "
        f"顺序热态 git_spawns={sw['gitSpawnsAbsoluteTotal']}, acp_delta={sw['acpListCallsDelta']}, "
        f"p50={sw['latencyMs']['p50']}ms, p95={sw['latencyMs']['p95']}ms"
    )
print(
    f"- 汇总：并发冷查单轮平均 git spawn={agy['summary']['concurrentColdGitSpawnsMeanPerRun']}，"
    f"顺序热态总 git spawn={agy['summary']['sequentialWarmGitSpawnsAbsoluteAcrossAllBatches']}，"
    f"热态 p95 均值={agy['summary']['sequentialWarmP95MsMean']}ms（批间极差波动 {agy['summary']['sequentialWarmP95SpreadPct']}%）"
)

print("\n[Claude SDK bridges/claude-sdk]")
print(
    f"- 数据集：{claude['dataset']['targetRepoSessions']} 目标仓 / "
    f"{claude['dataset']['totalTranscriptFiles']} 总 transcript，页长 {claude['dataset']['pageSize']}"
)
for b in claude["batches"]:
    cp1 = b["coldPage1"]
    wp2 = b["warmPage2"]
    bm = wp2["breakdownMeanMs"]
    print(
        f"  Batch {b['batch']}: 冷首屏 p95={cp1['totalMs']['p95']}ms | "
        f"热态次页 p50={wp2['totalMs']['p50']}ms, p95={wp2['totalMs']['p95']}ms, "
        f"目录处理(sessions.list+toRecord+sort)={bm['catalogProcessing']}ms ({wp2['catalogProcessingSharePct']}%), "
        f"细项(prepare={bm['prepare']}ms, sessions.list={bm['sessionsList']}ms, toRecord={bm['toRecord']}ms, sort={bm['filterSortCursor']}ms, live={bm['liveAndToThread']}ms)"
    )
te = claude["thresholdEvaluation"]
print(
    f"- 阈值评估（热态次页 p95 > 30ms 且目录处理占比 > 50%）："
    f"p95 均值={te['warmPage2P95MsMean']}ms（批间极差波动 {te['warmPage2P95SpreadPct']}%），"
    f"目录处理占比均值={te['catalogProcessingSharePctMean']}% → triggered={te['triggered']}"
)
PY
