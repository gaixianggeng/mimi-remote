#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GORELEASER_VERSION="2.15.3"
GORELEASER_BASE_URL="https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}"
TEMP_DIR=""

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

usage() {
  cat <<'USAGE'
用法：
  bash ./scripts/verify-release.sh [verify|check|--self-test]

命令：
  verify       默认。校验 packaging，生成四平台 snapshot，检查归档和 Formula；
               在 macOS 上同时构建 Mac installer snapshot 并校验内嵌二进制签名。
  check        只校验 packaging 和 GoReleaser 配置，不生成 dist。
  --self-test  只测试 GoReleaser 平台/校验和映射及版本解析，不联网。

环境变量：
  MIMI_RELEASE_TOOL_CACHE         覆盖 GoReleaser 压缩包缓存目录。
  MIMI_MACOS_SNAPSHOT_VERSION     覆盖 macOS snapshot 版本号（X.Y.Z）。
  MIMI_MACOS_SNAPSHOT_OUTPUT_DIR  覆盖 macOS snapshot 输出目录（默认 dist-macos）。
  MIMI_MACOS_SNAPSHOT_MODE        控制 macOS snapshot 形态：auto（默认，Finder 可用时走 DMG，无 Finder Automation 权限时降级为 app-only）、dmg 或 app-only。

说明：
  本脚本下载并校验官方 GoReleaser v2.15.3 预编译包。不要用
  `go run ...goreleaser@v2.15.3` 代替：编译 GoReleaser 自身会自动切换到
  更高 Go 工具链，并可能让 agentd 产物偏离 go.mod 声明的版本。
USAGE
}

normalize_macos_snapshot_version() {
  local raw="${1:-}"
  raw="${raw#v}"
  raw="${raw%%-*}"
  raw="${raw%%+*}"
  if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$raw"
    return
  fi
  printf '%s\n' "0.0.0"
}

resolve_macos_snapshot_version() {
  local raw="${MIMI_MACOS_SNAPSHOT_VERSION:-}"
  if [[ -z "$raw" ]] && command -v git >/dev/null 2>&1; then
    raw="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  fi
  normalize_macos_snapshot_version "$raw"
}

resolve_macos_snapshot_mode() {
  local requested="${1:-auto}"
  local finder_available="${2:-0}"
  case "$requested" in
    dmg|app-only)
      printf '%s\n' "$requested"
      ;;
    auto)
      if [[ "$finder_available" == "1" ]]; then
        printf '%s\n' "dmg"
      else
        printf '%s\n' "app-only"
      fi
      ;;
    *)
      echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_MODE 必须是 auto、dmg 或 app-only，实际为 ${requested}。" >&2
      return 2
      ;;
  esac
}

