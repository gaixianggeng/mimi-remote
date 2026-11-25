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
  local dmg_details dmg_team_id dmg_timestamp

  verify_developer_id_application "$dmg_path" "DMG 镜像"
  if ! dmg_details="$(codesign -d --verbose=4 "$dmg_path" 2>&1)"; then
    echo "Mac 安装包签名校验失败：无法读取 DMG 镜像签名详情：${dmg_details}" >&2
    return 1
  fi
  dmg_team_id="$(extract_codesign_field "$dmg_details" "TeamIdentifier")"
  if [[ ! "$dmg_team_id" =~ ^[A-Z0-9]+$ ]]; then
    echo "Mac 安装包签名校验失败：DMG 镜像缺少有效的非空 Team ID（实际：${dmg_team_id:-<空>}）。" >&2
    return 1
  fi
  if [[ -n "$expected_team_id" && "$dmg_team_id" != "$expected_team_id" ]]; then
    echo "Mac 安装包签名校验失败：DMG 镜像的 Team ID（${dmg_team_id}）与主 App（${expected_team_id}）不一致。" >&2
    return 1
  fi
  dmg_timestamp="$(extract_codesign_field "$dmg_details" "Timestamp")"
  if [[ -z "$dmg_timestamp" || "$dmg_timestamp" == "none" ]]; then
    echo "Mac 安装包签名校验失败：DMG 镜像缺少有效的安全时间戳（Timestamp=${dmg_timestamp:-<空>}）。" >&2
    return 1
  fi
  VERIFIED_DMG_TEAM_ID="$dmg_team_id"
}
