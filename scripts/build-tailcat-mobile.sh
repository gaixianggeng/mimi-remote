#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="$REPO_ROOT/experiments/tailcat"
TOOL_DIR="$REPO_ROOT/.build/tailcat-mobile-tools"
OUTPUT_DIR="$REPO_ROOT/ios/MimiRemote/Generated"
OUTPUT="$OUTPUT_DIR/TailcatMobile.xcframework"
GOMOBILE_VERSION="v0.0.0-20260821190718-4776eadac327"
TEMPORARY_DIR=""

cleanup() {
  [[ -z "$TEMPORARY_DIR" ]] || rm -rf "$TEMPORARY_DIR"
}
trap cleanup EXIT

mkdir -p "$TOOL_DIR/bin" "$OUTPUT_DIR"
GOBIN="$TOOL_DIR/bin" go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
"$TOOL_DIR/bin/gomobile" init

TEMPORARY_DIR="$(mktemp -d "$OUTPUT_DIR/.tailcat-mobile.XXXXXX")"
TEMPORARY_OUTPUT="$TEMPORARY_DIR/TailcatMobile.xcframework"
cd "$MODULE_DIR"
"$TOOL_DIR/bin/gomobile" bind \
  -target=ios,iossimulator \
  -o "$TEMPORARY_OUTPUT" \
  ./mobile/tailcatmobile

rm -rf "$OUTPUT"
mv "$TEMPORARY_OUTPUT" "$OUTPUT"
# `__has_include` 不会始终跟踪之前不存在的头文件；更新时间戳以触发下一次增量编译。
touch "$REPO_ROOT/ios/MimiRemote/Sources/Core/Tailcat/MimiTailcatBridge.m"
echo "Tailcat iOS 框架已生成：$OUTPUT"
