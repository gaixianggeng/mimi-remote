#!/usr/bin/env bash
set -euo pipefail

# 构建证据读取工具链版本；不写入调用日志，避免干扰“是否发起构建”的断言。
if [[ "$*" == "-version" ]]; then
  printf '%s\nBuild version %s\n' "${IOS_TEST_XCODE_VERSION:-Xcode 99.0}" "${IOS_TEST_XCODE_BUILD:-99A1}"
  exit 0
fi

if [[ -n "${IOS_TEST_XCODEBUILD_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$IOS_TEST_XCODEBUILD_LOG"
fi
if [[ "${IOS_TEST_CREATE_APP:-0}" == "1" ]]; then
  derived_data_path=""
  destination=""
  previous_argument=""
  for argument in "$@"; do
    case "$previous_argument" in
      -derivedDataPath) derived_data_path="$argument" ;;
      -destination) destination="$argument" ;;
    esac
    previous_argument="$argument"
  done
  if [[ -n "$derived_data_path" ]]; then
    product_suffix="iphoneos"
    [[ "$destination" == *"iOS Simulator"* ]] && product_suffix="iphonesimulator"
    mkdir -p "$derived_data_path/Build/Products/Debug-${product_suffix}/MimiRemote.app"
  fi
fi
if [[ -n "${IOS_TEST_XCODEBUILD_STARTED:-}" ]]; then
  printf '%s\n' "$$" > "$IOS_TEST_XCODEBUILD_STARTED"
fi
# 模拟构建进行中源码被修改：证据必须因前后指纹不一致而不写入。
if [[ -n "${IOS_TEST_XCODEBUILD_MUTATE_FILE:-}" ]]; then
  printf '// changed during build\n' >> "$IOS_TEST_XCODEBUILD_MUTATE_FILE"
fi
if [[ "${IOS_TEST_XCODEBUILD_SLEEP_SECONDS:-0}" != "0" ]]; then
  sleep "$IOS_TEST_XCODEBUILD_SLEEP_SECONDS"
fi
exit "${IOS_TEST_XCODEBUILD_EXIT_CODE:-0}"
