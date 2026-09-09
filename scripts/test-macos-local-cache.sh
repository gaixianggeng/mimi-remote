#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-local-cache.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
fixture="$TEMP_DIR/repo"
mkdir -p \
  "$fixture/scripts" \
  "$fixture/experiments/tailcat" \
  "$fixture/macos/MimiRemoteMac/Scripts" \
  "$fixture/macos/MimiRemoteMac/Resources/LaunchAgents" \
  "$TEMP_DIR/bin" \
  "$TEMP_DIR/go-root/bin"
cp "$ROOT_DIR/scripts/development-cache-"*.sh "$fixture/scripts/"
cp "$ROOT_DIR/macos/MimiRemoteMac/Scripts/"{build-local,embed-agentd,install-local}.sh \
  "$fixture/macos/MimiRemoteMac/Scripts/"
cp "$ROOT_DIR/macos/MimiRemoteMac/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist" \
  "$fixture/macos/MimiRemoteMac/Resources/LaunchAgents/"

export PATH="$TEMP_DIR/bin:$PATH"
export MIMI_DEVELOPMENT_CACHE_REPO_ROOT="$ROOT_DIR"
export MIMI_DEVELOPMENT_CACHE_ROOT="$TEMP_DIR/cache"
export MACOS_DERIVED_DATA_PATH="$TEMP_DIR/shared-derived"
export MACOS_EMBED_CACHE_DIR="$TEMP_DIR/embed"
export MACOS_DEVELOPMENT_CACHE_LOCK="$TEMP_DIR/build.lock"
export FIXTURE_LOCK_SCRIPT="$ROOT_DIR/scripts/development-cache-lock.sh"
export FIXTURE_BUILD_LOG="$TEMP_DIR/build.log"
export FIXTURE_REVISION="current-worktree"
export FIXTURE_GO_BUILD_LOG="$TEMP_DIR/go-build.log"
export FIXTURE_GO_ROOT="$TEMP_DIR/go-root"

# 仅替换外部构建工具，不启动真实 App，也不改动用户已安装的 App。
cat > "$TEMP_DIR/bin/xcodegen" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$TEMP_DIR/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
app="$MACOS_DERIVED_DATA_PATH/Build/Products/Release/Mimi Remote Mac.app"
mkdir -p "$app/Contents/Resources"
cp /usr/bin/true "$app/Contents/Resources/agentd"
printf '%s\n' "$FIXTURE_REVISION" > "$app/revision"
printf '%s\n' "$FIXTURE_REVISION" >> "$FIXTURE_BUILD_LOG"
STUB
cat > "$TEMP_DIR/bin/codesign" <<'STUB'
#!/usr/bin/env bash
[[ -f "${!#}/revision" ]]
STUB
cat > "$TEMP_DIR/bin/ditto" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
set +e
MIMI_DEVELOPMENT_CACHE_LOCK_WAIT_SECONDS=0 \
  bash "$FIXTURE_LOCK_SCRIPT" "$MACOS_DEVELOPMENT_CACHE_LOCK" -- true >/dev/null 2>&1
lock_status=$?
set -e
[[ "$lock_status" -eq 75 ]] || { echo "复制 App 时没有持有构建锁" >&2; exit 1; }
cp -R "$1" "$2"
STUB
cat > "$TEMP_DIR/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$TEMP_DIR/bin/go" <<'STUB'
#!/usr/bin/env bash
exec "$FIXTURE_GO_ROOT/bin/go" "$@"
STUB
cat > "$TEMP_DIR/go-root/bin/go" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == env && "${2:-}" == GOROOT ]]; then
  printf '%s\n' "$FIXTURE_GO_ROOT"
  exit 0
fi
if [[ "${1:-}" == env && "${2:-}" == GOVERSION ]]; then
  if [[ "$PWD" == */experiments/tailcat ]]; then
    printf 'go1.27.0\n'
  else
    printf 'go1.25.0\n'
  fi
  exit 0
