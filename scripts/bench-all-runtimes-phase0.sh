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

verify_claude_sdk_version() {
  BENCH_ROOT_DIR="$ROOT_DIR" bun -e '
import fs from "node:fs";
import path from "node:path";

const PKG_NAME = "@anthropic-ai/claude-agent-sdk";

function stripJsonc(raw: string): string {
  let noComments = "";
  let inStr = false;
  let escaped = false;
  let inLineComment = false;
  let inBlockComment = false;
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i]!;
    const next = raw[i + 1];
    if (inLineComment) {
      if (ch === "\n") {
        inLineComment = false;
        noComments += ch;
      }
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inStr) {
      noComments += ch;
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === "\"") inStr = false;
      continue;
    }
    if (ch === "\"") {
      inStr = true;
      noComments += ch;
      continue;
    }
    if (ch === "/" && next === "/") {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      i += 1;
      continue;
    }
    noComments += ch;
  }

  let cleaned = "";
  inStr = false;
  escaped = false;
  for (let i = 0; i < noComments.length; i += 1) {
    const ch = noComments[i]!;
    if (inStr) {
      cleaned += ch;
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === "\"") inStr = false;
      continue;
    }
    if (ch === "\"") {
      inStr = true;
      cleaned += ch;
      continue;
    }
    if (ch === ",") {
      let j = i + 1;
      while (j < noComments.length && /\s/.test(noComments[j]!)) j += 1;
      if (noComments[j] === "}" || noComments[j] === "]") continue;
    }
    cleaned += ch;
  }
  return cleaned;
}

const rootDir = process.env.BENCH_ROOT_DIR;
if (!rootDir) {
  console.error("缺少 BENCH_ROOT_DIR");
  process.exit(1);
}
const bridgeDir = path.join(rootDir, "bridges", "claude-sdk");
const lockPath = path.join(bridgeDir, "bun.lock");
const lock = JSON.parse(stripJsonc(fs.readFileSync(lockPath, "utf8"))) as {
  packages?: Record<string, unknown[]>;
};
const lockEntry = lock.packages?.[PKG_NAME]?.[0];
const prefix = `${PKG_NAME}@`;
if (typeof lockEntry !== "string" || !lockEntry.startsWith(prefix) || lockEntry.length <= prefix.length) {
  console.error(`无法从 bridges/claude-sdk/bun.lock 解析 ${PKG_NAME} 锁定版本`);
  process.exit(1);
}
const lockVersion = lockEntry.slice(prefix.length);

const localNodeModules = path.join(bridgeDir, "node_modules");
if (!fs.existsSync(localNodeModules)) {
  console.error(`缺少 bridges/claude-sdk/node_modules（lockfile 期望 ${PKG_NAME}@${lockVersion}）`);
  process.exit(1);
}
const localNodeModulesReal = fs.realpathSync(localNodeModules);

