#!/usr/bin/env bash

# 这个文件由 ios-dev.sh source。设备租约目录位于 /tmp，确保不同 Codex
# Worktree 使用同一个原子占用入口；不在仓库或设备上写入任何状态。

IOS_DEVICE_LEASE_ROOT="${IOS_DEVICE_LEASE_ROOT:-/tmp/mimi-remote-ios-device-leases-${UID:-$(id -u)}}"
IOS_DEVICE_LEASE_PS_BIN="${IOS_DEVICE_LEASE_PS_BIN:-ps}"
IOS_DEVICE_LEASE_TASK_ID="${IOS_DEVICE_LEASE_TASK_ID:-${CODEX_THREAD_ID:-unknown}}"
IOS_DEVICE_LEASE_WORKTREE="${IOS_DEVICE_LEASE_WORKTREE:-${ROOT_DIR:-unknown}}"
IOS_DEVICE_LEASE_WAIT_SECONDS="${IOS_DEVICE_LEASE_WAIT_SECONDS:-0}"
IOS_DEVICE_LEASE_POLL_SECONDS="${IOS_DEVICE_LEASE_POLL_SECONDS:-1}"
IOS_DEVICE_LEASE_PROGRESS_SECONDS="${IOS_DEVICE_LEASE_PROGRESS_SECONDS:-30}"
IOS_DEVICE_LEASE_ACQUIRE_GRACE_SECONDS="${IOS_DEVICE_LEASE_ACQUIRE_GRACE_SECONDS:-10}"

IOS_DEVICE_LEASE_ACTIVE_DIR=""
IOS_DEVICE_LEASE_BUSY_DETAIL=""

ios_lease_validate_device_id() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*)
      echo "设备 ID 包含不安全字符：$1" >&2
      return 2
      ;;
  esac
}

ios_lease_dir_for() {
  local device_id="$1"
  ios_lease_validate_device_id "$device_id" || return
  printf '%s/%s.lease\n' "$IOS_DEVICE_LEASE_ROOT" "$device_id"
}

ios_lease_safe_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

