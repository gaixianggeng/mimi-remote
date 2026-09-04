#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
architecture="$(uname -m)"
development_cache="$(
  bash "$repo_root/scripts/development-cache-path.sh" \
    "xcode/macos/$architecture/Release"
)"
derived_data="${MACOS_DERIVED_DATA_PATH:-$development_cache/DerivedData}"
source_app="$derived_data/Build/Products/Release/Mimi Remote Mac.app"

# Default to wherever the app is already installed. Picking a fixed default
# instead is how a rebuild silently lands beside the running copy: the new
# version installs, the login item keeps launching agentd out of the old
# bundle, and everything looks deployed while none of it is.
default_destination() {
  local candidates=("/Applications/Mimi Remote Mac.app" "$HOME/Applications/Mimi Remote Mac.app")
  local found=()
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -d "$candidate" ]] && found+=("$candidate")
  done
  case ${#found[@]} in
    0) printf '%s\n' "$HOME/Applications/Mimi Remote Mac.app" ;;
    1) printf '%s\n' "${found[0]}" ;;
    *)
      echo "检测到多处已安装，请显式指定目标：" >&2
      printf '  %s\n' "${found[@]}" >&2
      return 1
      ;;
  esac
}

if [[ $# -ge 1 ]]; then
  destination="$1"
else
  destination="$(default_destination)" || exit 2
  echo "沿用已安装位置：$destination"
fi
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