finder_automation_available() {
  command -v osascript >/dev/null 2>&1 || return 1
  osascript \
    -e 'with timeout of 5 seconds' \
    -e 'tell application "Finder" to get count of disks' \
    -e 'end timeout' >/dev/null 2>&1
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
      echo "本地发布校验不支持当前平台：$os_name/${arch_name}。" >&2
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
  [[ "$(normalize_macos_snapshot_version "v1.1.16")" == "1.1.16" ]]
  [[ "$(normalize_macos_snapshot_version "1.2.3-rc.1")" == "1.2.3" ]]
  [[ "$(normalize_macos_snapshot_version "v2.0.0+build.5")" == "2.0.0" ]]
  [[ "$(normalize_macos_snapshot_version "")" == "0.0.0" ]]
  [[ "$(normalize_macos_snapshot_version "not-a-version")" == "0.0.0" ]]
  [[ "$(resolve_macos_snapshot_mode auto 1)" == "dmg" ]]
  [[ "$(resolve_macos_snapshot_mode auto 0)" == "app-only" ]]
  [[ "$(resolve_macos_snapshot_mode dmg 0)" == "dmg" ]]
  [[ "$(resolve_macos_snapshot_mode app-only 1)" == "app-only" ]]
  if resolve_macos_snapshot_mode invalid 1 >/dev/null 2>&1; then
    echo "本地发布自测失败：无效 MIMI_MACOS_SNAPSHOT_MODE 未被拒绝。" >&2
    return 1
  fi
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
    echo "本地发布校验失败：当前 Go 为 ${actual_go_version}，go.mod 要求 ${expected_go_version}。" >&2
    echo "请先切换到 ${expected_go_version}；本脚本不会自动下载或切换构建工具链。" >&2
    exit 1
  fi

  bash ./scripts/check-packaging.sh

  local os_name
  local arch_name
  local asset_name
  local expected_checksum
  local cache_dir
  local archive_path
  local goreleaser_bin

  os_name="$(uname -s)"
  arch_name="$(uname -m)"
  read -r asset_name expected_checksum < <(goreleaser_asset_for "$os_name" "$arch_name")

  cache_dir="${MIMI_RELEASE_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mimi-remote/release-tools}"
  mkdir -p "$cache_dir"
  archive_path="$cache_dir/v${GORELEASER_VERSION}-${asset_name}"
  download_goreleaser_archive "$archive_path" "$asset_name" "$expected_checksum"

  TEMP_DIR="$(mktemp -d)"
  trap cleanup EXIT
  tar -xzf "$archive_path" -C "$TEMP_DIR" goreleaser
  goreleaser_bin="$TEMP_DIR/goreleaser"
  if [[ ! -x "$goreleaser_bin" ]]; then
    echo "本地发布校验失败：GoReleaser 压缩包中缺少可执行文件。" >&2
    exit 1
  fi
  if ! "$goreleaser_bin" --version | grep -Fq "GitVersion:    ${GORELEASER_VERSION}"; then
    echo "本地发布校验失败：GoReleaser 版本不是 ${GORELEASER_VERSION}。" >&2
    exit 1
  fi

  export GOTOOLCHAIN=local
  # snapshot 不会连接 Tap，但 GoReleaser 在生成 Formula 前仍会渲染 repository 模板。
  export TAP_DEPLOY_KEY="${TAP_DEPLOY_KEY:-snapshot-only-not-used}"
  "$goreleaser_bin" check
  local macos_summary=""
  if [[ "$mode" == "verify" ]]; then
    "$goreleaser_bin" release --snapshot --clean --skip=publish
    bash ./scripts/check-release-artifacts.sh
    if [[ "$os_name" == "Darwin" ]]; then
      local macos_version
      local macos_output_dir
      local macos_build_number
      local macos_requested_mode
      local finder_ok="0"
      local macos_effective_mode
      macos_version="$(resolve_macos_snapshot_version)"
      macos_output_dir="${MIMI_MACOS_SNAPSHOT_OUTPUT_DIR:-$ROOT_DIR/dist-macos}"
      macos_build_number="${GITHUB_RUN_NUMBER:-1}"
      macos_requested_mode="${MIMI_MACOS_SNAPSHOT_MODE:-auto}"
      if [[ "$macos_requested_mode" == "auto" ]] && finder_automation_available; then
        finder_ok="1"
      fi
      macos_effective_mode="$(resolve_macos_snapshot_mode "$macos_requested_mode" "$finder_ok")"
      # 使用独立目录（默认 dist-macos），避免覆盖或污染 GoReleaser 生成的 dist/。
      rm -rf -- "$macos_output_dir"
      mkdir -p "$macos_output_dir"
      if [[ "$macos_effective_mode" == "dmg" ]]; then
        bash ./scripts/build-macos-installer.sh \
          --snapshot \
          --version "$macos_version" \
          --build-number "$macos_build_number" \
          --output-dir "$macos_output_dir"
        bash ./scripts/check-macos-installer.sh "$macos_output_dir/Mimi-Remote-Mac.dmg"
        macos_summary=" / Mac DMG snapshot=${macos_version}"
      else
        if [[ "$macos_requested_mode" == "auto" ]]; then
          echo "提示：当前终端会话无法与 Finder AppleEvent 交互，自动切换为 --snapshot --app-only（仍执行完整 universal 构建、签名与全部内嵌 Mach-O 校验；DMG Finder 拖放布局留待 GUI 会话或 Release CI 校验）。"
        fi
        bash ./scripts/build-macos-installer.sh \
          --snapshot \
          --app-only \
          --version "$macos_version" \
          --build-number "$macos_build_number" \
          --output-dir "$macos_output_dir"
        bash ./scripts/check-macos-installer.sh --app "$macos_output_dir/Mimi Remote Mac.app"
        macos_summary=" / Mac App snapshot=${macos_version} (app-only)"
      fi
    fi
  fi

  cleanup
  TEMP_DIR=""
  trap - EXIT
  echo "本地发布校验完成：Go ${expected_go_version} / GoReleaser v${GORELEASER_VERSION} / mode=${mode}${macos_summary}。"
}

main "$@"
