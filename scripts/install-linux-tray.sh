#!/usr/bin/env bash
# The tray has its own reversible file transaction. agentd remains the owner of
# the user service; installing or quitting this UI never starts/stops that service.
set -Eeuo pipefail
umask 077

TRAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-install}"
case "$mode" in install|upgrade|rollback|uninstall) ;; *) echo '用法：install-linux-tray.sh [install|upgrade|rollback|uninstall]' >&2; exit 2 ;; esac
[[ "$(uname -s)" == Linux && "$(id -u)" != 0 ]] || { echo '请在 Linux 上以普通用户安装托盘，不要使用 sudo。' >&2; exit 1; }

tray_data="$HOME/.local/share/mimi-remote"
tray_binary="$HOME/.local/bin/mimi-remote-tray"
tray_config="${XDG_CONFIG_HOME:-$HOME/.config}"
previous="$tray_data/tray.previous"
[[ "$HOME$tray_config" != *$'\n'* && "$HOME$tray_config" != *$'\r'* ]] || { echo '桌面入口路径不能包含换行符。' >&2; exit 1; }
# Snapshot indexes include the helper itself, so upgrades and rollback use
# matching binaries and desktop metadata, including absent-file markers.
files=("$tray_binary" "$tray_data/mimi.png" "$HOME/.local/share/applications/mimi-remote.desktop" "$tray_config/autostart/mimi-remote.desktop" "$tray_data/install-linux-tray.sh")
modes=(755 644 644 644 755)

stop_tray() {
  if [[ -x "$tray_binary" ]]; then
    "$tray_binary" --quit
  fi
}
start_tray() {
  if [[ "${MIMI_TRAY_NO_START:-0}" != 1 && ( -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ) && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    mkdir -p "$tray_data"
    nohup "$tray_binary" >"$tray_data/tray.log" 2>&1 </dev/null &
  fi
}

if [[ "$mode" == uninstall ]]; then
  stop_tray
  for file in "${files[@]}"; do rm -f -- "$file"; done
  rm -rf -- "$previous"
  echo 'Linux 托盘已卸载；agentd 服务和配对配置由主安装器管理。'
  exit 0
fi

stage="$(mktemp -d)"
started=0
finished=0
snapshot() {
  local directory="$1" index
  mkdir -p "$directory"
  for index in "${!files[@]}"; do
    if [[ -f "${files[$index]}" ]]; then
      install -m "${modes[$index]}" "${files[$index]}" "$directory/$index"
    else
      : >"$directory/$index.absent"
    fi
  done
}
restore() {
  local directory="$1" index destination
  for index in "${!files[@]}"; do
    destination="${files[$index]}"
    if [[ -f "$directory/$index.absent" ]]; then
      rm -f -- "$destination"
    else
      mkdir -p "$(dirname "$destination")"
      install -m "${modes[$index]}" "$directory/$index" "$destination.new.$$"
      mv -f -- "$destination.new.$$" "$destination"
    fi
  done
}
cleanup() {
  local status=$? file
  trap - EXIT
  if [[ "$started" == 1 && "$finished" != 1 ]]; then
    restore "$stage/before" || echo '托盘文件恢复失败，请从 Release 包重新安装。' >&2
    [[ ! -x "$tray_binary" ]] || start_tray
  fi
  for file in "${files[@]}"; do rm -f -- "$file.new.$$"; done
  rm -rf -- "$stage"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$stage/source"
if [[ "$mode" == rollback ]]; then
  [[ -d "$previous" ]] || { echo '没有可回滚的托盘版本。' >&2; exit 1; }
  for index in "${!files[@]}"; do
    if [[ -f "$previous/$index.absent" ]]; then
      : >"$stage/source/$index.absent"
    else
      install -m "${modes[$index]}" "$previous/$index" "$stage/source/$index"
    fi
  done
else
  candidate="$TRAY_ROOT/mimi-remote-tray"
  [[ -x "$candidate" ]] || { echo 'Release 包缺少 mimi-remote-tray。' >&2; exit 1; }
  [[ "$("$candidate" version)" == "$("$TRAY_ROOT/agentd" version)" ]] || { echo '托盘与 agentd 版本不一致。' >&2; exit 1; }
  install -m 755 "$candidate" "$stage/source/0"
  install -m 644 "$TRAY_ROOT/cmd/mimi-remote-tray/assets/mimi.png" "$stage/source/1"
  install -m 755 "${BASH_SOURCE[0]}" "$stage/source/4"
  # Desktop Entry Exec has its own escaping rules; never interpolate a shell.
  desktop_exec="$tray_binary"
  desktop_exec="${desktop_exec//\\/\\\\}"
  desktop_exec="${desktop_exec//\$/\\\$}"
  desktop_exec="${desktop_exec//\`/\\\`}"
  desktop_exec="${desktop_exec//\"/\\\"}"
  desktop_exec="${desktop_exec//%/%%}"
  {
    cat "$TRAY_ROOT/packaging/linux/mimi-remote.desktop"
    printf 'Exec="%s" --show\nIcon=%s/mimi.png\n' "$desktop_exec" "$tray_data"
  } >"$stage/source/2"
  {
    cat "$TRAY_ROOT/packaging/linux/mimi-remote.desktop"
    printf 'Exec="%s"\nIcon=%s/mimi.png\n' "$desktop_exec" "$tray_data"
    if [[ -f "${files[3]}" ]] && grep -Eq '^Hidden=true[[:space:]]*$' "${files[3]}"; then
      echo 'Hidden=true'
    fi
  } >"$stage/source/3"
fi
snapshot "$stage/before"
stop_tray
started=1
restore "$stage/source"
mkdir -p "$tray_data"
# Build the complete previous snapshot before replacing the old one.
rm -rf -- "$previous.new.$$"
cp -a "$stage/before" "$previous.new.$$"
rm -rf -- "$previous"
mv -- "$previous.new.$$" "$previous"
finished=1
[[ ! -x "$tray_binary" ]] || start_tray
printf 'Linux 托盘 %s 完成；登录后自动显示，也可从应用菜单打开 Mimi Remote。\n' "$mode"
