#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GORELEASER_VERSION="2.15.3"
GORELEASER_BASE_URL="https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}"
TEMP_DIR=""
FINDER_PROBE_STATUS=""
FINDER_PROBE_REASON=""
FINDER_PROBE_DETAIL=""

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
  --self-test  只测试 GoReleaser 平台/校验和映射、版本解析、路径边界与安全发布逻辑，不联网。

环境变量：
  MIMI_RELEASE_TOOL_CACHE         覆盖 GoReleaser 压缩包缓存目录。
  MIMI_MACOS_SNAPSHOT_VERSION     覆盖 macOS snapshot 版本号（X.Y.Z，可带 v 前缀或预发布/构建后缀；显式设置无效值将直接报错）。
  MIMI_MACOS_SNAPSHOT_OUTPUT_DIR  覆盖 macOS snapshot 输出目录（默认 dist-macos；拒绝仓库根目录、其祖先目录以及 dist 及子目录）。
  MIMI_MACOS_SNAPSHOT_MODE        控制 macOS snapshot 形态：auto（默认，Finder 可用时走 DMG，明确无 GUI/TCC Automation 拒绝或超时时降级为 app-only）、dmg 或 app-only。

说明：
  本脚本下载并校验官方 GoReleaser v2.15.3 预编译包。不要用
  `go run ...goreleaser@v2.15.3` 代替：编译 GoReleaser 自身会自动切换到
  更高 Go 工具链，并可能让 agentd 产物偏离 go.mod 声明的版本。
USAGE
}

