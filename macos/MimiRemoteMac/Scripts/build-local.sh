#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$project_dir/../.." && pwd)"
configuration="${CONFIGURATION:-Release}"
architecture="$(uname -m)"
case "$architecture" in
  arm64|x86_64) ;;
  *) echo "不支持的 Mac 架构：$architecture" >&2; exit 1 ;;
esac
development_cache="$(
  bash "$repo_root/scripts/development-cache-path.sh" \
    "xcode/macos/$architecture/$configuration"
)"
derived_data="${MACOS_DERIVED_DATA_PATH:-$development_cache/DerivedData}"
embed_cache="${MACOS_EMBED_CACHE_DIR:-$development_cache/EmbedCache}"
cache_lock="${MACOS_DEVELOPMENT_CACHE_LOCK:-$derived_data.lock}"
[[ $# -le 1 ]] || { echo "用法：build-local.sh [暂存 App 路径]" >&2; exit 2; }

for command_name in xcodegen xcodebuild codesign ditto; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少构建工具：$command_name" >&2
    exit 1
  fi
done

# 从当前 Worktree 增量构建、验证和复制必须持有同一把锁，避免安装时
# 被另一分支替换共享 DerivedData 中的 App。可选参数仅用于安装暂存。
bash "$repo_root/scripts/development-cache-lock.sh" "$cache_lock" -- \
  bash -euo pipefail -c '
project_dir="$1"
configuration="$2"
architecture="$3"
derived_data="$4"
embed_cache="$5"
staged_app="$6"
xcodegen generate --spec "$project_dir/project.yml" --project "$project_dir"
xcodebuild \
  -quiet \
  -project "$project_dir/MimiRemoteMac.xcodeproj" \
  -scheme MimiRemoteMac \
  -configuration "$configuration" \
  -destination "platform=macOS,arch=$architecture" \
  -derivedDataPath "$derived_data" \
  MACOS_EMBED_CACHE_DIR="$embed_cache" \
  CODE_SIGN_STYLE=Automatic \
  build

app_path="$derived_data/Build/Products/$configuration/Mimi Remote Mac.app"
codesign --verify --deep --strict "$app_path"
"$app_path/Contents/Resources/agentd" version >/dev/null
if [[ -n "$staged_app" ]]; then
  ditto "$app_path" "$staged_app"
fi

echo "本地构建完成：$app_path"
' _ "$project_dir" "$configuration" "$architecture" "$derived_data" "$embed_cache" "${1:-}"