fi
[[ "${1:-}" == build ]] || { echo "未预期的 go 调用：$*" >&2; exit 1; }
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]] || { echo "go build 缺少 -o" >&2; exit 1; }
printf '%s\t%s\n' "${GOCACHE-<unset>}" "$output" >> "$FIXTURE_GO_BUILD_LOG"
mkdir -p "$(dirname "$output")"
cp /usr/bin/true "$output"
chmod +x "$output"
STUB
cat > "$TEMP_DIR/bin/cargo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
target=""
target_dir=""
profile="debug"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target="$2"
      shift 2
      ;;
    --target-dir)
      target_dir="$2"
      shift 2
      ;;
    --release)
      profile="release"
      shift
      ;;
    *) shift ;;
  esac
done
[[ -n "$target" && -n "$target_dir" ]] || { echo "cargo 缺少目标目录" >&2; exit 1; }
output="$target_dir/$target/$profile/alleycat-claude-bridge"
mkdir -p "$(dirname "$output")"
cp /usr/bin/true "$output"
chmod +x "$output"
STUB
chmod +x "$TEMP_DIR/bin/"* "$TEMP_DIR/go-root/bin/go"

old_app="$MACOS_DERIVED_DATA_PATH/Build/Products/Release/Mimi Remote Mac.app"
mkdir -p "$old_app"
printf 'other-worktree\n' > "$old_app/revision"
destination="$TEMP_DIR/installed/Mimi Remote Mac.app"
bash "$fixture/macos/MimiRemoteMac/Scripts/install-local.sh" "$destination"
[[ "$(cat "$destination/revision")" == current-worktree ]]
[[ "$(wc -l < "$FIXTURE_BUILD_LOG" | tr -d ' ')" == 1 ]]

export FIXTURE_REVISION="updated-worktree"
bash "$fixture/macos/MimiRemoteMac/Scripts/install-local.sh" "$destination"
[[ "$(cat "$destination/revision")" == updated-worktree ]]
[[ "$(wc -l < "$FIXTURE_BUILD_LOG" | tr -d ' ')" == 2 ]]
[[ "$(cat "$TEMP_DIR/installed/"Mimi\ Remote\ Mac.backup-*.app/revision)" == current-worktree ]]

embed_env=(
  "SRCROOT=$fixture/macos/MimiRemoteMac"
  "TARGET_BUILD_DIR=$TEMP_DIR/embed-build"
  "CONTENTS_FOLDER_PATH=Mimi Remote Mac.app/Contents"
  "ARCHS=arm64"
  "CONFIGURATION=Debug"
  "MACOS_EMBED_CACHE_DIR=$TEMP_DIR/embed"
  "CODE_SIGNING_ALLOWED=NO"
)
embed_script="$fixture/macos/MimiRemoteMac/Scripts/embed-agentd.sh"
env -u GOCACHE "${embed_env[@]}" bash "$embed_script" >/dev/null

agentd_intermediate="$TEMP_DIR/embed/Debug/go/arm64/agentd"
tailcat_intermediate="$TEMP_DIR/embed/Debug/tailcat-go/arm64/mimi-tailcat-experiment"
[[ "$(sed -n '1p' "$FIXTURE_GO_BUILD_LOG")" == $'<unset>\t'"$agentd_intermediate" ]]
[[ "$(sed -n '2p' "$FIXTURE_GO_BUILD_LOG")" == $'<unset>\t'"$tailcat_intermediate" ]]
[[ ! -e "$TEMP_DIR/embed/Debug/go/arm64/gocache" ]]
[[ ! -e "$TEMP_DIR/embed/Debug/tailcat-go/arm64/gocache" ]]
[[ -x "$TEMP_DIR/embed-build/Mimi Remote Mac.app/Contents/Resources/agentd" ]]
[[ -x "$TEMP_DIR/embed/Debug/rust/debug/aarch64-apple-darwin/aarch64-apple-darwin/debug/alleycat-claude-bridge" ]]

caller_go_cache="$TEMP_DIR/caller-gocache"
: > "$FIXTURE_GO_BUILD_LOG"
env "GOCACHE=$caller_go_cache" "${embed_env[@]}" bash "$embed_script" >/dev/null
[[ "$(sed -n '1p' "$FIXTURE_GO_BUILD_LOG")" == "$caller_go_cache"$'\t'"$agentd_intermediate" ]]
[[ "$(sed -n '2p' "$FIXTURE_GO_BUILD_LOG")" == "$caller_go_cache"$'\t'"$tailcat_intermediate" ]]

echo "Mac 安装锁、内嵌产物隔离和 Go 全局缓存继承自测通过。"