canonicalize_path() {
  local raw_path="${1:-}"
  if [[ -z "$raw_path" ]]; then
    return 1
  fi
  python3 - "$raw_path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

parse_macos_snapshot_version() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

resolve_macos_snapshot_version() {
  local explicit_raw="${MIMI_MACOS_SNAPSHOT_VERSION:-}"
  local parsed=""

  if [[ -n "$explicit_raw" ]]; then
    if ! parsed="$(parse_macos_snapshot_version "$explicit_raw")"; then
      echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_VERSION 无效（${explicit_raw}），必须是合法语义版本号（例如 1.2.3、v1.2.3、1.2.3-rc.1 或 v2.0.0+build.5）。" >&2
      return 2
    fi
    printf '%s\n' "$parsed"
    return 0
  fi

  local git_tag=""
  if command -v git >/dev/null 2>&1; then
    git_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  fi
  if [[ -n "$git_tag" ]] && parsed="$(parse_macos_snapshot_version "$git_tag")"; then
    printf '%s\n' "$parsed"
    return 0
  fi
  printf '%s\n' "0.0.0"
}

resolve_macos_snapshot_output_dir() {
  local requested_dir="${1:-}"
  local repo_root="${2:-$ROOT_DIR}"

  if [[ -z "$requested_dir" ]]; then
    echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR 不能为空。" >&2
    return 2
  fi

  local repo_real target_real dist_real dist_symlink_real
  repo_real="$(canonicalize_path "$repo_root")"
  target_real="$(canonicalize_path "$requested_dir")"
  dist_real="${repo_real}/dist"
  dist_symlink_real="$(canonicalize_path "$repo_root/dist")"

  if [[ -e "$target_real" && ! -d "$target_real" ]]; then
    echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR（${target_real}）已存在且不是目录。" >&2
    return 2
  fi
  if [[ "$target_real" == "/" || "$target_real" == "$repo_real" || "$repo_real" == "$target_real/"* ]]; then
    echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR（${target_real}）不得指向仓库根目录或其祖先目录。" >&2
    return 2
  fi
  if [[ "$target_real" == "$dist_real" || "$target_real" == "$dist_real/"* \
    || "$target_real" == "$dist_symlink_real" || "$target_real" == "$dist_symlink_real/"* ]]; then
    echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR（${target_real}）不得指向 GoReleaser 输出路径 dist 或其子目录。" >&2
    return 2
  fi

  printf '%s\n' "$target_real"
}

classify_finder_probe_result() {
  local session_manager="${1:-}"
  local probe_exit="${2:-0}"
  local probe_output="${3:-}"

  if [[ -n "$session_manager" && "$session_manager" != "Aqua" ]]; then
    FINDER_PROBE_STATUS="fallback"
    FINDER_PROBE_REASON="当前会话为 ${session_manager}（非 Aqua GUI 会话）"
    FINDER_PROBE_DETAIL="$probe_output"
    return 0
  fi

  if [[ "$probe_exit" -eq 0 ]]; then
    FINDER_PROBE_STATUS="ok"
    FINDER_PROBE_REASON=""
    FINDER_PROBE_DETAIL=""
    return 0
  fi

  # 仅对明确的无 GUI 会话 / TCC Automation 拒绝(-1743) / AppleEvent 超时(-1712) / 无 WindowServer(-600/-10810) 自动降级；
  # 其他未知错误保留诊断并要求调用方排查或显式设置 MIMI_MACOS_SNAPSHOT_MODE=app-only。
  if grep -Eiq '\(-1743\)|\(-1712\)|\(-600\)|\(-10810\)|Not authorized to send Apple events|errAEEventNotPermitted|errAETimeout|AppleEvent timed out|AppleEvent已超时|no user interaction is allowed|WindowServer' <<<"$probe_output"; then
    FINDER_PROBE_STATUS="fallback"
    if grep -Eiq '\(-1743\)|Not authorized|errAEEventNotPermitted' <<<"$probe_output"; then
      FINDER_PROBE_REASON="Finder Automation TCC 授权被拒绝（-1743）"
    elif grep -Eiq '\(-1712\)|timed out|已超时|errAETimeout' <<<"$probe_output"; then
      FINDER_PROBE_REASON="Finder AppleEvent 超时（-1712，后台或非交互终端通常无法响应授权弹窗）"
    else
      FINDER_PROBE_REASON="当前会话缺少可用的 Finder/WindowServer GUI 交互"
    fi
    FINDER_PROBE_DETAIL="$probe_output"
    return 0
  fi

  FINDER_PROBE_STATUS="error"
  FINDER_PROBE_REASON="Finder 探测返回未知错误（exit=${probe_exit}）"
  FINDER_PROBE_DETAIL="$probe_output"
  return 0
}

probe_finder_automation() {
  local session_manager=""
  if command -v launchctl >/dev/null 2>&1; then
    session_manager="$(launchctl managername 2>/dev/null || true)"
  fi
  if [[ -n "$session_manager" && "$session_manager" != "Aqua" ]]; then
    classify_finder_probe_result "$session_manager" 1 "launchctl managername=${session_manager}"
    return 0
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    FINDER_PROBE_STATUS="error"
    FINDER_PROBE_REASON="缺少 osascript 命令"
    FINDER_PROBE_DETAIL=""
    return 0
  fi

  local probe_output=""
  local probe_exit=0
  probe_output="$(
    osascript \
      -e 'with timeout of 5 seconds' \
      -e 'tell application "Finder" to get count of disks' \
      -e 'end timeout' 2>&1
  )" || probe_exit=$?
  classify_finder_probe_result "$session_manager" "$probe_exit" "$probe_output"
}

