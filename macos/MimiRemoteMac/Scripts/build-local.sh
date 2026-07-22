#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$project_dir/../.." && pwd)"
derived_data="$repo_root/.build/MimiRemoteMac"
configuration="${CONFIGURATION:-Release}"
architecture="$(uname -m)"
case "$architecture" in
  arm64|x86_64) ;;
  *) echo "不支持的 Mac 架构：$architecture" >&2; exit 1 ;;
esac

for command_name in xcodegen xcodebuild; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少构建工具：$command_name" >&2
    exit 1
  fi
done

xcodegen generate --spec "$project_dir/project.yml" --project "$project_dir"
xcodebuild \
  -quiet \
  -project "$project_dir/MimiRemoteMac.xcodeproj" \
  -scheme MimiRemoteMac \
  -configuration "$configuration" \
  -destination "platform=macOS,arch=$architecture" \
  -derivedDataPath "$derived_data" \
  CODE_SIGN_STYLE=Automatic \
  build

app_path="$derived_data/Build/Products/$configuration/Mimi Remote Mac.app"
/usr/bin/codesign --verify --deep --strict "$app_path"
"$app_path/Contents/Resources/agentd" version >/dev/null

echo "本地构建完成：$app_path"
