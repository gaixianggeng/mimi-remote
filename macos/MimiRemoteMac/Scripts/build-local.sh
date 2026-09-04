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

for command_name in xcodegen xcodebuild; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少构建工具：$command_name" >&2
    exit 1
  fi
done

xcodegen generate --spec "$project_dir/project.yml" --project "$project_dir"
bash "$repo_root/scripts/development-cache-lock.sh" "$cache_lock" -- \
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
/usr/bin/codesign --verify --deep --strict "$app_path"
"$app_path/Contents/Resources/agentd" version >/dev/null

echo "本地构建完成：$app_path"
