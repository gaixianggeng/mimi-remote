#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

project_path="macos/MimiRemoteMac/MimiRemoteMac.xcodeproj"
scheme="MimiRemoteMac"
configuration="${MACOS_TEST_CONFIGURATION:-Debug}"
architecture="${MACOS_TEST_ARCH:-$(uname -m)}"
derived_data="${MACOS_DERIVED_DATA_PATH:-$ROOT_DIR/.build/MimiRemoteMacTests}"
# 传给 Xcode build phase 的可复用缓存必须位于 DerivedData 或调用方明确指定的
# 临时目录；默认值不会把 Rust/Go 的中间产物写进仓库。
embed_cache="${MACOS_EMBED_CACHE_DIR:-$derived_data/MimiRemoteMacEmbedCache}"

log() {
  printf '[macos-test %s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

case "$architecture" in
  arm64|x86_64) ;;
  *)
    echo "Mac App 测试失败：不支持架构 ${architecture}。" >&2
    exit 1
    ;;
esac

for command_name in xcodebuild go cargo rustc; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { echo "Mac App 测试失败：缺少 ${command_name}。" >&2; exit 1; }
done

# 必须通过真实 Scheme 运行测试，不只做 Swift 语法检查。这会同时
# 编译 Mac App、内嵌 agentd / Claude bridge 和现有单测，但不读取发布签名凭据。
log "开始真实 Scheme 测试：scheme=${scheme} configuration=${configuration} arch=${architecture}"
log "DerivedData=${derived_data} embed-cache=${embed_cache}"
xcodebuild \
  -project "$project_path" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "platform=macOS,arch=$architecture" \
  -derivedDataPath "$derived_data" \
  -showBuildTimingSummary \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MACOS_EMBED_CACHE_DIR="$embed_cache" \
  test

log "Mac App 编译与单测通过：scheme=${scheme} configuration=${configuration} arch=${architecture}"
