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
  DMG 和 SHA 各自原子替换，以 SHA 替换为提交边界。在发布期间读取时请核对摘要，
  如果两份文件暂时不匹配，等发布完成后重新读取。
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
  local core_num='(0|[1-9][0-9]*)'
  local pre_id='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  local build_id='[0-9A-Za-z-]+'
  local semver_re="^v?(${core_num}\.${core_num}\.${core_num})(-${pre_id}(\.${pre_id})*)?(\+${build_id}(\.${build_id})*)?$"
  if [[ "$raw" =~ $semver_re ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

resolve_macos_snapshot_version() {
  local explicit_raw="${MIMI_MACOS_SNAPSHOT_VERSION:-}"
  local parsed=""

  if [[ ${MIMI_MACOS_SNAPSHOT_VERSION+x} ]]; then
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

  python3 - "$requested_dir" "$repo_root" <<'PY'
import ctypes
import os
import sys

requested_dir, repo_root = sys.argv[1:3]
repo_real = os.path.realpath(repo_root)
target_real = os.path.realpath(requested_dir)


def stat_id(path):
    try:
        st = os.stat(path)
        return (st.st_dev, st.st_ino)
    except OSError:
        return None


def lstat_id(path):
    try:
        st = os.lstat(path)
        return (st.st_dev, st.st_ino)
    except OSError:
        return None


def is_case_insensitive_dir(dir_path):
    override = os.environ.get("MIMI_VERIFY_RELEASE_TEST_CASE_SENSITIVE")
    if override == "1":
        return False
    if override == "0":
        return True
    if sys.platform == "darwin":
        try:
            libc = ctypes.CDLL("libSystem.B.dylib", use_errno=True)
            # macOS <unistd.h> _PC_CASE_SENSITIVE = 11: 0 表示不区分大小写，1 表示区分大小写。
            val = libc.pathconf(os.fsencode(dir_path), 11)
            if val == 0:
                return True
            if val == 1:
                return False
        except Exception:
            pass

    candidates = []
    try:
        for name in os.listdir(dir_path):
            if name.lower() != name.upper():
                candidates.append((dir_path, name))
                break
    except OSError:
        pass
    base = os.path.basename(dir_path)
    parent = os.path.dirname(dir_path)
    if base and base.lower() != base.upper() and parent != dir_path:
        candidates.append((parent, base))

    for parent_dir, entry_name in candidates:
        orig = os.path.join(parent_dir, entry_name)
        swapped = os.path.join(parent_dir, entry_name.swapcase())
        orig_id = lstat_id(orig)
        swapped_id = lstat_id(swapped)
        if orig_id is not None and swapped_id is not None and orig_id == swapped_id:
            return True
        return False
    return False


if os.path.exists(target_real) and not os.path.isdir(target_real):
    print(f"本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR（{target_real}）已存在且不是目录。", file=sys.stderr)
    sys.exit(2)

# 通过文件系统身份 (st_dev, st_ino) 识别仓库根目录及其所有祖先，防止大小写别名与链接绕过。
repo_and_ancestor_ids = set()
repo_and_ancestor_paths = set()
cur = repo_real
while True:
    repo_and_ancestor_paths.add(cur)
    cid = stat_id(cur)
    if cid is not None:
        repo_and_ancestor_ids.add(cid)
    parent = os.path.dirname(cur)
    if parent == cur:
        break
    cur = parent

target_id = stat_id(target_real)
if (
    target_real == "/"
    or target_real in repo_and_ancestor_paths
    or (target_id is not None and target_id in repo_and_ancestor_ids)
):
    print(f"本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR（{target_real}）不得指向仓库根目录或其祖先目录。", file=sys.stderr)
    sys.exit(2)

# 先检查原始组件，避免 realpath 把悬空的 dist 链接或 dist/nested 改写成仓库外路径。
repo_id = stat_id(repo_real)
case_insensitive = is_case_insensitive_dir(repo_real)
dist_path = os.path.join(repo_real, "dist")
dist_real = os.path.realpath(dist_path)


def reject_dist():
    print(f"本地发布校验失败：MIMI_MACOS_SNAPSHOT_OUTPUT_DIR（{target_real}）不得指向 GoReleaser 输出路径 dist 或其子目录。", file=sys.stderr)
    sys.exit(2)


def is_dist_entry(parent, child):
    return (
        (child == "dist" or (case_insensitive and child.lower() == "dist"))
        and (os.path.realpath(parent) == repo_real or (repo_id is not None and stat_id(parent) == repo_id))
    )


raw_parent = "/" if os.path.isabs(requested_dir) else os.getcwd()
for component in requested_dir.split(os.sep):
    if is_dist_entry(raw_parent, component):
        reject_dist()
    raw_parent = os.path.join(raw_parent, component)

# 解析后的父子关系也要比较路径本身，悬空链接的目标没有可比较的 inode。
dist_ids = {fn(candidate) for candidate in (dist_path, dist_real) for fn in (stat_id, lstat_id)}
dist_ids.discard(None)
cur = target_real
while True:
    if cur == dist_real or stat_id(cur) in dist_ids:
        reject_dist()
    parent = os.path.dirname(cur)
    if parent == cur:
        break
    if is_dist_entry(parent, os.path.basename(cur)):
        reject_dist()
    cur = parent

print(target_real)
PY
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

  # 仅对明确的无 GUI 会话 / TCC Automation 拒绝(-1743) / AppleEvent 超时(-1712) / 进程不可达(-600) 自动降级；
  # 宽泛的 WindowServer 字样或 kLSUnknownErr(-10810) 等未知错误保留诊断并失败，避免掩盖真实故障。
  if grep -Eiq '\(-1743\)|\(-1712\)|\(-600\)|Not authorized to send Apple events|errAEEventNotPermitted|errAETimeout|AppleEvent timed out|AppleEvent已超时|no user interaction is allowed' <<<"$probe_output"; then
    FINDER_PROBE_STATUS="fallback"
    if grep -Eiq '\(-1743\)|Not authorized|errAEEventNotPermitted' <<<"$probe_output"; then
      FINDER_PROBE_REASON="Finder Automation TCC 授权被拒绝（-1743）"
    elif grep -Eiq '\(-1712\)|timed out|已超时|errAETimeout' <<<"$probe_output"; then
      FINDER_PROBE_REASON="Finder AppleEvent 超时（-1712，后台或非交互终端通常无法响应授权弹窗）"
    else
      FINDER_PROBE_REASON="当前会话无法与 Finder 建立 GUI 交互（-600 / 无交互会话）"
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

publish_macos_snapshot_artifacts() {
  local stage_dir="$1"
  local output_dir="$2"
  local effective_mode="$3"
  local repo_root="${4:-$ROOT_DIR}"

  # 发布前再次核验目标目录（此时 GoReleaser 可能已生成 dist），防止大小写别名或链接绕过。
  local resolved_output_dir
  resolved_output_dir="$(resolve_macos_snapshot_output_dir "$output_dir" "$repo_root")" || return
  python3 "$ROOT_DIR/scripts/macos-installer-publish.py" "$effective_mode" "$resolved_output_dir" "$stage_dir"
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

self_test() (
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

  # 版本解析正反例（严格 SemVer 2.0.0 语法，且显式无效 MIMI_MACOS_SNAPSHOT_VERSION 必须报错，绝不静默降级 0.0.0）。
  [[ "$(parse_macos_snapshot_version "0.0.0")" == "0.0.0" ]]
  [[ "$(parse_macos_snapshot_version "v1.1.16")" == "1.1.16" ]]
  [[ "$(parse_macos_snapshot_version "1.2.3-rc.1")" == "1.2.3" ]]
  [[ "$(parse_macos_snapshot_version "1.2.3-0.3.7")" == "1.2.3" ]]
  [[ "$(parse_macos_snapshot_version "1.2.3-01a")" == "1.2.3" ]]
  [[ "$(parse_macos_snapshot_version "1.2.3-x-y-z.--")" == "1.2.3" ]]
  [[ "$(parse_macos_snapshot_version "v2.0.0+001")" == "2.0.0" ]]
  [[ "$(parse_macos_snapshot_version "v2.0.0+build.5")" == "2.0.0" ]]
  [[ "$(parse_macos_snapshot_version "v2.0.0-beta.1+exp.sha.5114f85")" == "2.0.0" ]]
  local invalid_ver
  for invalid_ver in \
    "not-a-version" \
    "1.2.3extra" \
    "1.2" \
    "01.2.3" \
    "1.02.3" \
    "1.2.03" \
    "1.2.3-" \
    "1.2.3-." \
    "1.2.3-foo..bar" \
    "1.2.3-foo." \
    "1.2.3-.foo" \
    "1.2.3-01" \
    "1.2.3-rc.01" \
    "1.2.3+" \
    "1.2.3+." \
    "1.2.3+foo..bar" \
    "1.2.3+foo."; do
    if parse_macos_snapshot_version "$invalid_ver" >/dev/null 2>&1; then
      echo "本地发布自测失败：非法 SemVer 版本号被接受（${invalid_ver}）。" >&2
      return 1
    fi
  done
  [[ "$(MIMI_MACOS_SNAPSHOT_VERSION="v1.4.2-rc.1" resolve_macos_snapshot_version)" == "1.4.2" ]]
  for invalid_ver in "" "typo" "1.2" "01.2.3" "1.2.3-01" "1.2.3-." "1.2.3+."; do
    if MIMI_MACOS_SNAPSHOT_VERSION="$invalid_ver" resolve_macos_snapshot_version >/dev/null 2>&1; then
      echo "本地发布自测失败：显式无效 MIMI_MACOS_SNAPSHOT_VERSION 未被拒绝（${invalid_ver}）。" >&2
      return 1
    fi
  done

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

  classify_finder_probe_result "Aqua" 1 'execution error: Finder got an error: Application isn’t running. (-600)'
  [[ "$FINDER_PROBE_STATUS" == "fallback" ]]
  [[ "$(resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]

  classify_finder_probe_result "Background" 1 "launchctl managername=Background"
  [[ "$FINDER_PROBE_STATUS" == "fallback" ]]
  [[ "$(resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]

  # 未知错误（包括宽泛 WindowServer 字样与 kLSUnknownErr -10810）在 auto 模式下绝不自动降级。
  local unknown_err
  for unknown_err in \
    "unexpected scripting runtime error (-9999)" \
    "WindowServer unexpected state (-9999)" \
    "unexpected internal error (-10810)"; do
    classify_finder_probe_result "Aqua" 1 "$unknown_err"
    [[ "$FINDER_PROBE_STATUS" == "error" ]]
    if resolve_macos_snapshot_mode auto "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL" >/dev/null 2>&1; then
      echo "本地发布自测失败：未知 Finder 错误在 auto 模式下不应静默降级（${unknown_err}）。" >&2
      return 1
    fi
  done
  [[ "$(resolve_macos_snapshot_mode app-only "$FINDER_PROBE_STATUS" "$FINDER_PROBE_REASON" "$FINDER_PROBE_DETAIL")" == "app-only" ]]
  [[ "$(resolve_macos_snapshot_mode dmg fallback "reason" "detail")" == "dmg" ]]
  if resolve_macos_snapshot_mode invalid ok "" "" >/dev/null 2>&1; then
    echo "本地发布自测失败：无效 MIMI_MACOS_SNAPSHOT_MODE 未被拒绝。" >&2
    return 1
  fi

  # 输出路径安全校验与保留既有文件的原子发布自测。
  local test_root
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-verify-release-selftest.XXXXXX")"
  trap 'rm -rf -- "$test_root"' EXIT
  local fake_repo="$test_root/workspace/repo"
  mkdir -p "$fake_repo/dist" "$fake_repo/dist-macos"

  # 仓库无 git tag 且未显式覆盖版本时保留 0.0.0 默认值。
  local default_ver
  default_ver="$(
    cd "$fake_repo"
    unset MIMI_MACOS_SNAPSHOT_VERSION
    resolve_macos_snapshot_version
  )"
  [[ "$default_ver" == "0.0.0" ]]
  if (cd "$fake_repo" && MIMI_MACOS_SNAPSHOT_VERSION="" resolve_macos_snapshot_version >/dev/null 2>&1); then
    echo "本地发布自测失败：无 tag 时显式空版本未被拒绝。" >&2
    return 1
  fi

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

  # 大小写别名校验（不区分大小写卷：覆盖 dist 已存在与 dist 尚未生成两种场景，含仓库与祖先目录别名）。
  local fs_is_case_insensitive=0
  if [[ -d "$fake_repo/DIST" ]]; then
    fs_is_case_insensitive=1
  fi
  if [[ "$fs_is_case_insensitive" == "1" ]]; then
    for forbidden_path in \
      "DIST" \
      "DiSt" \
      "DIST/nested" \
      "$test_root/workspace/REPO" \
      "$test_root/WORKSPACE" \
      "$test_root/workspace/REPO/DIST/nested"; do
      if (cd "$fake_repo" && resolve_macos_snapshot_output_dir "$forbidden_path" "$fake_repo" >/dev/null 2>&1); then
        rm -rf -- "$test_root"
        echo "本地发布自测失败：大小写不敏感卷上的危险别名未被拒绝（${forbidden_path}）。" >&2
        return 1
      fi
    done
  fi

  # dist 尚未创建时：仍须拒绝 dist / dist/nested 以及大小写不敏感模式下的 DIST / DIST/nested 与指向 DIST 的链接；
  # 大小写敏感模式下 DIST（dist 尚不存在）应允许。
  rm -rf -- "$fake_repo/dist"
  ln -s "$fake_repo/DIST" "$test_root/upper-dist-link"
  for forbidden_path in "dist" "dist/nested" "DIST" "DIST/nested" "$test_root/upper-dist-link"; do
    if (cd "$fake_repo" && MIMI_VERIFY_RELEASE_TEST_CASE_SENSITIVE=0 resolve_macos_snapshot_output_dir "$forbidden_path" "$fake_repo" >/dev/null 2>&1); then
      rm -rf -- "$test_root"
      echo "本地发布自测失败：dist 尚未生成时危险路径未被拒绝（${forbidden_path}）。" >&2
      return 1
    fi
  done
  if [[ "$fs_is_case_insensitive" == "1" ]]; then
    for forbidden_path in "DIST" "DIST/nested" "$test_root/upper-dist-link"; do
      if (cd "$fake_repo" && resolve_macos_snapshot_output_dir "$forbidden_path" "$fake_repo" >/dev/null 2>&1); then
        rm -rf -- "$test_root"
        echo "本地发布自测失败：本机不区分大小写卷在 dist 尚未生成时未拒绝（${forbidden_path}）。" >&2
        return 1
      fi
    done
  fi
  if ! (cd "$fake_repo" && MIMI_VERIFY_RELEASE_TEST_CASE_SENSITIVE=1 resolve_macos_snapshot_output_dir "DIST" "$fake_repo" >/dev/null 2>&1); then
    rm -rf -- "$test_root"
    echo "本地发布自测失败：大小写敏感卷上独立目录 DIST 不应被误拒。" >&2
    return 1
  fi
  ln -s "$test_root/not-created" "$fake_repo/dist"
  ln -s "$test_root/not-created" "$test_root/dangling-dist-alias"
  for forbidden_path in "dist" "dist/nested" "$test_root/dangling-dist-alias/nested"; do
    if (cd "$fake_repo" && resolve_macos_snapshot_output_dir "$forbidden_path" "$fake_repo" >/dev/null 2>&1); then
      rm -rf -- "$test_root"
      echo "本地发布自测失败：悬空 dist 链接的危险路径未被拒绝（${forbidden_path}）。" >&2
      return 1
    fi
  done
  [[ ! -e "$test_root/not-created" ]]
  rm -- "$fake_repo/dist"
  mkdir -p "$fake_repo/dist"

  local safe_out
  safe_out="$(cd "$fake_repo" && resolve_macos_snapshot_output_dir "dist-macos" "$fake_repo")"
  [[ "$safe_out" == "$(canonicalize_path "$fake_repo/dist-macos")" ]]

  # 校验原子发布：仅替换固定命名产物，保留输出目录下既有无关文件。
  local stage_dmg="$test_root/stage-dmg"
  local stage_app="$test_root/stage-app"
  local target_out="$test_root/custom-out"
  mkdir -p "$stage_dmg" "$stage_app/Mimi Remote Mac.app/Contents" "$target_out/Mimi Remote Mac.app/Contents"
  touch "$stage_app/Mimi Remote Mac.app/Contents/Info.plist" "$target_out/Mimi Remote Mac.app/Contents/Info.plist"
  printf 'keep-existing-user-file\n' > "$target_out/keep-me.txt"
  printf 'old-dmg\n' > "$target_out/Mimi-Remote-Mac.dmg"
  printf 'old-sha  Mimi-Remote-Mac.dmg\n' > "$target_out/Mimi-Remote-Mac.dmg.sha256"
  printf 'old-app\n' > "$target_out/Mimi Remote Mac.app/Contents/marker.txt"
  printf 'new-dmg-v2\n' > "$stage_dmg/Mimi-Remote-Mac.dmg"
  printf 'deadbeef  Mimi-Remote-Mac.dmg\n' > "$stage_dmg/Mimi-Remote-Mac.dmg.sha256"
  printf 'new-app-v2\n' > "$stage_app/Mimi Remote Mac.app/Contents/marker.txt"

  # 只在自测进程里拦截系统调用，并执行与公开入口相同的发布器。
  python3 - "$ROOT_DIR/scripts/macos-installer-publish.py" "$test_root" "$stage_dmg" "$stage_app" "$target_out" <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import sys

publisher = sys.argv[1]
root, stage_dmg, stage_app, output = map(Path, sys.argv[2:])
dmg = output / "Mimi-Remote-Mac.dmg"
sha = output / "Mimi-Remote-Mac.dmg.sha256"
journal = output / ".Mimi-Remote-Mac.dmg.transaction"
app = output / "Mimi Remote Mac.app"

injected_publisher = r"""
import fcntl
import os
from pathlib import Path
import runpy
import shutil
import signal
import sys

step = sys.argv.pop(1)
sys.argv.pop(0)
main = runpy.run_path(sys.argv[0])["main"]
replace = os.replace
rmtree = shutil.rmtree
flock = fcntl.flock


def replace_with_fault(src, dst):
    if step == "sha_replace" and Path(src).name == "new.sha256":
        raise OSError("injected sha_replace failure")
    replace(src, dst)
    if Path(src).name == "new.dmg" and step in ("SIGINT", "SIGTERM", "SIGKILL"):
        os.kill(os.getpid(), getattr(signal, step))
    if Path(src).name == "new.sha256" and step == "SIGKILL_after_sha":
        os.kill(os.getpid(), signal.SIGKILL)


def fail_swap(src, dst):
    raise OSError("injected failure before atomic app swap")


def fail_old_app_cleanup(path, *args, **kwargs):
    if Path(path).name.startswith(".Mimi-Remote-Mac.app.staging."):
        raise PermissionError("injected old App cleanup failure")
    rmtree(path, *args, **kwargs)


def controlled_lock(fd, flags):
    if step == "probe_lock":
        try:
            flock(fd, flags | fcntl.LOCK_NB)
        except BlockingIOError:
            print("blocked", flush=True)
        else:
            raise AssertionError("second publisher obtained a held directory lock")
    flock(fd, flags)
    if step == "hold_lock":
        print("locked", flush=True)
        sys.stdin.read(1)


os.replace = replace_with_fault
if step == "before_app_swap":
    main.__globals__["swap_dirs"] = fail_swap
if step == "signal_after_app_swap":
    swap = main.__globals__["swap_dirs"]

    def interrupt_after_swap(src, dst):
        swap(src, dst)
        os.kill(os.getpid(), signal.SIGINT)

    main.__globals__["swap_dirs"] = interrupt_after_swap
if step == "after_app_swap":
    shutil.rmtree = fail_old_app_cleanup
if step in ("hold_lock", "probe_lock"):
    fcntl.flock = controlled_lock
sys.exit(main())
"""


def command(step, mode, target, source):
    return [sys.executable, "-c", injected_publisher, step, publisher, mode, target, source]


def run(step, mode, target, source, status):
    result = subprocess.run(command(step, mode, target, source), capture_output=True, text=True, timeout=15)
    assert result.returncode == status, result
    return result


def assert_old_pair():
    assert dmg.read_text() == "old-dmg\n"
    assert sha.read_text() == "old-sha  Mimi-Remote-Mac.dmg\n"
    assert (output / "keep-me.txt").read_text() == "keep-existing-user-file\n"
    assert not journal.exists()


for fault, status in (("sha_replace", 1), ("SIGINT", 130), ("SIGTERM", 143)):
    run(fault, "dmg", output, stage_dmg, status)
    assert_old_pair()
    fresh_out = root / ("fresh-out-" + fault)
    run(fault, "dmg", fresh_out, stage_dmg, status)
    assert not list(fresh_out.iterdir())

# SIGKILL 无法捕获，下一次发布必须先恢复旧 DMG，随后允许重新提交。
run("SIGKILL", "dmg", output, stage_dmg, -signal.SIGKILL)
assert (journal / "old.dmg").read_text() == "old-dmg\n"
assert dmg.read_text() == "new-dmg-v2\n"
run("sha_replace", "dmg", output, stage_dmg, 1)
assert_old_pair()

journal.mkdir(mode=0o700)
(journal / "new.dmg").write_text("unrelated user file")
run("none", "dmg", output, stage_dmg, 1)
assert (journal / "new.dmg").read_text() == "unrelated user file"
(journal / "new.dmg").unlink()
journal.rmdir()
assert_old_pair()

# SHA 已提交以后再被强制终止，下一次只清理事务，保留新的一对产物。
run("SIGKILL_after_sha", "dmg", output, stage_dmg, -signal.SIGKILL)
run("sha_replace", "dmg", output, stage_dmg, 1)
assert dmg.read_text() == "new-dmg-v2\n"
assert sha.read_text() == "deadbeef  Mimi-Remote-Mac.dmg\n"
assert not journal.exists()

run("before_app_swap", "app-only", output, stage_app, 1)
assert (app / "Contents/marker.txt").read_text() == "old-app\n"
assert not list(output.glob(".Mimi-Remote-Mac.app.staging.*"))

result = run("after_app_swap", "app-only", output, stage_app, 0)
assert (app / "Contents/marker.txt").read_text() == "new-app-v2\n"
[legacy_app] = output.glob(".Mimi-Remote-Mac.app.staging.*")
assert (legacy_app / "Contents/marker.txt").read_text() == "old-app\n"
assert "新 App 已提交" in result.stderr and str(legacy_app) in result.stderr

result = run("signal_after_app_swap", "app-only", output, stage_app, 0)
assert (app / "Contents/marker.txt").read_text() == "new-app-v2\n"
assert "新 App 已提交" in result.stderr and "遗留路径" in result.stderr


def expect_line(child, line):
    readable, _, _ = select.select([child.stdout], [], [], 10)
    assert readable and child.stdout.readline().strip() == line, f"等待发布锁状态超时或错误：{line}"


# 两个发布者使用不同的有效 TMPDIR 和同一物理目录的不同路径。
tmp_a, tmp_b = root / "tmp-a", root / "tmp-b"
tmp_a.mkdir()
tmp_b.mkdir()
alias = root / "output-alias"
alias.symlink_to(output, target_is_directory=True)
children = []
try:
    for step, path, tmpdir, expected in (
        ("hold_lock", output, tmp_a, "locked"),
        ("probe_lock", alias, tmp_b, "blocked"),
    ):
        child = subprocess.Popen(
            command(step, "app-only", path, stage_app),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            env={**os.environ, "TMPDIR": str(tmpdir)},
        )
        children.append(child)
        expect_line(child, expected)
    assert children[1].poll() is None
    for child in children:
        assert child.communicate(timeout=10)[0] == ""
        assert child.returncode == 0
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
PY

  # 正常发布 DMG 与 App。
  publish_macos_snapshot_artifacts "$stage_dmg" "$target_out" "dmg" "$fake_repo"
  [[ "$(cat "$target_out/keep-me.txt")" == "keep-existing-user-file" ]]
  [[ "$(cat "$target_out/Mimi-Remote-Mac.dmg")" == "new-dmg-v2" ]]
  [[ "$(cat "$target_out/Mimi-Remote-Mac.dmg.sha256")" == "deadbeef  Mimi-Remote-Mac.dmg" ]]

  publish_macos_snapshot_artifacts "$stage_app" "$target_out" "app-only" "$fake_repo"
  [[ "$(cat "$target_out/keep-me.txt")" == "keep-existing-user-file" ]]
  [[ "$(cat "$target_out/Mimi Remote Mac.app/Contents/marker.txt")" == "new-app-v2" ]]
  [[ "$(cat "$target_out/Mimi-Remote-Mac.dmg")" == "new-dmg-v2" ]]

  # P2-3：同输出目录并发发布 App，必须通过互斥锁串行化，绝不能嵌套成 .app/.app。
  local stage_app_b="$test_root/stage-app-b"
  mkdir -p "$stage_app_b/Mimi Remote Mac.app/Contents"
  touch "$stage_app_b/Mimi Remote Mac.app/Contents/Info.plist"
  printf 'new-app-v3\n' > "$stage_app_b/Mimi Remote Mac.app/Contents/marker.txt"
  publish_macos_snapshot_artifacts "$stage_app" "$target_out" "app-only" "$fake_repo" &
  local pid_a=$!
  publish_macos_snapshot_artifacts "$stage_app_b" "$target_out" "app-only" "$fake_repo" &
  local pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  if [[ -e "$target_out/Mimi Remote Mac.app/Mimi Remote Mac.app" ]]; then
    rm -rf -- "$test_root"
    echo "本地发布自测失败：并发发布导致 .app 嵌套。" >&2
    return 1
  fi
  local final_marker
  final_marker="$(cat "$target_out/Mimi Remote Mac.app/Contents/marker.txt")"
  [[ "$final_marker" == "new-app-v2" || "$final_marker" == "new-app-v3" ]]

  # P2-2：固定产物名被目录或指向外部目录的符号链接占用时必须立即失败，外部目录与既有产物保持不变。
  local ext_dir="$test_root/external-dir"
  mkdir -p "$ext_dir"
  printf 'untouched\n' > "$ext_dir/sentinel.txt"

  local conflict_dir
  for conflict_kind in dmg-dir dmg-link sha-dir sha-link app-link; do
    conflict_dir="$test_root/conflict-${conflict_kind}"
    mkdir -p "$conflict_dir"
    printf 'existing-dmg\n' > "$conflict_dir/Mimi-Remote-Mac.dmg"
    printf 'existing-sha\n' > "$conflict_dir/Mimi-Remote-Mac.dmg.sha256"
    case "$conflict_kind" in
      dmg-dir)
        rm -f "$conflict_dir/Mimi-Remote-Mac.dmg"
        mkdir -p "$conflict_dir/Mimi-Remote-Mac.dmg"
        if publish_macos_snapshot_artifacts "$stage_dmg" "$conflict_dir" "dmg" "$fake_repo" >/dev/null 2>&1; then
          rm -rf -- "$test_root"
          echo "本地发布自测失败：Mimi-Remote-Mac.dmg 被目录占用时未被拒绝。" >&2
          return 1
        fi
        [[ -z "$(ls -A "$conflict_dir/Mimi-Remote-Mac.dmg")" ]]
        [[ "$(cat "$conflict_dir/Mimi-Remote-Mac.dmg.sha256")" == "existing-sha" ]]
        ;;
      dmg-link)
        rm -f "$conflict_dir/Mimi-Remote-Mac.dmg"
        ln -s "$ext_dir" "$conflict_dir/Mimi-Remote-Mac.dmg"
        if publish_macos_snapshot_artifacts "$stage_dmg" "$conflict_dir" "dmg" "$fake_repo" >/dev/null 2>&1; then
          rm -rf -- "$test_root"
          echo "本地发布自测失败：Mimi-Remote-Mac.dmg 被外部目录符号链接占用时未被拒绝。" >&2
          return 1
        fi
        [[ "$(ls -A "$ext_dir")" == "sentinel.txt" ]]
        [[ "$(cat "$conflict_dir/Mimi-Remote-Mac.dmg.sha256")" == "existing-sha" ]]
        ;;
      sha-dir)
        rm -f "$conflict_dir/Mimi-Remote-Mac.dmg.sha256"
        mkdir -p "$conflict_dir/Mimi-Remote-Mac.dmg.sha256"
        if publish_macos_snapshot_artifacts "$stage_dmg" "$conflict_dir" "dmg" "$fake_repo" >/dev/null 2>&1; then
          rm -rf -- "$test_root"
          echo "本地发布自测失败：Mimi-Remote-Mac.dmg.sha256 被目录占用时未被拒绝。" >&2
          return 1
        fi
        [[ -z "$(ls -A "$conflict_dir/Mimi-Remote-Mac.dmg.sha256")" ]]
        [[ "$(cat "$conflict_dir/Mimi-Remote-Mac.dmg")" == "existing-dmg" ]]
        ;;
      sha-link)
        rm -f "$conflict_dir/Mimi-Remote-Mac.dmg.sha256"
        ln -s "$ext_dir" "$conflict_dir/Mimi-Remote-Mac.dmg.sha256"
        if publish_macos_snapshot_artifacts "$stage_dmg" "$conflict_dir" "dmg" "$fake_repo" >/dev/null 2>&1; then
          rm -rf -- "$test_root"
          echo "本地发布自测失败：Mimi-Remote-Mac.dmg.sha256 被外部目录符号链接占用时未被拒绝。" >&2
          return 1
        fi
        [[ "$(ls -A "$ext_dir")" == "sentinel.txt" ]]
        [[ "$(cat "$conflict_dir/Mimi-Remote-Mac.dmg")" == "existing-dmg" ]]
        ;;
      app-link)
        ln -s "$ext_dir" "$conflict_dir/Mimi Remote Mac.app"
        if publish_macos_snapshot_artifacts "$stage_app" "$conflict_dir" "app-only" "$fake_repo" >/dev/null 2>&1; then
          rm -rf -- "$test_root"
          echo "本地发布自测失败：Mimi Remote Mac.app 被符号链接占用时未被拒绝。" >&2
          return 1
        fi
        [[ "$(ls -A "$ext_dir")" == "sentinel.txt" ]]
        ;;
    esac
  done

  echo "本地发布工具平台映射、版本校验、输出目录边界与原子发布自测通过。"
)

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
    macos_output_dir="${MIMI_MACOS_SNAPSHOT_OUTPUT_DIR:-$ROOT_DIR/dist-macos}"
    resolve_macos_snapshot_output_dir "$macos_output_dir" "$ROOT_DIR" >/dev/null
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
