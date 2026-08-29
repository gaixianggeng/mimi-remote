#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$SRCROOT/../.." && pwd)"
bundle_root="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
agentd_output="$bundle_root/Resources/agentd"
# agentd looks for the Claude bridge next to itself, so a complete install
# needs no per-machine configuration and no separate `cargo install`.
bridge_output="$bundle_root/Resources/alleycat-claude-bridge"
launch_agent_output="$bundle_root/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
launch_agent_source="$SRCROOT/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
configuration="${CONFIGURATION:-Debug}"

log() {
  printf '[embed-agentd %s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

# Build phase 被 Xcode 标记为 alwaysOutOfDate，因此这里必须复用稳定缓存。
# 配置和 Rust target/profile 都进入目录层级，避免 Debug/Release 或 arm64/
# x86_64 之间串用产物；默认路径仍在 DerivedData 内，CI 可显式传入 runner.temp。
default_cache_root="${PROJECT_TEMP_DIR:-${BUILD_DIR:-$TARGET_BUILD_DIR}/../MimiRemoteMacEmbedCache}"
cache_root="${MACOS_EMBED_CACHE_DIR:-$default_cache_root}"
cache_root="${cache_root%/}/${configuration}"
mkdir -p "$cache_root"

case "$configuration" in
  Debug|Debug-*)
    rust_profile="debug"
    ;;
  *)
    # Release 和 Archive 必须继续使用 release profile；未知配置也按发布安全默认处理。
    rust_profile="release"
    ;;
esac

log "开始构建内嵌 agentd/Claude bridge：configuration=${configuration} rust-profile=${rust_profile}"

find_go() {
  local candidate
  for candidate in "$(command -v go 2>/dev/null || true)" /usr/local/go/bin/go /opt/homebrew/bin/go; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      local resolved_goroot
      resolved_goroot="$($candidate env GOROOT 2>/dev/null || true)"
      if [[ -x "$resolved_goroot/bin/go" ]]; then
        printf '%s\n' "$resolved_goroot/bin/go"
        return 0
      fi
    fi
  done
  return 1
}

go_binary="$(find_go || true)"
if [[ -z "$go_binary" ]]; then
  echo "Mimi Remote Mac 构建失败：未找到可用 Go 工具链。" >&2
  exit 1
fi

go_version="$(GOTOOLCHAIN=local "$go_binary" env GOVERSION)"
if [[ "$go_version" != go1.25.* ]]; then
  echo "Mimi Remote Mac 构建失败：agentd 需要 Go 1.25，当前为 ${go_version}。" >&2
  exit 1
fi

mkdir -p "$(dirname "$agentd_output")" "$(dirname "$launch_agent_output")"

architectures=($ARCHS)
outputs=()
agent_version="${MARKETING_VERSION:-devel}"
if [[ -n "${CURRENT_PROJECT_VERSION:-}" && "$agent_version" != "devel" ]]; then
  # 同一个 marketing version 会有多个本地/发布构建；把 App build 写进 agentd，
  # 才能识别更新 App 后 launchd 仍驻留旧二进制的情况。
  agent_version="${agent_version}+mac.${CURRENT_PROJECT_VERSION}"
fi
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *)
      echo "Mimi Remote Mac 构建失败：不支持架构 ${architecture}。" >&2
      exit 1
      ;;
  esac
  # 每个架构使用独立 Go 编译缓存和输出，既可复用又不会把交叉编译结果混在一起。
  go_cache_root="$cache_root/go/$architecture"
  mkdir -p "$go_cache_root/gocache"
  output="$go_cache_root/agentd"
  go_started_at=$SECONDS
  log "构建 agentd：arch=${architecture} goarch=${go_arch} cache=${go_cache_root}"
  (
    cd "$project_root"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" GOTOOLCHAIN=local \
      GOCACHE="$go_cache_root/gocache" \
      "$go_binary" build -trimpath \
      -ldflags "-s -w -X main.version=${agent_version}" \
      -o "$output" ./cmd/agentd
  )
  log "agentd 构建完成：arch=${architecture} elapsed=$((SECONDS - go_started_at))s"
  outputs+=("$output")
done

