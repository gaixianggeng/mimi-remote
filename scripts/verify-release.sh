#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GORELEASER_VERSION="2.15.3"
GORELEASER_BASE_URL="https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}"

usage() {
  cat <<'USAGE'
用法：
  bash ./scripts/verify-release.sh [verify|check|--self-test]

命令：
  verify       默认。校验 packaging，生成四平台 snapshot，并检查归档和 Formula。
  check        只校验 packaging 和 GoReleaser 配置，不生成 dist。
  --self-test  只测试 GoReleaser 平台/校验和映射，不联网。

环境变量：
  MIMI_RELEASE_TOOL_CACHE  覆盖 GoReleaser 压缩包缓存目录。

说明：
  本脚本下载并校验官方 GoReleaser v2.15.3 预编译包。不要用
  `go run ...goreleaser@v2.15.3` 代替：编译 GoReleaser 自身会自动切换到
  更高 Go 工具链，并可能让 agentd 产物偏离 go.mod 声明的版本。
USAGE
}

goreleaser_asset_for() {
  local os_name="$1"
  local arch_name="$2"

  case "$os_name:$arch_name" in
    Darwin:arm64|Darwin:aarch64)
      printf '%s %s\n' \
        "goreleaser_Darwin_arm64.tar.gz" \
        "a46a3bf44ef8255b78d9eae9a3f4da60b878011e8eba7cf12bb3787ad5110418"
      ;;
    Darwin:x86_64|Darwin:amd64)
      printf '%s %s\n' \
        "goreleaser_Darwin_x86_64.tar.gz" \
        "723ba2f0ad18ec037c9bdd79d787f8a870a66f432706b3b3962b44b3a90def91"
      ;;
    Linux:arm64|Linux:aarch64)
      printf '%s %s\n' \
        "goreleaser_Linux_arm64.tar.gz" \
        "646b8f36329cf1ec02af18d40e7096973f62524bdef19c3690414e390a9f757d"
      ;;
    Linux:x86_64|Linux:amd64)
      printf '%s %s\n' \
        "goreleaser_Linux_x86_64.tar.gz" \
        "3b24b3a1629be21a9527d2f46f08b9bbf012c52fe33395714fe2c70acee57e0f"
      ;;
    *)
      echo "本地发布校验不支持当前平台：$os_name/$arch_name。" >&2
      return 1
      ;;
  esac
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi
  echo "本地发布校验失败：缺少 sha256sum 或 shasum。" >&2
  return 127
}

self_test() {
  local actual

  actual="$(goreleaser_asset_for Darwin arm64)"
  [[ "$actual" == "goreleaser_Darwin_arm64.tar.gz a46a3bf44ef8255b78d9eae9a3f4da60b878011e8eba7cf12bb3787ad5110418" ]]
  actual="$(goreleaser_asset_for Darwin x86_64)"
  [[ "$actual" == "goreleaser_Darwin_x86_64.tar.gz 723ba2f0ad18ec037c9bdd79d787f8a870a66f432706b3b3962b44b3a90def91" ]]
  actual="$(goreleaser_asset_for Linux arm64)"
  [[ "$actual" == "goreleaser_Linux_arm64.tar.gz 646b8f36329cf1ec02af18d40e7096973f62524bdef19c3690414e390a9f757d" ]]
  actual="$(goreleaser_asset_for Linux x86_64)"
  [[ "$actual" == "goreleaser_Linux_x86_64.tar.gz 3b24b3a1629be21a9527d2f46f08b9bbf012c52fe33395714fe2c70acee57e0f" ]]
  echo "本地发布工具平台映射自测通过。"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "本地发布校验失败：缺少命令 $1。" >&2
    exit 127
  fi
}

download_goreleaser_archive() {
  local archive_path="$1"
  local asset_name="$2"
  local expected_checksum="$3"
  local actual_checksum=""
  local partial_path="${archive_path}.partial.$$"

  if [[ -f "$archive_path" ]]; then
    actual_checksum="$(sha256_file "$archive_path")"
    if [[ "$actual_checksum" == "$expected_checksum" ]]; then
      return
    fi
    echo "缓存的 $asset_name 校验和不匹配，正在重新下载。" >&2
    rm -f "$archive_path"
  fi

  rm -f "$partial_path"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "$GORELEASER_BASE_URL/$asset_name" \
    --output "$partial_path"
  actual_checksum="$(sha256_file "$partial_path")"
  if [[ "$actual_checksum" != "$expected_checksum" ]]; then
    rm -f "$partial_path"
    echo "本地发布校验失败：$asset_name 校验和不匹配。" >&2
    exit 1
  fi
  mv "$partial_path" "$archive_path"
}

main() {
  local mode="${1:-verify}"
  if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
  fi
  case "$mode" in
    verify|check)
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
      exit 2
      ;;
  esac

  for command_name in awk bash curl go grep mktemp mkdir mv rm tar uname; do
    require_command "$command_name"
  done

  local expected_go_version
  local actual_go_version
  expected_go_version="go$(awk '$1 == "go" { print $2; exit }' go.mod)"
  actual_go_version="$(GOTOOLCHAIN=local go env GOVERSION)"
  if [[ "$actual_go_version" != "$expected_go_version" ]]; then
    echo "本地发布校验失败：当前 Go 为 $actual_go_version，go.mod 要求 $expected_go_version。" >&2
    echo "请先切换到 $expected_go_version；本脚本不会自动下载或切换构建工具链。" >&2
    exit 1
  fi

  bash ./scripts/check-packaging.sh

  local os_name
  local arch_name
  local asset_name
  local expected_checksum
  local cache_dir
  local archive_path
  local temp_dir
  local goreleaser_bin

  os_name="$(uname -s)"
  arch_name="$(uname -m)"
  read -r asset_name expected_checksum < <(goreleaser_asset_for "$os_name" "$arch_name")

  cache_dir="${MIMI_RELEASE_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mimi-remote/release-tools}"
  mkdir -p "$cache_dir"
  archive_path="$cache_dir/v${GORELEASER_VERSION}-${asset_name}"
  download_goreleaser_archive "$archive_path" "$asset_name" "$expected_checksum"

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  tar -xzf "$archive_path" -C "$temp_dir" goreleaser
  goreleaser_bin="$temp_dir/goreleaser"
  if [[ ! -x "$goreleaser_bin" ]]; then
    echo "本地发布校验失败：GoReleaser 压缩包中缺少可执行文件。" >&2
    exit 1
  fi
  if ! "$goreleaser_bin" --version | grep -Fq "GitVersion:    ${GORELEASER_VERSION}"; then
    echo "本地发布校验失败：GoReleaser 版本不是 ${GORELEASER_VERSION}。" >&2
    exit 1
  fi

  export GOTOOLCHAIN=local
  "$goreleaser_bin" check
  if [[ "$mode" == "verify" ]]; then
    "$goreleaser_bin" release --snapshot --clean --skip=publish
    bash ./scripts/check-release-artifacts.sh
  fi

  rm -rf "$temp_dir"
  trap - EXIT
  echo "本地发布校验完成：Go ${expected_go_version} / GoReleaser v${GORELEASER_VERSION} / mode=${mode}。"
}

main "$@"
