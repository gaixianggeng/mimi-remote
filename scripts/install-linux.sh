#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="mimi-remote.service"

usage() {
  cat <<'USAGE'
用法：
  bash ./scripts/install-linux.sh [install|upgrade|rollback|uninstall|--self-test]

命令：
  install     默认。从当前已解压的 Release 包安装；已有版本会自动备份。
  upgrade     与 install 使用同一安全替换流程，语义上表示升级。
  rollback    恢复 ~/.local/bin/agentd.previous 和上一版 systemd 模板。
  uninstall   停用并移除 user-systemd 服务与安装文件；保留配置和 Token。
  --self-test 只运行参数、架构和版本校验，不修改系统。

约束：
  - 只支持普通 Linux 用户的 systemd user service，不要使用 sudo。
  - install/upgrade 必须在官方 Release 包解压目录中执行。
  - 自定义 AGENTD_CONFIG 或 XDG_CONFIG_HOME 不适用当前固定 service 模板。
USAGE
}

fail() {
  echo "Linux 安装失败：$1" >&2
  return 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "缺少命令 $1。"
  fi
}

# 诊断输出会进入终端或 CI 日志，因此即使 agentd 已经做过一次去敏，安装器仍做兜底。
# 同时限制单行长度，避免异常日志把安装输出撑爆。
redact_diagnostic_line() (
  local value="${1:0:2048}"
  local sensitive_pattern='(token|secret|password|authorization|access[_-]?token|pair_sig)"?[[:space:]]*[:=：][[:space:]]*"?(bearer[[:space:]]+)?[^[:space:],;"&]+|bearer[[:space:]]+[^[:space:],;"&]+'
  local match prefix suffix
  local replacement

  shopt -s nocasematch
  for ((replacement = 0; replacement < 16; replacement++)); do
    if [[ ! "$value" =~ $sensitive_pattern ]]; then
      break
    fi
    match="${BASH_REMATCH[0]}"
    prefix="${value%%"$match"*}"
    suffix="${value#*"$match"}"
    value="${prefix}<redacted>${suffix}"
  done
  printf '%s\n' "$value"
)

print_bounded_redacted_lines() {
  local content="$1"
  local max_lines="$2"
  local empty_message="$3"
  local line
  local line_count=0

  if [[ -z "$content" ]]; then
    echo "$empty_message"
    return
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line_count" -ge "$max_lines" ]]; then
      echo "...诊断输出已截断..."
      return
    fi
    redact_diagnostic_line "$line"
    line_count=$((line_count + 1))
  done <<<"$content"
}

print_readiness_diagnostics() {
  local status_json="$1"
  local status_stderr="$2"
  local journal_output

  echo "就绪检查失败，最后一次去敏状态摘要："
  print_bounded_redacted_lines "$status_json" 40 "（agentd status 没有返回 JSON）"
  if [[ -n "$status_stderr" ]]; then
    echo "agentd status 错误："
    print_bounded_redacted_lines "$status_stderr" 20 "（无）"
  fi

  echo "systemd 最近 80 行去敏日志："
  journal_output="$(journalctl --user -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 || true)"
  print_bounded_redacted_lines "$journal_output" 80 "（journalctl 没有返回日志）"
}

print_path_hint() {
  local install_dir="$1"
  if [[ ":${PATH:-}:" == *":$install_dir:"* ]]; then
    return
  fi

  echo
  echo "当前 shell 的 PATH 尚未包含 ${install_dir}；安装器不会修改 shell rc。"
  echo '需要直接使用 agentd 命令时，先运行：'
  echo '  export PATH="$HOME/.local/bin:$PATH"'
}

normalize_arch() {
  case "$1" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      return 1
      ;;
  esac
}

