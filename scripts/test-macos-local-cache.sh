#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-local-cache.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
fixture="$TEMP_DIR/repo"
mkdir -p "$fixture/scripts" "$fixture/macos/MimiRemoteMac/Scripts" "$TEMP_DIR/bin"
cp "$ROOT_DIR/scripts/development-cache-"*.sh "$fixture/scripts/"
cp "$ROOT_DIR/macos/MimiRemoteMac/Scripts/"{build-local,install-local}.sh \
  "$fixture/macos/MimiRemoteMac/Scripts/"

export PATH="$TEMP_DIR/bin:$PATH"
export MIMI_DEVELOPMENT_CACHE_REPO_ROOT="$ROOT_DIR"
export MIMI_DEVELOPMENT_CACHE_ROOT="$TEMP_DIR/cache"
export MACOS_DERIVED_DATA_PATH="$TEMP_DIR/shared-derived"
export MACOS_EMBED_CACHE_DIR="$TEMP_DIR/embed"
export MACOS_DEVELOPMENT_CACHE_LOCK="$TEMP_DIR/build.lock"
export FIXTURE_LOCK_SCRIPT="$ROOT_DIR/scripts/development-cache-lock.sh"
export FIXTURE_BUILD_LOG="$TEMP_DIR/build.log"
export FIXTURE_REVISION="current-worktree"

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
chmod +x "$TEMP_DIR/bin/"*

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
echo "Mac 安装使用当前 Worktree 增量构建，并在共享缓存锁内暂存的自测通过。"
