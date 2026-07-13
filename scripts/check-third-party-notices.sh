#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NOTICES="THIRD_PARTY_NOTICES.md"

for command_name in go ruby rg awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "第三方许可门禁失败：缺少命令 $command_name。" >&2
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
    echo "第三方许可门禁失败：缺少 $name $version 的清单和许可证正文，请更新 $NOTICES。" >&2
    exit 1
  fi
  if ! rg -Fq -- "### $name $version" "$NOTICES"; then
    echo "第三方许可门禁失败：缺少 $name $version 的许可证正文，请更新 $NOTICES。" >&2
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
  local license_file=""

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

  for candidate in LICENSE LICENSE.txt COPYING; do
    if [[ -f "$module_dir/$candidate" ]]; then
      license_file="$module_dir/$candidate"
      break
    fi
  done
  if [[ -z "$license_file" ]]; then
    echo "第三方许可门禁失败：$module $version 没有可识别的许可证文件。" >&2
    exit 1
  fi

  if [[ "$(notice_license_body "$module" "$version")" != "$(cat "$license_file")" ]]; then
    echo "第三方许可门禁失败：$module $version 的许可证正文与模块源码不一致。" >&2
    exit 1
  fi
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

rg -Fq -- "THIRD_PARTY_NOTICES.md" .goreleaser.yml || {
  echo "第三方许可门禁失败：GoReleaser 归档未包含 THIRD_PARTY_NOTICES.md。" >&2
  exit 1
}

echo "第三方许可门禁通过。"
