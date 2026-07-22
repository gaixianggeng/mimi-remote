#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
source_app="$repo_root/.build/MimiRemoteMac/Build/Products/Release/Mimi Remote Mac.app"
destination="${1:-$HOME/Applications/Mimi Remote Mac.app}"
destination_parent="$(dirname "$destination")"

if [[ ! -d "$source_app" ]]; then
  CONFIGURATION=Release bash "$script_dir/build-local.sh"
fi
if [[ "$(basename "$destination")" != "Mimi Remote Mac.app" ]]; then
  echo "安装目标必须以 Mimi Remote Mac.app 结尾：$destination" >&2
  exit 2
fi
if pgrep -x "Mimi Remote Mac" >/dev/null 2>&1; then
  echo "请先从菜单栏退出 Mimi Remote Mac，再重新安装。" >&2
  exit 1
fi

mkdir -p "$destination_parent"
staging_dir="$(mktemp -d "$destination_parent/.mimi-remote-install.XXXXXX")"
staged_app="$staging_dir/Mimi Remote Mac.app"
backup_app=""
cleanup() {
  rm -rf -- "$staging_dir"
}
trap cleanup EXIT

/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

if [[ -e "$destination" ]]; then
  backup_app="$destination_parent/Mimi Remote Mac.backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$destination" "$backup_app"
fi

if ! mv "$staged_app" "$destination"; then
  if [[ -n "$backup_app" && -e "$backup_app" && ! -e "$destination" ]]; then
    mv "$backup_app" "$destination"
  fi
  exit 1
fi

echo "已安装：$destination"
if [[ -n "$backup_app" ]]; then
  echo "旧版本备份：$backup_app"
fi
echo "首次启动后，可在菜单栏完成 Homebrew 服务接管。"
