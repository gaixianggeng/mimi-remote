#!/usr/bin/env bash
# 从本机 Codex CLI 生成 app-server 协议的 TypeScript 类型，只保留适配器用到的类型闭包。
# Codex 版本必须与仓库协议快照一致，避免适配器和 agentd/iOS 依据的协议版本漂移。
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$PACKAGE_DIR/../.." && pwd)"
SNAPSHOT_VERSION="$(tr -d '[:space:]' < "$REPO_DIR/internal/httpapi/testdata/codex-protocol/codex-version.txt")"
CODEX_BIN="${CODEX_BIN:-codex}"
OUT_DIR="$PACKAGE_DIR/src/protocol/codex"

# 适配器直接引用的协议类型；依赖由下面的脚本按 import 自动补齐。
ROOT_TYPES=(
  InitializeParams
  InitializeResponse
  v2/Thread
  v2/Turn
  v2/ThreadItem
  v2/ThreadItemEntry
  v2/ThreadListParams
  v2/ThreadListResponse
  v2/ThreadReadParams
  v2/ThreadReadResponse
  v2/ThreadTurnsListParams
  v2/ThreadTurnsListResponse
  v2/ThreadItemsListParams
  v2/ThreadItemsListResponse
  v2/ThreadLoadedListParams
  v2/ThreadLoadedListResponse
  v2/ThreadStartParams
  v2/ThreadStartResponse
  v2/ThreadResumeParams
  v2/ThreadResumeResponse
  v2/TurnStartParams
  v2/TurnStartResponse
  v2/TurnSteerParams
  v2/TurnSteerResponse
  v2/TurnInterruptParams
  v2/TurnInterruptResponse
  v2/TurnStartedNotification
  v2/TurnCompletedNotification
  v2/ItemStartedNotification
  v2/ItemCompletedNotification
  v2/AgentMessageDeltaNotification
  v2/ReasoningTextDeltaNotification
  v2/ThreadTokenUsageUpdatedNotification
  v2/AccountRateLimitsUpdatedNotification
  v2/ServerRequestResolvedNotification
  v2/CommandExecutionRequestApprovalParams
  v2/CommandExecutionRequestApprovalResponse
  v2/FileChangeRequestApprovalParams
  v2/FileChangeRequestApprovalResponse
  v2/ToolRequestUserInputParams
  v2/ToolRequestUserInputResponse
  v2/ThreadStatusChangedNotification
)

actual_version="$("$CODEX_BIN" --version | awk '{print $NF}')"
if [[ "$actual_version" != "$SNAPSHOT_VERSION" ]]; then
  echo "Codex CLI 版本 $actual_version 与仓库协议快照 $SNAPSHOT_VERSION 不一致；用 CODEX_BIN 指向对应版本。" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
"$CODEX_BIN" app-server generate-ts --out "$work_dir/generated" >/dev/null

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
python3 - "$work_dir/generated" "$OUT_DIR" "${ROOT_TYPES[@]}" <<'PY'
import os
import re
import shutil
import sys

source, target, *roots = sys.argv[1:]
pending = [os.path.join(source, name + ".ts") for name in roots]
seen = set()
while pending:
    path = os.path.normpath(pending.pop())
    if path in seen:
        continue
    if not os.path.exists(path):
        sys.exit(f"缺少协议类型：{os.path.relpath(path, source)}")
    seen.add(path)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    for match in re.finditer(r'from "(\.[^"]+)"', text):
        pending.append(os.path.join(os.path.dirname(path), match.group(1) + ".ts"))
for path in sorted(seen):
    relative = os.path.relpath(path, source)
    destination = os.path.join(target, relative)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.copyfile(path, destination)
print(f"已同步 {len(seen)} 个协议类型文件")
PY
printf '%s\n' "$SNAPSHOT_VERSION" > "$OUT_DIR/codex-version.txt"
