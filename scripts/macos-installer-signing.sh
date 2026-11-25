#!/usr/bin/env bash

MACOS_FIXED_MACHOS=(
  'Contents/MacOS/Mimi Remote Mac|com.gaixianggeng.mimi.mac'
  'Contents/Resources/agentd|com.gaixianggeng.mimi.mac.agentd'
  'Contents/Resources/alleycat-claude-bridge|com.gaixianggeng.mimi.mac.claude-bridge'
  'Contents/Resources/mimi-claude-adapter|com.gaixianggeng.mimi.mac.claude-adapter'
  'Contents/Resources/mimi-agy-adapter|com.gaixianggeng.mimi.mac.agy-adapter'
  'Contents/Resources/mimi-tailcat-experiment|com.gaixianggeng.mimi.mac.tailcat'
)

verify_macos_fixed_entry_paths() {
  local app="$1" path entry
  # find 不跟随包内父目录链接。固定入口及其父目录也必须走真实节点。
  for path in Contents Contents/MacOS Contents/Resources; do
    if [[ -L "$app/$path" || ( -e "$app/$path" && ! -d "$app/$path" ) ]]; then
      echo "Mac 安装包签名校验失败：固定入口的父目录必须是真实目录，不得为符号链接：${path}。" >&2
      return 1
    fi
  done
  for entry in "${MACOS_FIXED_MACHOS[@]}"; do
    path="${entry%%|*}"
    if [[ -L "$app/$path" ]]; then
      echo "Mac 安装包签名校验失败：固定入口不得为符号链接：${path}。" >&2
      return 1
    fi
    if [[ -e "$app/$path" && ( ! -f "$app/$path" || ! -x "$app/$path" ) ]]; then
      echo "Mac 安装包签名校验失败：固定入口必须是可执行普通文件：${path}。" >&2
      return 1
    fi
  done
}

verify_present_macos_fixed_machos() {
  local app="$1" require_team="$2" team="$3" require_developer_id="$4" require_timestamp="$5"
  local path entry
  # 直接读取固定路径，让卷决定大小写是否等价。遍历路径的实际拼写不影响标识符要求。
  for entry in "${MACOS_FIXED_MACHOS[@]}"; do
    path="${entry%%|*}"
    if [[ -e "$app/$path" ]]; then
      verify_macho_slice_policy "$app/$path" "$path" "${entry#*|}" \
        "$require_team" "$team" "$require_developer_id" "$require_timestamp"
    fi
  done
}

read_codesign_details() {
  local target="$1" label="$2"
  shift 2
  local executable_line details

  # verbosity 0 只输出 Executable 行。保留末尾换行，才能识别路径本身的换行。
  if ! executable_line="$(codesign -d "$@" --verbose=0 "$target" 2>&1 && printf '.')"; then
    echo "Mac 安装包签名校验失败：无法读取 ${label} 的签名路径：${executable_line}" >&2
    return 1
  fi
  if [[ "$executable_line" != Executable=?*$'\n.' || "${executable_line%$'\n.'}" == *[$'\r\n']* ]]; then
    echo "Mac 安装包签名校验失败：${label} 的 Executable 路径含换行或输出有歧义。" >&2
    return 1
  fi
  executable_line="${executable_line%$'\n.'}"

  # verbosity 1 保留所需字段，但不输出可包含任意文本的证书名称。
  if ! details="$(codesign -d "$@" --verbose=1 "$target" 2>&1)"; then
    echo "Mac 安装包签名校验失败：无法读取 ${label} 的签名详情：${details}" >&2
    return 1
  fi
  if [[ "$details" != "$executable_line"$'\n'* ]]; then
    echo "Mac 安装包签名校验失败：${label} 的 Executable 与签名路径不一致。" >&2
    return 1
  fi
  printf '%s\n' "${details#"$executable_line"$'\n'}"
}

extract_unique_codesign_field() {
  LC_ALL=C awk -v key="$2" '
    index($0, key "=") == 1 { count++; value = substr($0, length(key) + 2) }
    END {
      if (count != 1 || value == "" || value ~ /[[:cntrl:]]/) exit 1
      print value
    }
  ' <<<"$1"
}

verify_codesign_identifier() {
  local target="$1" label="$2" details="$3" expected="$4"
  shift 4
  local identifier escaped_identifier
  if ! identifier="$(extract_unique_codesign_field "$details" Identifier)"; then
    echo "Mac 安装包签名校验失败：${label} 缺少唯一、非空的签名 identifier。" >&2
    return 1
  fi
  local required_identifier="${expected:-$identifier}"
  escaped_identifier="${required_identifier//\\/\\\\}"
  escaped_identifier="${escaped_identifier//\"/\\\"}"
  # 即使没有固定值，也要让系统确认文本读出的 identifier 等于签名中的完整值。
  if ! codesign --verify --strict --test-requirement="=identifier \"$escaped_identifier\"" "$@" "$target" >&2; then
    echo "Mac 安装包签名校验失败：${label} 的签名 identifier 不匹配或含换行（期望 ${required_identifier}）。" >&2
    return 1
  fi
  printf '%s\n' "$required_identifier"
}

