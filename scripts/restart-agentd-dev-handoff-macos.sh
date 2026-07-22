#!/usr/bin/env bash
set -euo pipefail
umask 077

# 该脚本由 launchd 独立的一次性 job 执行，不能依赖发起更新的 Codex/agentd 进程继续存活。
if [[ $# -ne 9 ]]; then
  echo "开发重启交接参数不完整。" >&2
  exit 0
fi

readonly RUN_DIR="$1"
readonly TARGET_BINARY="$2"
readonly SERVICE_TARGET="$3"
readonly NEW_VERSION="$4"
readonly OLD_VERSION="$5"
readonly CANDIDATE="$6"
readonly BACKUP="$7"
readonly LATEST_STATUS="$8"
readonly BREW_BINARY="$9"
readonly RUN_STATUS="$RUN_DIR/status"

write_status() {
  local value="$1"
  local temp_status="${RUN_STATUS}.new.$$"
  printf '%s\n' "$value" > "$temp_status"
  /bin/chmod 600 "$temp_status"
  # run status 是等待方的完成信号，必须最后发布；否则调用方可能在 latest-status
  # 更新前就 bootout 一次性 job，留下过期的 running 状态。
  /bin/cp -p "$temp_status" "${LATEST_STATUS}.new.$$"
  /bin/mv -f "${LATEST_STATUS}.new.$$" "$LATEST_STATUS"
  /bin/mv -f "$temp_status" "$RUN_STATUS"
}

deploy_binary() {
  local source="$1"
  local staging="${TARGET_BINARY}.mimi-new.$$"
  /bin/cp -p "$source" "$staging"
  /bin/chmod 755 "$staging"
  /usr/bin/codesign --verify --strict --verbose=2 "$staging"
  /bin/mv -f "$staging" "$TARGET_BINARY"
}

restart_service() {
  # 直接操作稳定的 Homebrew label，避免回滚到尚不支持 --no-pair 的旧 CLI 时泄漏访问码。
  if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "$SERVICE_TARGET"
    return
  fi
  "$BREW_BINARY" services start mimi-remote
}

service_ready() {
  local expected_version="$1"
  local attempts=25
  local status_json
  local service_ok
  local cli_version
  while (( attempts > 0 )); do
    status_json="$("$TARGET_BINARY" status --json 2>/dev/null || true)"
    service_ok="$(printf '%s' "$status_json" | /usr/bin/plutil -extract service_ok raw -o - - 2>/dev/null || true)"
    cli_version="$(printf '%s' "$status_json" | /usr/bin/plutil -extract version raw -o - - 2>/dev/null || true)"
    if [[ "$service_ok" == "true" && "$cli_version" == "$expected_version" ]]; then
      return 0
    fi
    attempts=$((attempts - 1))
    /bin/sleep 1
  done
  return 1
}

finish_with_status() {
  local value="$1"
  local keep_backup="${2:-false}"
  /bin/rm -f -- "$CANDIDATE"
  if [[ "$keep_backup" != "true" ]]; then
    /bin/rm -f -- "$BACKUP"
  fi
  # 终态最后发布，等待方看到后即可安全 bootout job，不会截断清理或状态复制。
  write_status "$value"
  exit 0
}

unexpected_failure() {
  trap - ERR
  # 未知故障时宁可多留一份旧二进制，也不要丢掉最后的人工恢复入口。
  /bin/rm -f -- "$CANDIDATE"
  write_status "failed stage=handoff-unexpected version=${NEW_VERSION} backup=${BACKUP}" 2>/dev/null || true
  exit 0
}

trap unexpected_failure ERR

write_status "running version=${NEW_VERSION}"
# 给远程调用方留出返回“已交接”的时间；之后旧服务和当前 WebSocket 可以安全退出。
/bin/sleep 2

if ! deploy_binary "$CANDIDATE"; then
  finish_with_status "failed stage=deploy version=${NEW_VERSION}"
fi
if restart_service && service_ready "$NEW_VERSION"; then
  finish_with_status "ok version=${NEW_VERSION}"
fi

echo "新版本未通过 readyz，正在恢复 ${OLD_VERSION}。" >&2
if deploy_binary "$BACKUP" && restart_service && service_ready "$OLD_VERSION"; then
  finish_with_status "rolled_back failed_version=${NEW_VERSION} restored_version=${OLD_VERSION}"
fi

finish_with_status "failed stage=rollback failed_version=${NEW_VERSION} expected_restore=${OLD_VERSION} service=${SERVICE_TARGET} backup=${BACKUP}" true