ios_lease_metadata_value() {
  local lease_dir="$1"
  local requested_key="$2"
  local key value
  [[ -f "$lease_dir/metadata" ]] || return 1
  while IFS=$'\t' read -r key value; do
    if [[ "$key" == "$requested_key" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < "$lease_dir/metadata"
  return 1
}

ios_lease_format_duration() {
  local total="$1"
  if (( total >= 3600 )); then
    printf '%dh%02dm%02ds' "$((total / 3600))" "$((total % 3600 / 60))" "$((total % 60))"
  elif (( total >= 60 )); then
    printf '%dm%02ds' "$((total / 60))" "$((total % 60))"
  else
    printf '%ds' "$total"
  fi
}

# 一行说明占用者：排队时需要知道是谁、做什么、已经占用多久，才能判断等待还是协调。
ios_lease_owner_summary() {
  local lease_dir="$1"
  local owner_pid task command started_epoch now summary
  owner_pid="$(ios_lease_metadata_value "$lease_dir" pid 2>/dev/null || printf unknown)"
  task="$(ios_lease_metadata_value "$lease_dir" task 2>/dev/null || printf unknown)"
  command="$(ios_lease_metadata_value "$lease_dir" command 2>/dev/null || true)"
  started_epoch="$(ios_lease_metadata_value "$lease_dir" started_epoch 2>/dev/null || true)"
  summary="PID ${owner_pid}，Task ${task}"
  if [[ "$started_epoch" =~ ^[0-9]+$ ]]; then
    now="$(date '+%s')"
    (( now >= started_epoch )) \
      && summary="${summary}，已占用 $(ios_lease_format_duration "$((now - started_epoch))")"
  fi
  if [[ -n "$command" ]]; then
    (( ${#command} > 120 )) && command="${command:0:117}..."
    summary="${summary}，命令 ${command}"
  fi
  printf '%s\n' "$summary"
}

ios_lease_process_start() {
  local pid="$1"
  "$IOS_DEVICE_LEASE_PS_BIN" -p "$pid" -o lstart= 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | head -n 1
}

ios_lease_dir_age_seconds() {
  local lease_dir="$1"
  local modified_at now
  if modified_at="$(/usr/bin/stat -f '%m' "$lease_dir" 2>/dev/null)"; then
    :
  elif modified_at="$(stat -c '%Y' "$lease_dir" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  now="$(date '+%s')"
  printf '%s\n' "$((now - modified_at))"
}

ios_lease_owner_is_alive() {
  local lease_dir="$1"
  local owner_pid recorded_start current_start lease_age
  if [[ ! -f "$lease_dir/metadata" ]]; then
    lease_age="$(ios_lease_dir_age_seconds "$lease_dir" 2>/dev/null || true)"
    [[ "$lease_age" =~ ^[0-9]+$ && "$lease_age" -le "$IOS_DEVICE_LEASE_ACQUIRE_GRACE_SECONDS" ]]
    return
  fi
  owner_pid="$(ios_lease_metadata_value "$lease_dir" pid 2>/dev/null || true)"
  recorded_start="$(ios_lease_metadata_value "$lease_dir" pid_start 2>/dev/null || true)"

  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 1

  # PID 可能被系统复用；记录的进程启动时间不一致时把租约视为过期。
  if [[ -n "$recorded_start" ]]; then
    current_start="$(ios_lease_process_start "$owner_pid")"
    [[ -n "$current_start" && "$current_start" == "$recorded_start" ]] || return 1
  fi
  return 0
}

ios_lease_remove_dir() {
  local lease_dir="$1"
  local moved_dir
  [[ -d "$lease_dir" ]] || return 0
  moved_dir="${lease_dir}.cleanup.$$.$RANDOM"
  if mv "$lease_dir" "$moved_dir" 2>/dev/null; then
    rm -f "$moved_dir/metadata" "$moved_dir/metadata.tmp"
    rmdir "$moved_dir" 2>/dev/null || true
  fi
}

ios_lease_cleanup_stale() {
  local lease_dir="$1"
  [[ -d "$lease_dir" ]] || return 0
  if ! ios_lease_owner_is_alive "$lease_dir"; then
    ios_lease_remove_dir "$lease_dir"
  fi
}

ios_lease_find_external_xcodebuild() {
  local device_id="$1"
  local device_name="$2"
  local device_kind="$3"
  local line trimmed pid process_command

  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    pid="${trimmed%%[[:space:]]*}"
    process_command="${trimmed#"$pid"}"
    process_command="${process_command#"${process_command%%[![:space:]]*}"}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    case " $process_command " in
      *"/xcodebuild "*|*" xcodebuild "*) ;;
      *) continue ;;
    esac

    if [[ "$process_command" == *"$device_id"* ]]; then
      printf '%s\t%s\n' "$pid" "$process_command"
      return 0
    fi
    if [[ "$process_command" == *"-destination"* && "$process_command" == *"name=$device_name"* ]]; then
      printf '%s\t%s\n' "$pid" "$process_command"
      return 0
    fi
    if [[ "$device_kind" == "device" && "$process_command" == *"generic/platform=iOS"* && "$process_command" != *"Simulator"* ]]; then
      printf '%s\t%s\n' "$pid" "$process_command"
      return 0
    fi
    if [[ "$device_kind" == "simulator" && "$process_command" == *"generic/platform=iOS Simulator"* ]]; then
      printf '%s\t%s\n' "$pid" "$process_command"
      return 0
    fi
  done < <(
    # 先按子串预筛：不含 xcodebuild 的进程在下方循环中总会被跳过。机器上常有数千个
    # 进程，逐行交给 bash 匹配会让每次租约尝试多花数秒，排队轮询也随之变慢。
    { "$IOS_DEVICE_LEASE_PS_BIN" -axo pid=,command= 2>/dev/null || true; } | grep -F xcodebuild || true
  )
  return 1
}

ios_lease_read_state() {
  local device_kind="$1"
  local device_id="$2"
  local device_name="$3"
  local lease_dir external_record owner_pid
  lease_dir="$(ios_lease_dir_for "$device_id")" || return

  if [[ -d "$lease_dir" ]]; then
    if ios_lease_owner_is_alive "$lease_dir"; then
      owner_pid="$(ios_lease_metadata_value "$lease_dir" pid 2>/dev/null || true)"
      if [[ -f "$lease_dir/metadata" ]]; then
        IOS_DEVICE_LEASE_BUSY_DETAIL="租约占用：$(ios_lease_owner_summary "$lease_dir")"
      else
        IOS_DEVICE_LEASE_BUSY_DETAIL="租约正在建立，等待 owner metadata"
      fi
      printf 'leased\t%s\t%s\n' "$lease_dir" "$IOS_DEVICE_LEASE_BUSY_DETAIL"
      return 0
    fi
    IOS_DEVICE_LEASE_BUSY_DETAIL="发现死 PID 或 PID 已复用的过期租约；下一次占用时会安全清理"
    printf 'stale\t%s\t%s\n' "$lease_dir" "$IOS_DEVICE_LEASE_BUSY_DETAIL"
    return 0
  fi

  if external_record="$(ios_lease_find_external_xcodebuild "$device_id" "$device_name" "$device_kind")"; then
    IOS_DEVICE_LEASE_BUSY_DETAIL="外部 xcodebuild：PID ${external_record%%$'\t'*}"
    printf 'external\t%s\t%s\n' "${external_record%%$'\t'*}" "${external_record#*$'\t'}"
    return 0
  fi

  IOS_DEVICE_LEASE_BUSY_DETAIL=""
  printf 'free\t\t\n'
}

ios_lease_device_is_available() {
  local device_kind="$1"
  local device_id="$2"
  local device_name="$3"
  local state_record state remainder
  state_record="$(ios_lease_read_state "$device_kind" "$device_id" "$device_name")"
  state="${state_record%%$'\t'*}"
  remainder="${state_record#*$'\t'}"
  if [[ "$state" == "external" ]]; then
    IOS_DEVICE_LEASE_BUSY_DETAIL="外部 xcodebuild：PID ${remainder%%$'\t'*}"
  else
    IOS_DEVICE_LEASE_BUSY_DETAIL="${remainder#*$'\t'}"
  fi
  case "$state" in
    free|stale) return 0 ;;
    *) return 1 ;;
  esac
}

ios_lease_try_acquire() {
  local device_kind="$1"
  local device_id="$2"
  local device_name="$3"
  local lease_command="$4"
  local derived_data_path="$5"
  local lease_dir external_record pid_start started_at

  lease_dir="$(ios_lease_dir_for "$device_id")" || return
  umask 077
  mkdir -p "$IOS_DEVICE_LEASE_ROOT"
  ios_lease_cleanup_stale "$lease_dir"

  if external_record="$(ios_lease_find_external_xcodebuild "$device_id" "$device_name" "$device_kind")"; then
    IOS_DEVICE_LEASE_BUSY_DETAIL="外部 xcodebuild 正在使用 ${device_name}：PID ${external_record%%$'\t'*}"
    return 1
  fi

  if ! mkdir "$lease_dir" 2>/dev/null; then
    if ios_lease_owner_is_alive "$lease_dir"; then
      if [[ -f "$lease_dir/metadata" ]]; then
        IOS_DEVICE_LEASE_BUSY_DETAIL="$device_name 已被占用：$(ios_lease_owner_summary "$lease_dir")"
      else
        IOS_DEVICE_LEASE_BUSY_DETAIL="$device_name 的租约正在建立，等待 owner metadata"
      fi
      return 1
    fi
    ios_lease_cleanup_stale "$lease_dir"
    if ! mkdir "$lease_dir" 2>/dev/null; then
      IOS_DEVICE_LEASE_BUSY_DETAIL="$device_name 的设备租约正在被其他进程更新"
      return 1
    fi
  fi

  # 获取原子目录后再次检查外部 xcodebuild，缩小绕过统一脚本时的竞态窗口。
  if external_record="$(ios_lease_find_external_xcodebuild "$device_id" "$device_name" "$device_kind")"; then
    IOS_DEVICE_LEASE_BUSY_DETAIL="外部 xcodebuild 正在使用 ${device_name}：PID ${external_record%%$'\t'*}"
    ios_lease_remove_dir "$lease_dir"
    return 1
  fi

  pid_start="$(ios_lease_process_start "$$")"
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  {
    printf 'pid\t%s\n' "$$"
    printf 'pid_start\t%s\n' "$(ios_lease_safe_field "$pid_start")"
    printf 'task\t%s\n' "$(ios_lease_safe_field "$IOS_DEVICE_LEASE_TASK_ID")"
    printf 'worktree\t%s\n' "$(ios_lease_safe_field "$IOS_DEVICE_LEASE_WORKTREE")"
    printf 'command\t%s\n' "$(ios_lease_safe_field "$lease_command")"
    printf 'derived_data\t%s\n' "$(ios_lease_safe_field "$derived_data_path")"
    printf 'started_at\t%s\n' "$started_at"
    printf 'started_epoch\t%s\n' "$(date '+%s')"
    printf 'kind\t%s\n' "$device_kind"
    printf 'device_id\t%s\n' "$device_id"
    printf 'device_name\t%s\n' "$(ios_lease_safe_field "$device_name")"
  } > "$lease_dir/metadata.tmp"
  mv "$lease_dir/metadata.tmp" "$lease_dir/metadata"

  IOS_DEVICE_LEASE_ACTIVE_DIR="$lease_dir"
  IOS_DEVICE_LEASE_BUSY_DETAIL=""
  return 0
}

ios_lease_acquire_wait() {
  local device_kind="$1"
  local device_id="$2"
  local device_name="$3"
  local lease_command="$4"
  local derived_data_path="$5"
  local started_epoch now_epoch waited=0 announced=0 last_progress=0
  if [[ ! "$IOS_DEVICE_LEASE_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "IOS_DEVICE_LEASE_WAIT_SECONDS 必须是非负整数：$IOS_DEVICE_LEASE_WAIT_SECONDS" >&2
    return 2
  fi
  if [[ ! "$IOS_DEVICE_LEASE_PROGRESS_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "IOS_DEVICE_LEASE_PROGRESS_SECONDS 必须是正整数：$IOS_DEVICE_LEASE_PROGRESS_SECONDS" >&2
    return 2
  fi
  started_epoch="$(date '+%s')"

  while true; do
    if ios_lease_try_acquire "$device_kind" "$device_id" "$device_name" "$lease_command" "$derived_data_path"; then
      if [[ "$announced" == "1" ]]; then
        now_epoch="$(date '+%s')"
        echo "==> 已获得设备租约：${device_name}，排队 $(ios_lease_format_duration "$((now_epoch - started_epoch))")" >&2
      fi
      return 0
    fi
    now_epoch="$(date '+%s')"
    waited=$((now_epoch - started_epoch))
    if (( waited >= IOS_DEVICE_LEASE_WAIT_SECONDS )); then
      echo "设备忙，未切换到其他测试设备：$device_name ($device_id)" >&2
      echo "$IOS_DEVICE_LEASE_BUSY_DETAIL" >&2
      if (( IOS_DEVICE_LEASE_WAIT_SECONDS == 0 )); then
        echo "需要排队时设置 IOS_DEVICE_LEASE_WAIT_SECONDS=<秒>，占用结束后自动继续；超时仍按阻塞（75）处理。" >&2
      else
        echo "已排队 $(ios_lease_format_duration "$waited")，达到 IOS_DEVICE_LEASE_WAIT_SECONDS=${IOS_DEVICE_LEASE_WAIT_SECONDS}。" >&2
      fi
      echo "查看占用：bash ./scripts/ios-dev.sh leases" >&2
      return 75
    fi
    # 等待期间只在开始和每个进度间隔输出一次，避免刷屏，也让调用方知道仍在排队。
    if [[ "$announced" == "0" ]]; then
      echo "==> 设备忙，排队等待租约（最长 ${IOS_DEVICE_LEASE_WAIT_SECONDS}s，不切换设备）：$device_name ($device_id)" >&2
      echo "    $IOS_DEVICE_LEASE_BUSY_DETAIL" >&2
      announced=1
      last_progress="$waited"
    elif (( waited - last_progress >= IOS_DEVICE_LEASE_PROGRESS_SECONDS )); then
      echo "    仍在排队：已等待 $(ios_lease_format_duration "$waited") / ${IOS_DEVICE_LEASE_WAIT_SECONDS}s · $IOS_DEVICE_LEASE_BUSY_DETAIL" >&2
      last_progress="$waited"
    fi
    sleep "$IOS_DEVICE_LEASE_POLL_SECONDS"
  done
}

ios_lease_release_active() {
  local owner_pid
  [[ -n "$IOS_DEVICE_LEASE_ACTIVE_DIR" && -d "$IOS_DEVICE_LEASE_ACTIVE_DIR" ]] || return 0
  owner_pid="$(ios_lease_metadata_value "$IOS_DEVICE_LEASE_ACTIVE_DIR" pid 2>/dev/null || true)"
  if [[ "$owner_pid" == "$$" ]]; then
    ios_lease_remove_dir "$IOS_DEVICE_LEASE_ACTIVE_DIR"
  fi
  IOS_DEVICE_LEASE_ACTIVE_DIR=""
}

ios_lease_install_traps() {
  trap 'ios_lease_release_active' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

ios_lease_print_status() {
  local device_kind="$1"
  local device_id="$2"
  local device_name="$3"
  local state_record state remainder payload detail lease_dir key value
  state_record="$(ios_lease_read_state "$device_kind" "$device_id" "$device_name")"
  state="${state_record%%$'\t'*}"
  remainder="${state_record#*$'\t'}"
  payload="${remainder%%$'\t'*}"
  detail="${remainder#*$'\t'}"

  printf '%-9s %-10s %s (%s)\n' "$state" "$device_kind" "$device_name" "$device_id"
  case "$state" in
    leased|stale)
      lease_dir="$payload"
      for key in pid task worktree command derived_data started_at; do
        value="$(ios_lease_metadata_value "$lease_dir" "$key" 2>/dev/null || true)"
        [[ -n "$value" ]] && printf '  %-12s %s\n' "$key:" "$value"
      done
      value="$(ios_lease_metadata_value "$lease_dir" started_epoch 2>/dev/null || true)"
      if [[ "$state" == "leased" && "$value" =~ ^[0-9]+$ ]]; then
        printf '  %-12s %s\n' "held_for:" "$(ios_lease_format_duration "$(( $(date '+%s') - value ))")"
      fi
      [[ "$state" == "stale" ]] && printf '  note:        %s\n' "$detail"
      ;;
    external)
      printf '  pid:         %s\n' "$payload"
      printf '  command:     %s\n' "$detail"
      ;;
  esac
  return 0
}
