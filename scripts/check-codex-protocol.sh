#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_DIR="$ROOT_DIR/internal/httpapi/testdata/codex-protocol"
VERSION_FILE="$SNAPSHOT_DIR/codex-version.txt"
CODEX_BIN="${CODEX_BIN:-codex}"
MODE="check"

usage() {
  cat <<'USAGE'
用法：
  bash ./scripts/check-codex-protocol.sh
  bash ./scripts/check-codex-protocol.sh --update

默认检查本机 Codex CLI 版本，并将实时生成的 app-server 方法列表与仓库快照对比。
--update 使用本机 Codex CLI 重写版本和方法快照，仅应在明确升级 Codex 后执行。

环境变量：
  CODEX_BIN  Codex CLI 路径，默认 codex
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)
      MODE="update"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少依赖：$1" >&2
    exit 127
  fi
}

require_command "$CODEX_BIN"
require_command jq
require_command diff

version_output="$("$CODEX_BIN" --version 2>&1)"
if [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?) ]]; then
  actual_version="${BASH_REMATCH[1]}"
else
  echo "无法从 Codex CLI 输出中解析版本：$version_output" >&2
  exit 2
fi

if [[ "$MODE" == "check" ]]; then
  if [[ ! -f "$VERSION_FILE" ]]; then
    echo "缺少 Codex 版本快照：$VERSION_FILE" >&2
    exit 2
  fi

  IFS= read -r expected_version <"$VERSION_FILE"
  if [[ "$actual_version" != "$expected_version" ]]; then
    cat >&2 <<EOF
Codex CLI 版本不匹配：
  快照版本：$expected_version
  本机版本：$actual_version

请安装快照版本后重试：
  npm install --global @openai/codex@$expected_version

如果这是有意升级，请先安装目标版本，再更新快照（CI 会自动读取新的版本文件）：
  bash ./scripts/check-codex-protocol.sh --update
EOF
    exit 1
  fi
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-protocol.XXXXXX")"
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

SCHEMA_DIR="$TMP_DIR/schema"
METHOD_DIR="$TMP_DIR/methods"
mkdir -p "$SCHEMA_DIR" "$METHOD_DIR"

echo "==> 使用 Codex CLI $actual_version 生成 app-server schema"
if ! "$CODEX_BIN" app-server generate-json-schema --experimental --out "$SCHEMA_DIR"; then
  echo "生成 Codex app-server schema 失败" >&2
  exit 1
fi

schema_names=("ClientRequest" "ServerRequest" "ServerNotification")
snapshot_names=(
  "client-request-methods.txt"
  "server-request-methods.txt"
  "server-notification-methods.txt"
)

for index in "${!schema_names[@]}"; do
  schema_name="${schema_names[$index]}"
  snapshot_name="${snapshot_names[$index]}"
  schema_file="$SCHEMA_DIR/$schema_name.json"
  generated_file="$METHOD_DIR/$snapshot_name"

  if [[ ! -f "$schema_file" ]]; then
    echo "生成结果缺少 $schema_name.json，Codex schema 输出结构可能已经变化" >&2
    exit 1
  fi

  # 每个 oneOf 分支都必须对应一个且仅一个 JSON-RPC method，避免结构变化时静默漏报。
  if ! jq -e '
    (.oneOf | type == "array")
    and (.oneOf | length > 0)
    and all(
      .oneOf[];
      (.properties.method.enum | type == "array")
      and (.properties.method.enum | length == 1)
      and (.properties.method.enum[0] | type == "string")
    )
  ' "$schema_file" >/dev/null; then
    echo "$schema_name.json 的 method 结构不符合预期，请人工检查 Codex 协议变更" >&2
    exit 1
  fi

  # jq 的 sort 不受系统 locale 影响，确保 macOS 和 Linux 生成相同快照。
  jq -r '[.oneOf[].properties.method.enum[0]] | sort | .[]' \
    "$schema_file" >"$generated_file"
done

if [[ "$MODE" == "update" ]]; then
  mkdir -p "$SNAPSHOT_DIR"
  printf '%s\n' "$actual_version" >"$VERSION_FILE"
  for snapshot_name in "${snapshot_names[@]}"; do
    cp "$METHOD_DIR/$snapshot_name" "$SNAPSHOT_DIR/$snapshot_name"
  done
  echo "已更新 Codex $actual_version 协议方法快照：$SNAPSHOT_DIR"
  exit 0
fi

status=0
for index in "${!schema_names[@]}"; do
  schema_name="${schema_names[$index]}"
  snapshot_name="${snapshot_names[$index]}"
  snapshot_file="$SNAPSHOT_DIR/$snapshot_name"
  generated_file="$METHOD_DIR/$snapshot_name"

  if [[ ! -f "$snapshot_file" ]]; then
    echo "缺少协议快照：$snapshot_file" >&2
    status=1
    continue
  fi

  method_count="$(jq -R -s 'split("\n") | map(select(length > 0)) | length' "$generated_file")"
  echo "==> 检查 ${schema_name}：$method_count 个方法"
  if ! diff -u "$snapshot_file" "$generated_file"; then
    echo "$schema_name 方法列表与 Codex $actual_version 不一致" >&2
    status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  cat >&2 <<'EOF'

检测到 Codex app-server 协议漂移。
请先评估新增、删除或重命名的方法是否影响 Go Gateway 和移动端，再决定是否更新快照。
EOF
  exit "$status"
fi

echo "Codex $actual_version app-server 协议方法快照检查通过"