verify_codesign_team_id() {
  local target="$1" label="$2" details="$3" expected="$4"
  shift 4
  local team
  if ! team="$(extract_unique_codesign_field "$details" TeamIdentifier)" || [[ ! "$team" =~ ^[A-Z0-9]+$ ]]; then
    echo "Mac 安装包签名校验失败：${label} 缺少有效的非空 Team ID，或 Team ID 输出有歧义。" >&2
    return 1
  fi
  if [[ -n "$expected" && "$team" != "$expected" ]]; then
    echo "Mac 安装包签名校验失败：${label}的 Team ID（${team}）与主 App（${expected}）不一致。" >&2
    return 1
  fi
  if ! codesign --verify --strict --test-requirement="=certificate leaf[subject.OU] = \"$team\"" "$@" "$target" >&2; then
    echo "Mac 安装包签名校验失败：${label}的 Team ID（${team}）与签名证书不一致。" >&2
    return 1
  fi
  printf '%s\n' "$team"
}

verify_codesign_timestamp() {
  local details="$1" label="$2" timestamp
  if ! timestamp="$(extract_unique_codesign_field "$details" Timestamp)" || [[ "$timestamp" == "none" ]]; then
    echo "Mac 安装包签名校验失败：${label}缺少有效的安全时间戳或时间戳输出有歧义。" >&2
    return 1
  fi
}

verify_macho_slice_policy() {
  local target="$1" display_label="$2" expected_identifier="$3" require_team="$4" expected_team="$5"
  local require_developer_id="$6" require_timestamp="$7"
  local lipo_target="$target"
  if [[ -d "$target" ]]; then
    lipo_target="$(resolve_app_executable_path "$target")" || return 1
  fi

  local slice_archs
  if ! slice_archs="$(lipo -archs "$lipo_target" 2>&1)"; then
    echo "Mac 安装包签名校验失败：无法枚举 ${display_label} 的架构切片：${slice_archs}" >&2
    return 1
  fi
  if [[ -z "$slice_archs" ]]; then
    echo "Mac 安装包签名校验失败：${display_label} 未包含任何架构切片。" >&2
    return 1
  fi

  local slice_arch label details identifier resolved_identifier="" resolved_identifier_arch=""
  local resolved_team="$expected_team"
  for slice_arch in $slice_archs; do
    label="${display_label}（${slice_arch}）"
    details="$(read_codesign_details "$target" "$label" --arch "$slice_arch")" || return 1
    if ! grep -Eq '^CodeDirectory[[:space:]].*flags=0x[0-9a-fA-F]+\(([^)]*,)?runtime(,[^)]*)?\)' <<<"$details"; then
      echo "Mac 安装包签名校验失败：${label} 缺少 Hardened Runtime 标志（flags 需包含 runtime）。" >&2
      return 1
    fi
    identifier="$(verify_codesign_identifier "$target" "$label" "$details" "$expected_identifier" --arch "$slice_arch")" || return 1
    if [[ -z "$resolved_identifier" ]]; then
      resolved_identifier="$identifier"
      resolved_identifier_arch="$slice_arch"
    elif [[ "$identifier" != "$resolved_identifier" ]]; then
      echo "Mac 安装包签名校验失败：${label} 的签名 identifier（${identifier}）与 ${resolved_identifier_arch} 切片（${resolved_identifier}）不一致。" >&2
      return 1
    fi

    if [[ "$require_developer_id" == "1" ]]; then
      verify_developer_id_application "$target" "$label" --arch "$slice_arch" || return 1
    fi
    if [[ "$require_team" == "1" ]]; then
      resolved_team="$(verify_codesign_team_id "$target" "$label" "$details" "$resolved_team" --arch "$slice_arch")" || return 1
    fi
    if [[ "$require_timestamp" == "1" ]]; then
      verify_codesign_timestamp "$details" "$label" || return 1
    fi
  done
  RESOLVED_SLICE_TEAM_ID="$resolved_team"
}

verify_developer_id_application() {
  local target="$1" label="$2"
  shift 2
  # Apple 信任锚、Developer ID CA 和 Application 叶证书，见 Apple TN3127。
  local requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  # codesign 用参数值前导 "=" 区分内联要求和文件路径。
  if ! codesign --verify --strict --verbose=2 --test-requirement="=$requirement" "$@" "$target"; then
    echo "Mac 安装包签名校验失败：${label}不是有效的 Developer ID Application 签名（未通过 Apple 证书要求）。" >&2
    return 1
  fi
}

verify_dmg_image_signature() {
  local dmg_path="$1" expected_team_id="${2:-}"
  local dmg_details

  verify_developer_id_application "$dmg_path" "DMG 镜像" || return 1
  dmg_details="$(read_codesign_details "$dmg_path" "DMG 镜像")" || return 1
  verify_codesign_identifier "$dmg_path" "DMG 镜像" "$dmg_details" "" >/dev/null || return 1
  VERIFIED_DMG_TEAM_ID="$(verify_codesign_team_id "$dmg_path" "DMG 镜像" "$dmg_details" "$expected_team_id")" || return 1
  verify_codesign_timestamp "$dmg_details" "DMG 镜像"
}
