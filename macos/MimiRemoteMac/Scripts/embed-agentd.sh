#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$SRCROOT/../.." && pwd)"
bundle_root="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
agentd_output="$bundle_root/Resources/agentd"
launch_agent_output="$bundle_root/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
launch_agent_source="$SRCROOT/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"

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
  echo "Mimi Remote Mac 构建失败：agentd 需要 Go 1.25，当前为 $go_version。" >&2
  exit 1
fi

mkdir -p "$(dirname "$agentd_output")" "$(dirname "$launch_agent_output")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-agentd-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

architectures=($ARCHS)
outputs=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *)
      echo "Mimi Remote Mac 构建失败：不支持架构 $architecture。" >&2
      exit 1
      ;;
  esac
  output="$build_dir/agentd-$architecture"
  (
    cd "$project_root"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" GOTOOLCHAIN=local \
      "$go_binary" build -trimpath \
      -ldflags "-s -w -X main.version=${MARKETING_VERSION:-devel}" \
      -o "$output" ./cmd/agentd
  )
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

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    --options runtime --timestamp=none "$agentd_output"
fi

"$agentd_output" version >/dev/null