resolve_macos_snapshot_mode() {
  local requested="${1:-auto}"
  local probe_status="${2:-error}"
  local probe_reason="${3:-}"
  local probe_detail="${4:-}"

  case "$requested" in
    dmg|app-only)
      printf '%s\n' "$requested"
      ;;
    auto)
      case "$probe_status" in
        ok)
          printf '%s\n' "dmg"
          ;;
        fallback)
          printf '%s\n' "app-only"
          ;;
        *)
          echo "本地发布校验失败：自动探测 Finder Automation 遇到未知错误，未静默降级。" >&2
          if [[ -n "$probe_reason" ]]; then
            echo "原因：${probe_reason}" >&2
          fi
          if [[ -n "$probe_detail" ]]; then
            echo "详情：${probe_detail}" >&2
          fi
          echo "如需跳过 DMG Finder 布局校验，请显式设置 MIMI_MACOS_SNAPSHOT_MODE=app-only。" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "本地发布校验失败：MIMI_MACOS_SNAPSHOT_MODE 必须是 auto、dmg 或 app-only，实际为 ${requested}。" >&2
      return 2
      ;;
  esac
}

atomic_replace_file() {
  local src_file="$1"
  local dst_dir="$2"
  local file_name="$3"
  local staging_path="${dst_dir}/.${file_name}.staging.$$"
  local final_path="${dst_dir}/${file_name}"

  rm -f -- "$staging_path"
  cp -p "$src_file" "$staging_path"
  mv -f -- "$staging_path" "$final_path"
}

atomic_replace_app_dir() {
  local src_app="$1"
  local dst_dir="$2"
  local app_name="$3"
  local staging_path="${dst_dir}/.${app_name}.staging.$$"
  local previous_path="${dst_dir}/.${app_name}.previous.$$"
  local final_path="${dst_dir}/${app_name}"

  rm -rf -- "$staging_path" "$previous_path"
  if command -v ditto >/dev/null 2>&1; then
    ditto "$src_app" "$staging_path"
  else
    cp -Rp "$src_app" "$staging_path"
  fi

  local had_existing=0
  if [[ -e "$final_path" ]]; then
    mv -- "$final_path" "$previous_path"
    had_existing=1
  fi

  if ! mv -- "$staging_path" "$final_path"; then
    rm -rf -- "$staging_path"
    if [[ "$had_existing" == "1" && -e "$previous_path" ]]; then
      mv -- "$previous_path" "$final_path" || true
    fi
    echo "本地发布校验失败：原子替换 ${final_path} 失败。" >&2
    return 1
  fi

  if [[ "$had_existing" == "1" ]]; then
    rm -rf -- "$previous_path"
  fi
}