let resolvedEntry: string;
try {
  resolvedEntry = Bun.resolveSync(PKG_NAME, path.join(bridgeDir, "src", "claude"));
} catch (error) {
  console.error(`无法解析 ${PKG_NAME}（lockfile 期望 ${lockVersion}）：${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}

let dir = path.dirname(resolvedEntry);
let pkgDir = "";
let resolvedVersion = "";
while (true) {
  const candidate = path.join(dir, "package.json");
  if (fs.existsSync(candidate)) {
    const pkg = JSON.parse(fs.readFileSync(candidate, "utf8")) as { name?: unknown; version?: unknown };
    if (pkg.name === PKG_NAME && typeof pkg.version === "string" && pkg.version.length > 0) {
      pkgDir = dir;
      resolvedVersion = pkg.version;
      break;
    }
  }
  const parent = path.dirname(dir);
  if (parent === dir) break;
  dir = parent;
}

if (!pkgDir || !resolvedVersion) {
  console.error(`无法定位解析出的 ${PKG_NAME} package.json（lockfile 期望 ${lockVersion}）`);
  process.exit(1);
}

const pkgDirReal = fs.realpathSync(pkgDir);
if (pkgDirReal !== localNodeModulesReal && !pkgDirReal.startsWith(`${localNodeModulesReal}${path.sep}`)) {
  console.error(`解析出的 ${PKG_NAME}@${resolvedVersion} 不位于 bridges/claude-sdk/node_modules 内`);
  process.exit(1);
}

if (resolvedVersion !== lockVersion) {
  console.error(`解析出的 ${PKG_NAME} 版本与 bun.lock 不一致：resolved=${resolvedVersion}, lockfile=${lockVersion}`);
  process.exit(1);
}

console.log(`${resolvedVersion} ${lockVersion}`);
'
}

# 仅在缺少依赖时按锁文件安装，不改动锁文件且不下载可选原生二进制。
if [[ ! -d "$ROOT_DIR/bridges/agy-acp/node_modules" ]]; then
  (cd "$ROOT_DIR/bridges/agy-acp" && bun install --frozen-lockfile --omit optional >/dev/null)
fi

CLAUDE_SDK_CHECK_OUT=""
if [[ ! -d "$ROOT_DIR/bridges/claude-sdk/node_modules" ]] || ! CLAUDE_SDK_CHECK_OUT="$(verify_claude_sdk_version 2>&1)"; then
  if [[ -d "$ROOT_DIR/bridges/claude-sdk/node_modules" && -n "$CLAUDE_SDK_CHECK_OUT" ]]; then
    echo "检测到 bridges/claude-sdk 依赖与 bun.lock 不一致，重新执行 frozen install：${CLAUDE_SDK_CHECK_OUT}" >&2
  fi
  (cd "$ROOT_DIR/bridges/claude-sdk" && bun install --frozen-lockfile --omit optional >/dev/null)
  CLAUDE_SDK_CHECK_OUT="$(verify_claude_sdk_version)"
fi
read -r CLAUDE_SDK_VERSION CLAUDE_SDK_LOCK_VERSION <<<"$CLAUDE_SDK_CHECK_OUT"
if [[ -z "$CLAUDE_SDK_VERSION" || "$CLAUDE_SDK_VERSION" != "$CLAUDE_SDK_LOCK_VERSION" ]]; then
  echo "Claude Agent SDK 版本校验失败：resolved=${CLAUDE_SDK_VERSION:-missing}, lockfile=${CLAUDE_SDK_LOCK_VERSION:-missing}" >&2
  exit 1
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

echo "==> [2/2] 运行 Claude SDK (bridges/claude-sdk) 基准（sdk=@anthropic-ai/claude-agent-sdk@${CLAUDE_SDK_VERSION}, seed=${SEED}, batches=${BATCHES}, cold=${COLD}, warm=${WARM}, target=${TARGET_SESSIONS}, other=${OTHER_SESSIONS}）"
bun "$ROOT_DIR/scripts/bench-claude-sdk-list.ts" \
  --seed "$SEED" \
  --batches "$BATCHES" \
  --cold "$COLD" \
  --warm "$WARM" \
  --target-sessions "$TARGET_SESSIONS" \
  --other-sessions "$OTHER_SESSIONS" \
  --json-out "$CLAUDE_JSON" >/dev/null

python3 - "$AGY_JSON" "$CLAUDE_JSON" "$CLAUDE_SDK_VERSION" "$CLAUDE_SDK_LOCK_VERSION" <<'PY'
import json
import pathlib
import sys

agy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
claude_path = pathlib.Path(sys.argv[2])
claude = json.loads(claude_path.read_text(encoding="utf-8"))
sdk_version = sys.argv[3]
sdk_lock_version = sys.argv[4]

claude["sdk"] = {
    "package": "@anthropic-ai/claude-agent-sdk",
    "version": sdk_version,
    "lockfileVersion": sdk_lock_version,
}
claude_path.write_text(json.dumps(claude, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

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
        f"acp_rpcs={cc['acpSessionListRpcsPerRun']}, p50={cc['latencyMs']['p50']}ms, p95={cc['latencyMs']['p95']}ms | "
        f"顺序热态 git_spawns={sw['gitSpawnsAbsoluteTotal']}, acp_rpc_delta={sw['acpSessionListRpcsDelta']}, "
        f"p50={sw['latencyMs']['p50']}ms, p95={sw['latencyMs']['p95']}ms"
    )
print(
    f"- 汇总：并发冷查单轮平均 git spawn={agy['summary']['concurrentColdGitSpawnsMeanPerRun']}，"
    f"顺序热态总 git spawn={agy['summary']['sequentialWarmGitSpawnsAbsoluteAcrossAllBatches']}，"
    f"顺序热态总 ACP RPC 增量={agy['summary']['sequentialWarmAcpRpcsDeltaAcrossAllBatches']}，"
    f"热态 p95 均值={agy['summary']['sequentialWarmP95MsMean']}ms（批间极差波动 {agy['summary']['sequentialWarmP95SpreadPct']}%）"
)

print("\n[Claude SDK bridges/claude-sdk]")
print(
    f"- SDK：@anthropic-ai/claude-agent-sdk@{claude['sdk']['version']} (lockfile={claude['sdk']['lockfileVersion']})"
)
print(
    f"- 数据集：{claude['dataset']['verifiedTargetRepoSessions']}/{claude['dataset']['targetRepoSessions']} 目标仓（含 worktree） / "
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
    f"- 阈值评估（合并热态次页 p95 > 30ms 且目录处理占比 > 50%，n={te['warmPage2RunsPooled']}）："
    f"合并 p95={te['warmPage2P95MsPooled']}ms（批均值 {te['warmPage2P95MsBatchMean']}ms，批间极差波动 {te['warmPage2P95SpreadPct']}%），"
    f"合并目录处理占比={te['catalogProcessingSharePctPooled']}% → triggered={te['triggered']}"
)
PY