if [[ ${#outputs[@]} -eq 1 ]]; then
  cp "${outputs[0]}" "$agentd_output"
else
  /usr/bin/lipo -create "${outputs[@]}" -output "$agentd_output"
fi
chmod 0755 "$agentd_output"
cp "$launch_agent_source" "$launch_agent_output"
/usr/bin/plutil -lint "$launch_agent_output" >/dev/null
log "agentd 已内嵌：archs=${architectures[*]}"

# --- Claude bridge -----------------------------------------------------------
find_cargo() {
  local candidate
  for candidate in "$(command -v cargo 2>/dev/null || true)" "$HOME/.cargo/bin/cargo" /opt/homebrew/bin/cargo; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

cargo_binary="$(find_cargo || true)"
if [[ -z "$cargo_binary" ]]; then
  echo "Mimi Remote Mac 构建失败：未找到 cargo，无法构建随包 Claude bridge。" >&2
  echo "安装 Rust 工具链后重试：https://rustup.rs" >&2
  exit 1
fi

bridge_outputs=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64) rust_target=aarch64-apple-darwin ;;
    x86_64) rust_target=x86_64-apple-darwin ;;
  esac
  # target-dir 按 profile/target 分开，Cargo 的增量产物可以跨 build phase 复用。
  rust_target_dir="$cache_root/rust/$rust_profile/$rust_target"
  mkdir -p "$rust_target_dir"
  cargo_args=(
    build
    --locked
    --manifest-path "$project_root/Cargo.toml"
    --package alleycat-claude-bridge
    --bin alleycat-claude-bridge
    --target "$rust_target"
    --target-dir "$rust_target_dir"
  )
  if [[ "$rust_profile" == "release" ]]; then
    cargo_args+=(--release)
  fi
  bridge_binary="$rust_target_dir/$rust_target/$rust_profile/alleycat-claude-bridge"
  rust_started_at=$SECONDS
  log "构建 Claude bridge：arch=${architecture} target=${rust_target} profile=${rust_profile} target-dir=${rust_target_dir}"
  # Drop MACOSX_DEPLOYMENT_TARGET for this build. Xcode sets it for the Swift
  # target, and cargo applies it to host artifacts too — which breaks the
  # proc-macro crates rustc has to load at compile time (`can't find crate for
  # tokio_macros`). The bridge's own deployment floor comes from the target
  # triple, so nothing is lost by unsetting it here.
  if ! env -u MACOSX_DEPLOYMENT_TARGET "$cargo_binary" "${cargo_args[@]}"; then
    echo "Mimi Remote Mac 构建失败：无法为 $rust_target 构建 Claude bridge。" >&2
    echo "缺少目标时先安装：rustup target add $rust_target" >&2
    exit 1
  fi
  [[ -x "$bridge_binary" ]] \
    || { echo "Mimi Remote Mac 构建失败：Cargo 未产出 $bridge_binary。" >&2; exit 1; }
  log "Claude bridge 构建完成：arch=${architecture} elapsed=$((SECONDS - rust_started_at))s"
  bridge_outputs+=("$bridge_binary")
done

if [[ ${#bridge_outputs[@]} -eq 1 ]]; then
  cp "${bridge_outputs[0]}" "$bridge_output"
else
  /usr/bin/lipo -create "${bridge_outputs[@]}" -output "$bridge_output"
fi
chmod 0755 "$bridge_output"
log "Claude bridge 已内嵌：archs=${architectures[*]} profile=${rust_profile}"

entitlements_args=()
if [[ -n "${CODE_SIGN_ENTITLEMENTS:-}" && -f "$SRCROOT/$CODE_SIGN_ENTITLEMENTS" ]]; then
  entitlements_args=(--entitlements "$SRCROOT/$CODE_SIGN_ENTITLEMENTS")
fi

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    "${entitlements_args[@]}" \
    --options runtime --timestamp=none "$agentd_output"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.claude-bridge \
    --options runtime --timestamp=none "$bridge_output"
fi

"$agentd_output" version >/dev/null
"$bridge_output" --version >/dev/null
log "内嵌二进制 smoke check 通过"

# This phase runs after Xcode has sealed the bundle, so the binaries it just
# wrote are not covered by that seal. On a full build Xcode signs afterwards
# and everything lines up; on an incremental build where the Swift target was
# untouched it skips signing, and the bundle ships with a stale seal that
# fails `codesign --verify`. Re-seal here so both paths end up valid.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "${entitlements_args[@]}" \
    --options runtime --timestamp=none \
    "$TARGET_BUILD_DIR/$WRAPPER_NAME"
fi
