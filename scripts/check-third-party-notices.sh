#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NOTICES="THIRD_PARTY_NOTICES.md"
TAILCAT_MODULE_DIR="experiments/tailcat"
# 发布包始终包含 Tailcat；检出不完整时必须失败，不能把漏检当成许可清单齐全。
if [[ ! -f "$TAILCAT_MODULE_DIR/go.mod" ]]; then
  echo "第三方许可门禁失败：缺少 Tailcat module 的 go.mod：${TAILCAT_MODULE_DIR}/go.mod。" >&2
  exit 1
fi
PACKAGE_RESOLVED="ios/MimiRemote/MimiRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

for command_name in go ruby rg awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "第三方许可门禁失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done

notice_license_body() {
  local name="$1"
  local version="$2"
  awk -v heading="### $name $version" '
    $0 == heading { found = 1; next }
    found && $0 == "```text" { in_license = 1; next }
    in_license && $0 == "```" { exit }
    in_license { print }
  ' "$NOTICES"
}

require_notice_entry() {
  local name="$1"
  local version="$2"
  local expected="| \`$name\` | \`$version\` |"
  if ! rg -Fq -- "$expected" "$NOTICES"; then
    echo "第三方许可门禁失败：缺少 $name $version 的清单和许可证正文，请更新 ${NOTICES}。" >&2
    exit 1
  fi
  if ! rg -Fq -- "### $name $version" "$NOTICES"; then
    echo "第三方许可门禁失败：缺少 $name $version 的许可证正文，请更新 ${NOTICES}。" >&2
    exit 1
  fi

  local license_body
  license_body="$(notice_license_body "$name" "$version")"
  if [[ "${#license_body}" -lt 200 ]] || ! grep -Eq 'Copyright|Apache License|Redistribution|Permission is hereby granted' <<<"$license_body"; then
    echo "第三方许可门禁失败：$name $version 的许可证正文为空或明显不完整。" >&2
    exit 1
  fi
}

validate_go_module_license() {
  local module="$1"
  local version="$2"
  local module_json
  local module_dir

  if ! module_json="$(go mod download -json "$module@$version")"; then
    echo "第三方许可门禁失败：无法下载 $module $version 的模块元数据。" >&2
    exit 1
  fi
  if ! module_dir="$(printf '%s' "$module_json" | ruby -rjson -e '
    metadata = JSON.parse(STDIN.read)
    abort(metadata["Error"]) if metadata["Error"]
    puts metadata.fetch("Dir")
  ')"; then
    echo "第三方许可门禁失败：无法解析 $module $version 的模块目录。" >&2
    exit 1
  fi

  validate_go_module_dir_license "$module" "$version" "$module_dir"
}

validate_notice_body_matches_file() {
  local name="$1"
  local version="$2"
  local file="$3"
  if [[ "$(notice_license_body "$name" "$version")" != "$(cat "$file")" ]]; then
    echo "第三方许可门禁失败：$name $version 的许可证正文与模块源码不一致。" >&2
    exit 1
  fi
}

validate_go_module_dir_license() {
  local module="$1"
  local version="$2"
  local module_dir="$3"
  local candidate
  local license_file=""

  for candidate in LICENSE LICENSE.txt LICENSE.md COPYING; do
    if [[ -f "$module_dir/$candidate" ]]; then
      license_file="$module_dir/$candidate"
      break
    fi
  done
  if [[ -z "$license_file" ]]; then
    echo "第三方许可门禁失败：$module $version 没有可识别的许可证文件。" >&2
    exit 1
  fi
  validate_notice_body_matches_file "$module" "$version" "$license_file"
}