validate_release_version() {
  local version="$1"
  [[ "$version" != "devel" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

uninstall_linux() {
  local destination_binary="$1"
  local previous_binary="$2"
  local destination_service="$3"
  local previous_service="$4"
  local installed_helper="$5"
  local config_dir="$6"
  local installed_path
  local has_installed_file="0"

  for installed_path in \
    "$destination_binary" \
    "$previous_binary" \
    "$destination_service" \
    "$previous_service" \
    "$installed_helper"; do
    if path_exists "$installed_path"; then
      has_installed_file="1"
      break
    fi
  done

  if [[ "$has_installed_file" == "0" ]]; then
    echo "Mimi Remote Linux 已处于未安装状态。"
  else
    if path_exists "$destination_service"; then
      # 必须先证明服务已停止且不会再自启，才能移除 unit 和二进制。
      # 否则可能留下仍在运行、但已无法用原命令管理的进程。
      if ! systemctl --user stop "$SERVICE_NAME"; then
        fail "停止 $SERVICE_NAME 失败，未删除任何安装文件。"
        return 1
      fi
      if ! systemctl --user disable "$SERVICE_NAME"; then
        fail "禁用 $SERVICE_NAME 失败，未删除任何安装文件。"
        return 1
      fi
    fi

    # 先用 daemon-reload 作为 systemd manager 的破坏性操作前置检查；
    # 删除 unit 后再 reload 一次，确保 manager 不保留已卸载的 unit 定义。
    systemctl --user daemon-reload
    rm -f -- \
      "$destination_service" \
      "$previous_service"
    systemctl --user daemon-reload
    rm -f -- \
      "$destination_binary" \
      "$previous_binary" \
      "$installed_helper"
    echo "Mimi Remote Linux uninstall 完成。"
  fi

  echo "已保留配置和 Token：$config_dir"
  echo "如确认不再使用，可手动永久删除配对凭据："
  echo '  rm -rf -- "$HOME/.config/mimi-remote"'
}

self_test() {
  [[ "$(normalize_arch x86_64)" == "amd64" ]]
  [[ "$(normalize_arch aarch64)" == "arm64" ]]
  if normalize_arch mips64 >/dev/null 2>&1; then
    fail "不支持的架构没有被拒绝。"
  fi
  validate_release_version "0.1.0"
  validate_release_version "0.1.1-rc.1"
  if validate_release_version "devel"; then
    fail "devel 构建没有被拒绝。"
  fi
  if validate_release_version "not-a-version"; then
    fail "非法版本没有被拒绝。"
  fi
  [[ "$(redact_diagnostic_line 'Token：self-test-secret')" == "<redacted>" ]] \
    || fail "中文 Token 诊断没有被去敏。"
  [[ "$(redact_diagnostic_line 'authorization=Bearer self-test-secret')" == "<redacted>" ]] \
    || fail "Bearer 诊断没有被去敏。"
  echo "Linux Release 安装脚本自测通过。"
}

main() {
  local mode="${1:-install}"
  if [[ $# -gt 1 ]]; then
    usage >&2
    return 2
  fi
  case "$mode" in
    install|upgrade|rollback|uninstall)
      ;;
    --self-test)
      self_test
      return
      ;;
    -h|--help)
      usage
      return
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  [[ "$(uname -s)" == "Linux" ]] || fail "仅支持 Linux；macOS 请使用 Homebrew。"
  [[ "${EUID:-$(id -u)}" != "0" ]] || fail "不得使用 root 或 sudo，请以实际登录用户运行。"
  [[ -n "${HOME:-}" ]] || fail "HOME 未设置。"
  [[ -z "${AGENTD_CONFIG:-}" ]] || fail "检测到 AGENTD_CONFIG；当前 systemd 模板只使用默认配置路径。"
  if [[ -n "${XDG_CONFIG_HOME:-}" && "$XDG_CONFIG_HOME" != "$HOME/.config" ]]; then
    fail "XDG_CONFIG_HOME=$XDG_CONFIG_HOME 与当前 systemd 模板的 $HOME/.config 不一致。"
  fi

  local destination_binary="$HOME/.local/bin/agentd"
  local previous_binary="$HOME/.local/bin/agentd.previous"
  local destination_service="$HOME/.config/systemd/user/$SERVICE_NAME"
  local previous_service="$HOME/.config/systemd/user/${SERVICE_NAME}.previous"
  local config_dir="$HOME/.config/mimi-remote"
  local config_path="$HOME/.config/mimi-remote/config.json"
  local installed_helper="$HOME/.local/share/mimi-remote/install-linux.sh"
  local source_binary="$ROOT_DIR/agentd"
  local source_service="$ROOT_DIR/packaging/systemd/mimi-remote.service"

  local command_name
  if [[ "$mode" == "uninstall" ]]; then
    for command_name in rm systemctl; do
      require_command "$command_name"
    done
    uninstall_linux \
      "$destination_binary" \
      "$previous_binary" \
      "$destination_service" \
      "$previous_service" \
      "$installed_helper" \
      "$config_dir"
    return
  fi

  for command_name in cmp grep id install journalctl mkdir mktemp mv rm sleep systemctl uname; do
    require_command "$command_name"
  done
  normalize_arch "$(uname -m)" >/dev/null \
    || fail "仅支持 Linux amd64/arm64，当前架构为 $(uname -m)。"

  if [[ "$mode" == "rollback" ]]; then
    source_binary="$previous_binary"
    source_service="$previous_service"
    [[ -x "$source_binary" ]] || fail "缺少 ${previous_binary}，无法回滚。"
    [[ -f "$source_service" ]] || fail "缺少 ${previous_service}，无法回滚 service 模板。"
  else
    [[ -x "$source_binary" ]] \
      || fail "当前目录不是完整 Release 包：缺少可执行的 agentd。"
    [[ -f "$source_service" ]] \
      || fail "当前目录不是完整 Release 包：缺少 systemd 模板。"
  fi

  local source_version
  source_version="$("$source_binary" version)" \
    || fail "agentd 无法在当前机器执行，可能下载了错误架构的归档。"
  validate_release_version "$source_version" \
    || fail "拒绝安装非正式版本：${source_version}。"

  local work_dir
  work_dir="$(mktemp -d)"
  local transaction_started="0"
  local completed="0"
  local had_binary="0"
  local had_service="0"
  local was_enabled="0"
  local was_active="0"
  local created_config="0"

  cleanup() {
    rm -rf "$work_dir"
    rm -f "${destination_binary}.new.$$" "${destination_service}.new.$$"
  }

  # 任一步骤失败都恢复安装前的二进制和 unit；首次安装失败则停用残留服务。
  rollback_on_error() {
    local status=$?
    trap - ERR
    if [[ "$transaction_started" == "1" && "$completed" != "1" ]]; then
      echo "安装未通过就绪检查，正在恢复安装前版本..." >&2
      if [[ "$had_binary" == "1" ]]; then
        install -m 755 "$work_dir/agentd.before" "${destination_binary}.restore.$$" || true
        mv -f "${destination_binary}.restore.$$" "$destination_binary" || true
      else
        rm -f "$destination_binary"
      fi
      if [[ "$had_service" == "1" ]]; then
        install -m 644 "$work_dir/service.before" "${destination_service}.restore.$$" || true
        mv -f "${destination_service}.restore.$$" "$destination_service" || true
      else
        rm -f "$destination_service"
      fi
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      if [[ "$was_enabled" == "1" ]]; then
        systemctl --user enable "$SERVICE_NAME" >/dev/null 2>&1 || true
      else
        systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      fi
      if [[ "$was_active" == "1" ]]; then
        systemctl --user restart "$SERVICE_NAME" >/dev/null 2>&1 || true
      else
        systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
      fi
    fi
    cleanup
    exit "$status"
  }
  trap cleanup EXIT
  trap rollback_on_error ERR

  mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/code"
  install -m 755 "$source_binary" "$work_dir/agentd.source"
  install -m 644 "$source_service" "$work_dir/service.source"

  if [[ -f "$destination_binary" ]]; then
    had_binary="1"
    install -m 755 "$destination_binary" "$work_dir/agentd.before"
  fi
  if [[ -f "$destination_service" ]]; then
    had_service="1"
    install -m 644 "$destination_service" "$work_dir/service.before"
  fi
  if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    was_enabled="1"
  fi
  if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    was_active="1"
  fi

  transaction_started="1"
  if [[ "$had_binary" == "1" ]]; then
    install -m 755 "$work_dir/agentd.before" "${previous_binary}.new.$$"
    mv -f "${previous_binary}.new.$$" "$previous_binary"
  fi
  if [[ "$had_service" == "1" ]]; then
    install -m 644 "$work_dir/service.before" "${previous_service}.new.$$"
    mv -f "${previous_service}.new.$$" "$previous_service"
  fi

  install -m 755 "$work_dir/agentd.source" "${destination_binary}.new.$$"
  [[ "$("${destination_binary}.new.$$" version)" == "$source_version" ]] \
    || fail "暂存二进制版本校验失败。"
  mv -f "${destination_binary}.new.$$" "$destination_binary"
  install -m 644 "$work_dir/service.source" "${destination_service}.new.$$"
  mv -f "${destination_service}.new.$$" "$destination_service"

  if [[ ! -f "$config_path" ]]; then
    created_config="1"
    # setup 的普通输出包含长期 Token 和尚未就绪的二维码；首次安装先静默建配置，
    # 只有服务通过真实 readiness 且事务提交后才在终端展示配对信息。
    "$destination_binary" setup --scan-root "$HOME/code" --browse-root "$HOME" >/dev/null
  fi
  "$destination_binary" doctor --fix

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  if [[ "$was_active" == "1" ]]; then
    # enable --now 不会重启已经运行的旧进程，升级时必须显式 restart。
    systemctl --user restart "$SERVICE_NAME"
  else
    systemctl --user start "$SERVICE_NAME"
  fi

  local status_json=""
  local status_stderr_path="$work_dir/status.stderr"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    status_json="$("$destination_binary" status --json 2>"$status_stderr_path" || true)"
    if grep -Eq '"service_ok"[[:space:]]*:[[:space:]]*true' <<<"$status_json" \
      && grep -Eq '"doctor_ok"[[:space:]]*:[[:space:]]*true' <<<"$status_json"; then
      completed="1"
      break
    fi
    sleep 1
  done
  if [[ "$completed" != "1" ]]; then
    # 必须在 rollback 删除新二进制和 unit 前取证；所有输出有界并再次去敏。
    print_readiness_diagnostics "$status_json" "$(<"$status_stderr_path")" >&2
    fail "服务或必要环境检查在 10 秒内未就绪；安装前版本已自动恢复。"
  fi

  mkdir -p "$HOME/.local/share/mimi-remote"
  if [[ ! -f "$installed_helper" ]] || ! cmp -s "${BASH_SOURCE[0]}" "$installed_helper"; then
    if ! install -m 755 "${BASH_SOURCE[0]}" "$installed_helper"; then
      echo "警告：服务已就绪，但没有保存回滚脚本；请保留当前 Release 解压目录。" >&2
    fi
  fi
  trap - ERR
  cleanup
  trap - EXIT
  echo "Mimi Remote Linux ${mode} 完成：agentd ${source_version}。"
  echo "配置：$config_path"
  echo "服务：systemctl --user status $SERVICE_NAME"
  echo "回滚：bash $installed_helper rollback"
  print_path_hint "$HOME/.local/bin"
  echo "状态：\"$destination_binary\" status"
  echo "日志：\"$destination_binary\" logs -n 200"
  echo "重启：\"$destination_binary\" restart"
  echo "配对：\"$destination_binary\" pair --qr-only"

  if [[ "$created_config" == "1" ]]; then
    echo
    echo "服务已就绪，请用移动端扫描下面的配对二维码："
    # 配对属于安装后的交互交接；失败只给出绝对路径重试命令，不能回滚已提交事务。
    if ! "$destination_binary" pair --qr-only; then
      echo "警告：服务已安装并就绪，但暂时无法生成配对信息。请重试：\"$destination_binary\" pair --qr-only" >&2
    fi
  fi
}

main "$@"