publish_macos_snapshot_artifacts() {
  local stage_dir="$1"
  local output_dir="$2"
  local effective_mode="$3"

  mkdir -p "$output_dir"
  if [[ "$effective_mode" == "dmg" ]]; then
    if [[ ! -f "$stage_dir/Mimi-Remote-Mac.dmg" || ! -f "$stage_dir/Mimi-Remote-Mac.dmg.sha256" ]]; then
      echo "本地发布校验失败：临时构建目录缺少 Mimi-Remote-Mac.dmg 或 Mimi-Remote-Mac.dmg.sha256。" >&2
      return 1
    fi
    atomic_replace_file "$stage_dir/Mimi-Remote-Mac.dmg" "$output_dir" "Mimi-Remote-Mac.dmg"
    atomic_replace_file "$stage_dir/Mimi-Remote-Mac.dmg.sha256" "$output_dir" "Mimi-Remote-Mac.dmg.sha256"
  else
    if [[ ! -d "$stage_dir/Mimi Remote Mac.app" ]]; then
      echo "本地发布校验失败：临时构建目录缺少 Mimi Remote Mac.app。" >&2
      return 1
    fi
    atomic_replace_app_dir "$stage_dir/Mimi Remote Mac.app" "$output_dir" "Mimi Remote Mac.app"
  fi
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
  require_command python3
  local actual

  actual="$(goreleaser_asset_for Darwin arm64)"
  [[ "$actual" == "goreleaser_Darwin_arm64.tar.gz a46a3bf44ef8255b78d9eae9a3f4da60b878011e8eba7cf12bb3787ad5110418" ]]
  actual="$(goreleaser_asset_for Darwin x86_64)"
  [[ "$actual" == "goreleaser_Darwin_x86_64.tar.gz 723ba2f0ad18ec037c9bdd79d787f8a870a66f432706b3b3962b44b3a90def91" ]]
  actual="$(goreleaser_asset_for Linux arm64)"
  [[ "$actual" == "goreleaser_Linux_arm64.tar.gz 646b8f36329cf1ec02af18d40e7096973f62524bdef19c3690414e390a9f757d" ]]
  actual="$(goreleaser_asset_for Linux x86_64)"
  [[ "$actual" == "goreleaser_Linux_x86_64.tar.gz 3b24b3a1629be21a9527d2f46f08b9bbf012c52fe33395714fe2c70acee57e0f" ]]

  # 版本解析正反例（含显式无效 MIMI_MACOS_SNAPSHOT_VERSION 必须报错，绝不静默降级 0.0.0）。
  [[ "$(parse_macos_snapshot_version "v1.1.16")" == "1.1.16" ]]
  [[ "$(parse_macos_snapshot_version "1.2.3-rc.1")" == "1.2.3" ]]
  [[ "$(parse_macos_snapshot_version "v2.0.0+build.5")" == "2.0.0" ]]
  [[ "$(parse_macos_snapshot_version "v2.0.0-beta.1+sha.abcdef")" == "2.0.0" ]]
  if parse_macos_snapshot_version "not-a-version" >/dev/null 2>&1; then
    echo "本地发布自测失败：无效版本号被接受。" >&2
    return 1
  fi
  if parse_macos_snapshot_version "1.2.3extra" >/dev/null 2>&1; then
    echo "本地发布自测失败：带非法后缀的版本号被接受。" >&2
    return 1
  fi
  [[ "$(MIMI_MACOS_SNAPSHOT_VERSION="v1.4.2-rc.1" resolve_macos_snapshot_version)" == "1.4.2" ]]
  if MIMI_MACOS_SNAPSHOT_VERSION="typo" resolve_macos_snapshot_version >/dev/null 2>&1; then
    echo "本地发布自测失败：显式无效 MIMI_MACOS_SNAPSHOT_VERSION 未被拒绝。" >&2
    return 1
  fi
  if MIMI_MACOS_SNAPSHOT_VERSION="1.2" resolve_macos_snapshot_version >/dev/null 2>&1; then
    echo "本地发布自测失败：不完整 MIMI_MACOS_SNAPSHOT_VERSION 未被拒绝。" >&2
    return 1
  fi

  # Finder 探测原因分类与模式解析正反例。
  classify_finder_probe_result "Aqua" 0 "2"
  [[ "$FINDER_PROBE_STATUS" == "ok" ]]
  [[ "$(resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "dmg" ]]

  classify_finder_probe_result "Aqua" 1 'execution error: Finder got an error: Not authorized to send Apple events to Finder. (-1743)'
  [[ "$FINDER_PROBE_STATUS" == "fallback" ]]
  [[ "$(resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]

  classify_finder_probe_result "Aqua" 1 '59:73: execution error: “Finder”遇到一个错误：AppleEvent已超时。 (-1712)'
  [[ "$FINDER_PROBE_STATUS" == "fallback" ]]
  [[ "$(resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]

  classify_finder_probe_result "Background" 1 "launchctl managername=Background"
  [[ "$FINDER_PROBE_STATUS" == "fallback" ]]
  [[ "$(resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]

  classify_finder_probe_result "Aqua" 1 "unexpected scripting runtime error (-9999)"
  [[ "$FINDER_PROBE_STATUS" == "error" ]]
  if resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL" >/dev/null 2>&1; then
    echo "本地发布自测失败：未知 Finder 错误在 auto 模式下不应静默降级。" >&2
    return 1
  fi
  [[ "$(resolve_macos_snapshot_mode app-only "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]
  [[ "$(resolve_macos_snapshot_mode dmg fallback "reason" "detail")" == "dmg" ]]
  if resolve_macos_snapshot_mode invalid ok "" "" >/dev/null 2>&1; then
    echo "本地发布自测失败：无效 MIMI_MACOS_SNAPSHOT_MODE 未被拒绝。" >&2
    return 1
  fi

  # 输出路径安全校验与保留既有文件的原子发布自测。
  local test_root
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-verify-release-selftest.XXXXXX")"
  local fake_repo="$test_root/workspace/repo"
  mkdir -p "$fake_repo/dist" "$fake_repo/dist-macos"

  # 仓库无 git tag 且未显式覆盖版本时保留 0.0.0 默认值。
  local default_ver
  default_ver="$(
    cd "$fake_repo"
    unset MIMI_MACOS_SNAPSHOT_VERSION
    PATH="/nonexistent" resolve_macos_snapshot_version
  )"
  [[ "$default_ver" == "0.0.0" ]]

  # 拒绝 dist、dist 子目录、仓库根目录、相对祖先目录以及指向 dist 的符号链接。
  ln -s "$fake_repo/dist" "$test_root/dist-link"
  local forbidden_path
  for forbidden_path in "dist" "./dist" "dist/nested" "." ".." "../.." "$fake_repo" "$test_root/workspace" "$test_root/dist-link"; do
    if (cd "$fake_repo" && resolve_macos_snapshot_output_dir "$forbidden_path" "$fake_repo" >/dev/null 2>&1); then
      rm -rf -- "$test_root"
      echo "本地发布自测失败：危险输出路径未被拒绝（${forbidden_path}）。" >&2
      return 1
    fi
  done

  local safe_out
  safe_out="$(cd "$fake_repo" && resolve_macos_snapshot_output_dir "dist-macos" "$fake_repo")"
  [[ "$safe_out" == "$(canonicalize_path "$fake_repo/dist-macos")" ]]

  # 校验原子发布：仅替换固定命名产物，保留输出目录下既有无关文件。
  local stage_dmg="$test_root/stage-dmg"
  local stage_app="$test_root/stage-app"
  local target_out="$test_root/custom-out"
  mkdir -p "$stage_dmg" "$stage_app/Mimi Remote Mac.app/Contents" "$target_out/Mimi Remote Mac.app/Contents"
  printf 'keep-existing-user-file\n' > "$target_out/keep-me.txt"
  printf 'old-dmg\n' > "$target_out/Mimi-Remote-Mac.dmg"
  printf 'old-app\n' > "$target_out/Mimi Remote Mac.app/Contents/marker.txt"
  printf 'new-dmg-v2\n' > "$stage_dmg/Mimi-Remote-Mac.dmg"
  printf 'deadbeef  Mimi-Remote-Mac.dmg\n' > "$stage_dmg/Mimi-Remote-Mac.dmg.sha256"
  printf 'new-app-v2\n' > "$stage_app/Mimi Remote Mac.app/Contents/marker.txt"

  publish_macos_snapshot_artifacts "$stage_dmg" "$target_out" "dmg"
  [[ "$(cat "$target_out/keep-me.txt")" == "keep-existing-user-file" ]]
  [[ "$(cat "$target_out/Mimi-Remote-Mac.dmg")" == "new-dmg-v2" ]]
  [[ "$(cat "$target_out/Mimi-Remote-Mac.dmg.sha256")" == "deadbeef  Mimi-Remote-Mac.dmg" ]]

  publish_macos_snapshot_artifacts "$stage_app" "$target_out" "app-only"
  [[ "$(cat "$target_out/keep-me.txt")" == "keep-existing-user-file" ]]
  [[ "$(cat "$target_out/Mimi Remote Mac.app/Contents/marker.txt")" == "new-app-v2" ]]
  [[ "$(cat "$target_out/Mimi-Remote-Mac.dmg")" == "new-dmg-v2" ]]

  rm -rf -- "$test_root"
  echo "本地发布工具平台映射、版本校验、输出目录边界与原子发布自测通过。"
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

  for command_name in awk bash cp curl go grep mktemp mkdir mv python3 rm tar uname; do
    require_command "$command_name"
  done

  local os_name
  local arch_name
  os_name="$(uname -s)"
  arch_name="$(uname -m)"

  # 在启动 GoReleaser 构建前先校验 macOS snapshot 配置，避免无效参数浪费构建时间。
  local macos_version=""
  local macos_output_dir=""
  local macos_build_number=""
  local macos_requested_mode=""
  local macos_effective_mode=""
  if [[ "$mode" == "verify" && "$os_name" == "Darwin" ]]; then
    macos_version="$(resolve_macos_snapshot_version)"
    macos_output_dir="$(resolve_macos_snapshot_output_dir "${MIMI_MACOS_SNAPSHOT_OUTPUT_DIR:-$ROOT_DIR/dist-macos}" "$ROOT_DIR")"
    macos_build_number="${GITHUB_RUN_NUMBER:-1}"
    macos_requested_mode="${MIMI_MACOS_SNAPSHOT_MODE:-auto}"
    if [[ "$macos_requested_mode" == "auto" ]]; then
      probe_finder_automation
    fi
    macos_effective_mode="$(
      resolve_macos_snapshot_mode \
        "$macos_requested_mode" \
        "$FINDER_PROBE_STATUS" \
        "$FINDER_PROBE_REASON" \
        "$FINDER_PROBE_DETAIL"
    )"
  fi

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

  local asset_name
  local expected_checksum
  local cache_dir
  local archive_path
  local goreleaser_bin

  read -r asset_name expected_checksum < <(goreleaser_asset_for "$os_name" "$arch_name")

  cache_dir="${MIMI_RELEASE_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mimi-remote/release-tools}"
  mkdir -p "$cache_dir"
  archive_path="$cache_dir/v${GORELEASER_VERSION}-${asset_name}"
  download_goreleaser_archive "$archive_path" "$asset_name" "$expected_checksum"

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-verify-release.XXXXXX")"
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
      # 在脚本私有临时目录构建并校验；通过后仅原子替换固定命名产物，绝不对目标输出目录执行 rm -rf。
      local macos_stage_dir="$TEMP_DIR/macos-snapshot-stage"
      mkdir -p "$macos_stage_dir"
      if [[ "$macos_effective_mode" == "dmg" ]]; then
        bash ./scripts/build-macos-installer.sh \
          --snapshot \
          --version "$macos_version" \
          --build-number "$macos_build_number" \
          --output-dir "$macos_stage_dir"
        bash ./scripts/check-macos-installer.sh "$macos_stage_dir/Mimi-Remote-Mac.dmg"
        publish_macos_snapshot_artifacts "$macos_stage_dir" "$macos_output_dir" "dmg"
        macos_summary=" / Mac DMG snapshot=${macos_version}"
      else
        if [[ "$macos_requested_mode" == "auto" ]]; then
          echo "提示：${FINDER_PROBE_REASON}，自动切换为 --snapshot --app-only（仍执行完整 universal 构建、签名与全部内嵌 Mach-O 校验；DMG Finder 拖放布局留待 GUI 会话或 Release CI 校验）。"
          if [[ -n "$FINDER_PROBE_DETAIL" ]]; then
            echo "Finder 探测详情：${FINDER_PROBE_DETAIL}"
          fi
        fi
        bash ./scripts/build-macos-installer.sh \
          --snapshot \
          --app-only \
          --version "$macos_version" \
          --build-number "$macos_build_number" \
          --output-dir "$macos_stage_dir"
        bash ./scripts/check-macos-installer.sh --app "$macos_stage_dir/Mimi Remote Mac.app"
        publish_macos_snapshot_artifacts "$macos_stage_dir" "$macos_output_dir" "app-only"
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