validate_swift_license_checksum() {
  local identity="$1"
  local version="$2"
  local expected=""
  local license_body
  local actual

  # 摘要由 Package.resolved 对应 revision 的上游 LICENSE/NOTICE 生成，防止正文被误删或截断。
  case "$identity|$version" in
    "swift-markdown|0.8.0") expected="a287d3f38552a2b7c9264319761b03d49e1ab1c5c11ebbe4ed68328b45555e88" ;;
    "swift-markdown NOTICE|0.8.0") expected="d111b6caf5376721efa735dc47069c2fc9b245ecbc3c7ada8c59d6c823141e30" ;;
    "swift-cmark|0.8.0") expected="883fd19b75bad9ff8b1ef0ce3e98e909b46cced8f85f2b06c6fc5b655014fa4e" ;;
    "swift-syntax|603.0.1") expected="2245a990b635558be210fb3eb4f8a6f7a49aebc0fefbf5859146a65ddc7ddcf3" ;;
    "swift-snapshot-testing|1.19.2") expected="ae6b29268a507436557b16fd0a071bcb01398926b748ebf41e07f01a689189f5" ;;
    "swift-custom-dump|1.6.0") expected="499cab523b8faf078485e35f6bf917c061b51cb8ab284569811c02e4f5622056" ;;
    "xctest-dynamic-overlay|1.9.0") expected="499cab523b8faf078485e35f6bf917c061b51cb8ab284569811c02e4f5622056" ;;
    *)
      echo "第三方许可门禁失败：$identity $version 缺少 pinned Swift 许可证摘要。" >&2
      exit 1
      ;;
  esac

  license_body="$(notice_license_body "$identity" "$version")"
  actual="$(printf '%s' "$license_body" | ruby -rdigest -e 'print Digest::SHA256.hexdigest(STDIN.read)')"
  if [[ "$actual" != "$expected" ]]; then
    echo "第三方许可门禁失败：$identity $version 的许可证正文与 pinned 摘要不一致。" >&2
    exit 1
  fi
}

# Tailcat 是独立 Go module，只统计发布包实际编入的模块。目标与发布构建保持一致：
# Mac 安装包（macos/MimiRemoteMac/Scripts/embed-agentd.sh）与 Linux 归档（.goreleaser.yml）
# 的辅助程序关闭 CGO；iOS 框架由 scripts/build-tailcat-mobile.sh 用 gomobile 绑定，gobind
# 生成的代码另外引用 golang.org/x/mobile/bind/seq。字段：GOOS GOARCH CGO_ENABLED 构建标签 包列表。
TAILCAT_BUILD_TARGETS=(
  "darwin arm64 0 - ./cmd/mimi-tailcat-experiment"
  "darwin amd64 0 - ./cmd/mimi-tailcat-experiment"
  "linux amd64 0 - ./cmd/mimi-tailcat-experiment"
  "linux arm64 0 - ./cmd/mimi-tailcat-experiment"
  "ios arm64 1 ios ./mobile/tailcatmobile golang.org/x/mobile/bind/seq"
  "ios amd64 1 ios ./mobile/tailcatmobile golang.org/x/mobile/bind/seq"
)

# 输出“模块路径、版本、模块目录、包目录”，以制表符分隔；只含第三方模块的包。
tailcat_linked_packages() {
  local target goos goarch cgo tags packages
  local template='{{if and .Module (not .Module.Main)}}{{.Module.Path}}{{"\t"}}{{.Module.Version}}{{"\t"}}{{.Module.Dir}}{{"\t"}}{{.Dir}}{{end}}'
  for target in "${TAILCAT_BUILD_TARGETS[@]}"; do
    read -r goos goarch cgo tags packages <<<"$target"
    [[ "$tags" != "-" ]] || tags=""
    # packages 有意按空格拆成多个包参数。
    # shellcheck disable=SC2086
    (
      cd "$TAILCAT_MODULE_DIR"
      GOTOOLCHAIN=auto GOOS="$goos" GOARCH="$goarch" CGO_ENABLED="$cgo" \
        go list -mod=readonly -deps -tags="$tags" -f "$template" $packages
    ) || return 1
  done
}

