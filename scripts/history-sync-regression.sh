#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${AGENTD_CONFIG:-}"
ROUNDS=10
LIST_LIMIT=20
TIMEOUT="15s"
ENDPOINTS=()

usage() {
  cat <<'USAGE'
用法：
  bash ./scripts/history-sync-regression.sh [options]

只读执行 initialize + thread/list，并输出 Endpoint 的成功率、P50、P95 和最大耗时。
未传 --endpoint 时，默认使用当前 Mac 的 Tailscale IPv4 地址和 8787 端口。

Options:
  --endpoint NAME=URL   增加验收入口；第一次传入时替换默认入口，可重复
  --rounds N            每条链路请求次数，默认 10
  --limit N             thread/list 页大小，默认 20
  --timeout DURATION    单次 RPC 超时，默认 15s
  --config PATH         agentd config.json 路径
  -h, --help            显示帮助

示例：
  # 默认验证当前 Mac 的 Tailscale Endpoint
  bash ./scripts/history-sync-regression.sh --rounds 10

  # 显式指定其他 Tailscale/MagicDNS Endpoint
  bash ./scripts/history-sync-regression.sh \
    --endpoint tailscale=http://<Mac-Tailscale-IP>:8787

Token 优先读取 AGENTD_TOKEN；为空时读取 --config 的 .auth.token。脚本不会打印 Token。
USAGE
}

custom_endpoints=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)
      if [[ "$custom_endpoints" == "0" ]]; then
        ENDPOINTS=()
        custom_endpoints=1
      fi
      ENDPOINTS+=("${2:?--endpoint 需要 NAME=URL}")
      shift 2
      ;;
    --rounds)
      ROUNDS="${2:?--rounds 需要正整数}"
      shift 2
      ;;
    --limit)
      LIST_LIMIT="${2:?--limit 需要正整数}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:?--timeout 需要 Go duration，例如 15s}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:?--config 需要路径}"
      shift 2
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

default_config_path() {
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Application Support/mimi-remote/config.json"
      ;;
    *)
      printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/mimi-remote/config.json"
      ;;
  esac
}

legacy_config_path() {
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Application Support/codex-ipad-agent/config.json"
      ;;
    *)
      printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/codex-ipad-agent/config.json"
      ;;
  esac
}

if [[ -z "$CONFIG_PATH" ]]; then
  CONFIG_PATH="$(default_config_path)"
  legacy_path="$(legacy_config_path)"
  # 只为尚未迁移的本机保留读取兼容；新安装始终使用 mimi-remote 目录。
  if [[ ! -f "$CONFIG_PATH" && -f "$legacy_path" ]]; then
    CONFIG_PATH="$legacy_path"
    echo "提示：未找到 mimi-remote 新目录配置，正在兼容读取旧配置：$legacy_path" >&2
  fi
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少依赖：$1" >&2
    exit 127
  fi
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == *[!0-9]* || "$value" == "0" ]]; then
    echo "$name 必须是正整数：$value" >&2
    exit 2
  fi
}

require_command go
require_command jq
require_command perl
require_positive_integer "--rounds" "$ROUNDS"
require_positive_integer "--limit" "$LIST_LIMIT"

if [[ "$custom_endpoints" == "0" ]]; then
  require_command tailscale
  tailscale_ip="$(tailscale ip -4 2>/dev/null || true)"
  if [[ -z "${tailscale_ip//[[:space:]]/}" || "$tailscale_ip" == *$'\n'* ]]; then
    echo "无法确定唯一的 Mac Tailscale IPv4 地址；请确认 Tailscale 已连接，或用 --endpoint 显式指定" >&2
    exit 2
  fi
  ENDPOINTS=("tailscale=http://${tailscale_ip}:8787")
fi

TOKEN="${AGENTD_TOKEN:-}"
if [[ -z "${TOKEN//[[:space:]]/}" && -f "$CONFIG_PATH" ]]; then
  TOKEN="$(jq -er '.auth.token // empty' "$CONFIG_PATH" 2>/dev/null || true)"
fi
if [[ -z "${TOKEN//[[:space:]]/}" ]]; then
  echo "缺少 Token：请设置 AGENTD_TOKEN，或用 --config 指向 agentd config.json" >&2
  exit 2
fi

probe_bin="$(mktemp -t mimi-history-probe.XXXXXX)"
timings_file="$(mktemp -t mimi-history-timings.XXXXXX)"
trap 'rm -f "$probe_bin" "$timings_file"' EXIT

go build -tags ipadwsprobe -o "$probe_bin" "$ROOT_DIR/scripts/ipad-ws-probe.go"

printf '%-12s %8s %8s %8s %8s %8s\n' "链路" "成功" "失败" "P50(ms)" "P95(ms)" "最大(ms)"
for entry in "${ENDPOINTS[@]}"; do
  if [[ "$entry" != *=* ]]; then
    echo "--endpoint 格式必须是 NAME=URL：$entry" >&2
    exit 2
  fi
  name="${entry%%=*}"
  endpoint="${entry#*=}"
  : >"$timings_file"
  successes=0
  failures=0

  for _ in $(seq 1 "$ROUNDS"); do
    started="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    if AGENTD_TOKEN="$TOKEN" "$probe_bin" \
      -endpoint "$endpoint" \
      -list-only \
      -list-limit "$LIST_LIMIT" \
      -timeout "$TIMEOUT" >/dev/null 2>&1; then
      finished="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
      awk -v start="$started" -v finish="$finished" 'BEGIN { printf "%.0f\n", (finish - start) * 1000 }' >>"$timings_file"
      successes=$((successes + 1))
    else
      failures=$((failures + 1))
    fi
  done

  if [[ "$successes" == "0" ]]; then
    printf '%-12s %8d %8d %8s %8s %8s\n' "$name" "$successes" "$failures" "-" "-" "-"
    continue
  fi

  read -r p50 p95 maximum < <(
    sort -n "$timings_file" | awk '
      { values[NR] = $1 }
      END {
        p50 = int((NR * 50 + 99) / 100)
        p95 = int((NR * 95 + 99) / 100)
        printf "%d %d %d\n", values[p50], values[p95], values[NR]
      }
    '
  )
  printf '%-12s %8d %8d %8d %8d %8d\n' "$name" "$successes" "$failures" "$p50" "$p95" "$maximum"
done