# 模块内被编入的包所在子目录（不含模块根目录）如果自带许可证或 NOTICE，必须单独列出正文，
# 条目名为“模块路径/相对文件路径”。
tailcat_subdirectory_licenses() {
  local linked="$1"
  local module version module_dir package_dir dir candidate
  while IFS=$'\t' read -r module version module_dir package_dir; do
    [[ -n "$module" ]] || continue
    dir="$package_dir"
    while [[ "$dir" == "$module_dir"/* ]]; do
      for candidate in "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYING* "$dir"/NOTICE*; do
        [[ -f "$candidate" ]] || continue
        printf '%s\t%s\t%s\n' "$module/${candidate#"$module_dir"/}" "$version" "$candidate"
      done
      dir="${dir%/*}"
    done
  done <<<"$linked" | LC_ALL=C sort -u
}

validate_tailcat_notices() {
  local go_version go_root linked modules subdirectory_licenses
  local module version module_dir candidate name file

  # Tailcat module 要求比根 module 更新的 Go；与发布构建一样允许自动选择工具链。
  if ! go_version="$(cd "$TAILCAT_MODULE_DIR" && GOTOOLCHAIN=auto go env GOVERSION)" \
    || ! go_root="$(cd "$TAILCAT_MODULE_DIR" && GOTOOLCHAIN=auto go env GOROOT)"; then
    echo "第三方许可门禁失败：无法解析 Tailcat module 的 Go 工具链。" >&2
    exit 1
  fi
  require_notice_entry "Go standard library/runtime" "$go_version"
  if [[ "$(notice_license_body "Go standard library/runtime" "$go_version")" != "$(cat "$go_root/LICENSE")" ]]; then
    echo "第三方许可门禁失败：Go standard library/runtime $go_version 的许可证正文与 Tailcat 使用的 Go 工具链不一致。" >&2
    exit 1
  fi

  if ! linked="$(tailcat_linked_packages)"; then
    echo "第三方许可门禁失败：无法枚举 Tailcat 发布构建编入的 Go 包。" >&2
    exit 1
  fi
  linked="$(LC_ALL=C sort -u <<<"$linked")"
  if [[ -z "$linked" ]]; then
    echo "第三方许可门禁失败：Tailcat 发布构建没有枚举到任何第三方模块，构建目标可能已失效。" >&2
    exit 1
  fi

  modules="$(cut -f1-3 <<<"$linked" | LC_ALL=C sort -u)"
  while IFS=$'\t' read -r module version module_dir; do
    [[ -n "$module" ]] || continue
    require_notice_entry "$module" "$version"
    validate_go_module_dir_license "$module" "$version" "$module_dir"
    # Apache-2.0 等许可证要求随分发保留 NOTICE；模块根目录有 NOTICE 时单独列出正文。
    for candidate in "$module_dir"/NOTICE*; do
      [[ -f "$candidate" ]] || continue
      name="$module/${candidate##*/}"
      require_notice_entry "$name" "$version"
      validate_notice_body_matches_file "$name" "$version" "$candidate"
    done
  done <<<"$modules"

  subdirectory_licenses="$(tailcat_subdirectory_licenses "$linked")"
  while IFS=$'\t' read -r name version file; do
    [[ -n "$name" ]] || continue
    require_notice_entry "$name" "$version"
    validate_notice_body_matches_file "$name" "$version" "$file"
  done <<<"$subdirectory_licenses"
}

go_version="$(go env GOVERSION)"
require_notice_entry "Go standard library/runtime" "$go_version"
if [[ "$(notice_license_body "Go standard library/runtime" "$go_version")" != "$(cat "$(go env GOROOT)/LICENSE")" ]]; then
  echo "第三方许可门禁失败：Go standard library/runtime $go_version 的许可证正文与当前 Go 工具链不一致。" >&2
  exit 1
fi

if ! go_modules="$(go list -m -f '{{if not .Main}}{{.Path}} {{.Version}}{{end}}' all)"; then
  echo "第三方许可门禁失败：无法解析 Go module graph。" >&2
  exit 1
fi
while read -r module version; do
  [[ -n "$module" && -n "$version" ]] || continue
  require_notice_entry "$module" "$version"
  validate_go_module_license "$module" "$version"
done <<<"$go_modules"

validate_tailcat_notices

if [[ -d ios ]]; then
  if [[ ! -f "$PACKAGE_RESOLVED" ]]; then
    echo "第三方许可门禁失败：iOS 源码存在，但缺少 Swift Package.resolved。" >&2
    exit 1
  fi
  if ! swift_pins="$(ruby -rjson -e '
    JSON.parse(File.read(ARGV.fetch(0))).fetch("pins").each do |pin|
      state = pin.fetch("state")
      puts "#{pin.fetch("identity")} #{state["version"] || state.fetch("revision")}"
    end
  ' "$PACKAGE_RESOLVED")"; then
    echo "第三方许可门禁失败：无法解析 Swift Package.resolved。" >&2
    exit 1
  fi
  while read -r identity version; do
    [[ -n "$identity" && -n "$version" ]] || continue
    require_notice_entry "$identity" "$version"
    validate_swift_license_checksum "$identity" "$version"
  done <<<"$swift_pins"

  require_notice_entry "swift-markdown NOTICE" "0.8.0"
  validate_swift_license_checksum "swift-markdown NOTICE" "0.8.0"
fi

rg -Fq -- "THIRD_PARTY_NOTICES.md" .goreleaser.yml || {
  echo "第三方许可门禁失败：GoReleaser 归档未包含 THIRD_PARTY_NOTICES.md。" >&2
  exit 1
}

if [[ -d ios ]]; then
  rg -Fq -- "THIRD_PARTY_NOTICES.md in Resources" ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj || {
    echo "第三方许可门禁失败：iOS App 未打包 THIRD_PARTY_NOTICES.md。" >&2
    exit 1
  }
fi

echo "第三方许可门禁通过。"
