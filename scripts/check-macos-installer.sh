#!/usr/bin/env bash
set -euo pipefail

REQUIRE_NOTARIZATION=0
REQUIRE_DEVELOPER_ID=0
REQUIRE_TEAM_SIGNING=0
VERIFY_APP_MACHO_SIGNATURES=0
CHECK_APP_ONLY=0
VERIFY_CAPABILITIES_KIND=""
VERIFY_CAPABILITIES_VERSION=""
TARGET_PATH=""
DMG_PATH=""
APP_PATH=""
ADAPTER_PATH=""
AGY_ADAPTER_PATH=""
CHECK_TEMP_DIR=""
MOUNT_DIR=""
MOUNT_TARGET=""
MOUNTED=0
RESOLVED_SLICE_TEAM_ID=""
VERIFIED_APP_TEAM_ID=""
macho_count=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    if ! hdiutil detach "$MOUNT_TARGET" -quiet >/dev/null 2>&1; then
      # Finder 的运行态校验可能短暂占用卷；强制卸载仅针对本次只读校验挂载。
      hdiutil detach "$MOUNT_TARGET" -force -quiet >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$CHECK_TEMP_DIR" && -d "$CHECK_TEMP_DIR" ]]; then
    rm -rf -- "$CHECK_TEMP_DIR"
  fi
}
trap cleanup EXIT

version_at_least() {
  local actual="$1"
  local minimum="$2"
  local actual_major actual_minor actual_patch
  local minimum_major minimum_minor minimum_patch

  IFS=. read -r actual_major actual_minor actual_patch <<<"$actual"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<<"$minimum"
  if (( 10#$actual_major != 10#$minimum_major )); then
    (( 10#$actual_major > 10#$minimum_major ))
    return
  fi
  if (( 10#$actual_minor != 10#$minimum_minor )); then
    (( 10#$actual_minor > 10#$minimum_minor ))
    return
  fi
  (( 10#$actual_patch >= 10#$minimum_patch ))
}

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-macos-installer.sh [--require-team-signing] [--require-developer-id] [--require-notarization] <Mimi-Remote-Mac.dmg>
  bash ./scripts/check-macos-installer.sh --app [--require-team-signing] [--require-developer-id] <Mimi-Remote-Mac.app>
  bash ./scripts/check-macos-installer.sh --verify-app-macho-signatures [--require-team-signing] [--require-developer-id] <Mimi-Remote-Mac.app>
  bash ./scripts/check-macos-installer.sh --verify-capabilities-json <claude|agy> <expected-version>
EOF
}

resolve_physical_dir() {
  local dir_path="$1"
  (
    CDPATH= cd -P -- "$dir_path" >/dev/null && pwd -P
  )
}

resolve_app_executable_path() {
  local app_dir="$1"
  local info_plist="$app_dir/Contents/Info.plist"
  local executable_name=""
  if [[ -f "$info_plist" ]]; then
    executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)"
  fi
  if [[ -z "$executable_name" ]]; then
    echo "Mac 安装包校验失败：无法从 ${app_dir}/Contents/Info.plist 读取 CFBundleExecutable。" >&2
    exit 1
  fi
  local executable_path="$app_dir/Contents/MacOS/$executable_name"
  if [[ ! -x "$executable_path" ]]; then
    echo "Mac 安装包校验失败：主 App 可执行文件不存在或不可执行：${executable_path}。" >&2
    exit 1
  fi
  printf '%s\n' "$executable_path"
}

extract_codesign_field() {
  local details="$1"
  local field_name="$2"
  awk -v key="$field_name" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' <<<"$details"
}

has_hardened_runtime_flag() {
  local details="$1"
  grep -Eq '^CodeDirectory[[:space:]].*flags=0x[0-9a-fA-F]+\(([^)]*,)?runtime(,[^)]*)?\)' <<<"$details"
}

verify_macho_slice_policy() {
  local target_path="$1"
  local display_label="$2"
  local expected_identifier="$3"
  local require_team_signing="$4"
  local expected_team_id="$5"
  local require_developer_id="$6"
  local require_timestamp="$7"

  local lipo_target="$target_path"
  if [[ -d "$target_path" ]]; then
    lipo_target="$(resolve_app_executable_path "$target_path")"
  fi

  local slice_archs=""
  if ! slice_archs="$(lipo -archs "$lipo_target" 2>&1)"; then
    echo "Mac 安装包校验失败：无法枚举 ${display_label} 的架构切片：${slice_archs}" >&2
    exit 1
  fi
  if [[ -z "$slice_archs" ]]; then
    echo "Mac 安装包校验失败：${display_label} 未包含任何架构切片。" >&2
    exit 1
  fi

  local slice_arch slice_details slice_identifier slice_team_id slice_timestamp
  local resolved_team="$expected_team_id"
  for slice_arch in $slice_archs; do
    if ! slice_details="$(codesign -d --arch "$slice_arch" --verbose=4 "$target_path" 2>&1)"; then
      echo "Mac 安装包校验失败：无法读取 ${display_label}（${slice_arch}）的签名详情：${slice_details}" >&2
      exit 1
    fi

    if ! has_hardened_runtime_flag "$slice_details"; then
      echo "Mac 安装包校验失败：${display_label}（${slice_arch}）缺少 Hardened Runtime 标志（flags 需包含 runtime）。" >&2
      exit 1
    fi

    if [[ -n "$expected_identifier" ]]; then
      slice_identifier="$(extract_codesign_field "$slice_details" "Identifier")"
      if [[ "$slice_identifier" != "$expected_identifier" ]]; then
        echo "Mac 安装包校验失败：${display_label}（${slice_arch}）的签名 identifier 不稳定（期望 ${expected_identifier}，实际 ${slice_identifier:-<空>}）。" >&2
        exit 1
      fi
    fi

    if [[ "$require_team_signing" == "1" ]]; then
      slice_team_id="$(extract_codesign_field "$slice_details" "TeamIdentifier")"
      if [[ ! "$slice_team_id" =~ ^[A-Z0-9]+$ ]]; then
        echo "Mac 安装包校验失败：${display_label}（${slice_arch}）缺少有效的非空 Team ID（实际：${slice_team_id:-<空>}）。" >&2
        exit 1
      fi
      if [[ -z "$resolved_team" ]]; then
        resolved_team="$slice_team_id"
      elif [[ "$slice_team_id" != "$resolved_team" ]]; then
        echo "Mac 安装包校验失败：${display_label}（${slice_arch}）的 Team ID（${slice_team_id}）与主 App（${resolved_team}）不一致。" >&2
        exit 1
      fi
    fi

    if [[ "$require_developer_id" == "1" ]] \
      && ! grep -Fq 'Authority=Developer ID Application:' <<<"$slice_details"; then
      echo "Mac 安装包校验失败：${display_label}（${slice_arch}）不是有效的 Developer ID Application 签名。" >&2
      exit 1
    fi

    if [[ "$require_timestamp" == "1" ]]; then
      slice_timestamp="$(extract_codesign_field "$slice_details" "Timestamp")"
      if [[ -z "$slice_timestamp" || "$slice_timestamp" == "none" ]]; then
        echo "Mac 安装包校验失败：${display_label}（${slice_arch}）缺少有效的安全时间戳（Timestamp=${slice_timestamp:-<空>}）。" >&2
        exit 1
      fi
    fi
  done

  RESOLVED_SLICE_TEAM_ID="$resolved_team"
}

verify_boolean_true_entitlements() {
  local target_path="$1"
  local display_label="$2"
  shift 2

  local lipo_target="$target_path"
  if [[ -d "$target_path" ]]; then
    lipo_target="$(resolve_app_executable_path "$target_path")"
  fi

  local slice_archs=""
  if ! slice_archs="$(lipo -archs "$lipo_target" 2>&1)"; then
    echo "Mac 安装包校验失败：无法枚举 ${display_label} 的架构切片以检查 entitlements：${slice_archs}" >&2
    exit 1
  fi

  local slice_arch entitlements_file entitlements_err
  for slice_arch in $slice_archs; do
    entitlements_file="$CHECK_TEMP_DIR/entitlements-${slice_arch}.plist"
    entitlements_err="$CHECK_TEMP_DIR/entitlements-${slice_arch}.err"
    if ! codesign -d --arch "$slice_arch" --entitlements - --xml "$target_path" >"$entitlements_file" 2>"$entitlements_err"; then
      echo "Mac 安装包校验失败：无法读取 ${display_label}（${slice_arch}）的签名 entitlements：$(<"$entitlements_err")" >&2
      exit 1
    fi

    if ! python3 - "$entitlements_file" "$display_label" "$slice_arch" "$@" <<'PY'
import plistlib
import sys

plist_path, label, arch, *required_keys = sys.argv[1:]
with open(plist_path, "rb") as fh:
    raw = fh.read()

if not raw.strip():
    print(
        f"Mac 安装包校验失败：{label}（{arch}）签名缺少 entitlements plist（期望启用 {', '.join(required_keys)}）。",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    data = plistlib.loads(raw)
except Exception as exc:
    print(
        f"Mac 安装包校验失败：{label}（{arch}）的 entitlements plist 无法解析：{exc}",
        file=sys.stderr,
    )
    sys.exit(1)

if not isinstance(data, dict):
    print(
        f"Mac 安装包校验失败：{label}（{arch}）的 entitlements 顶层不是字典（实际类型：{type(data).__name__}）。",
        file=sys.stderr,
    )
    sys.exit(1)

for key in required_keys:
    if key not in data:
        print(
            f"Mac 安装包校验失败：{label}（{arch}）签名缺少 {key}。",
            file=sys.stderr,
        )
        sys.exit(1)
    value = data[key]
    if not isinstance(value, bool) or value is not True:
        print(
            f"Mac 安装包校验失败：{label}（{arch}）签名的 {key} 必须为布尔 true（实际类型：{type(value).__name__}，值：{value!r}）。",
            file=sys.stderr,
        )
        sys.exit(1)
PY
    then
      exit 1
    fi
  done
}

validate_adapter_capabilities_json() {
  local adapter_kind="$1"
  local expected_version="$2"
  local capabilities_json="$3"

  if ! MIMI_CAPABILITIES_JSON="$capabilities_json" python3 - "$adapter_kind" "$expected_version" <<'PY'
import json
import os
import re
import sys

kind, expected_version = sys.argv[1:3]
raw = os.environ.get("MIMI_CAPABILITIES_JSON", "")

if kind == "agy":
    label = "Antigravity 适配器"
    runtime_key = "agy"
elif kind == "claude":
    label = "Claude 适配器"
    runtime_key = "claudeCode"
else:
    print(f"Mac 安装包校验失败：未知适配器类型 {kind}。", file=sys.stderr)
    sys.exit(2)

try:
    payload = json.loads(raw)
except Exception as exc:
    print(f"Mac 安装包校验失败：{label}的 --capabilities 输出不是合法 JSON：{exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, dict):
    print(f"Mac 安装包校验失败：{label}的 --capabilities 顶层必须是 JSON object。", file=sys.stderr)
    sys.exit(1)

version = payload.get("version")
if not isinstance(version, str) or version != expected_version:
    print(
        f"Mac 安装包校验失败：{label}的 capabilities.version（{version!r}）与 --version（{expected_version!r}）不一致。",
        file=sys.stderr,
    )
    sys.exit(1)

methods = payload.get("methods")
if not isinstance(methods, list) or not methods or not all(isinstance(item, str) for item in methods):
    print(f"Mac 安装包校验失败：{label}的 capabilities.methods 必须是非空字符串数组。", file=sys.stderr)
    sys.exit(1)
if "turn/start" not in methods:
    print(f"Mac 安装包校验失败：{label}的 capabilities.methods 缺少 turn/start。", file=sys.stderr)
    sys.exit(1)

runtime_block = payload.get(runtime_key)
if not isinstance(runtime_block, dict):
    print(f"Mac 安装包校验失败：{label}的 capabilities.{runtime_key} 必须是 JSON object。", file=sys.stderr)
    sys.exit(1)

min_ver = runtime_block.get("minimumVersion")
if not isinstance(min_ver, str) or not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", min_ver):
    print(
        f"Mac 安装包校验失败：{label}的 capabilities.{runtime_key}.minimumVersion 不是合法版本号（实际：{min_ver!r}）。",
        file=sys.stderr,
    )
    sys.exit(1)
PY
  then
    exit 1
  fi
}

verify_app_machos() {
  local check_arch_and_vtool="${1:-1}"
  local app_team=""
  local candidate_path candidate_kind candidate_team_identifier
  local binary_archs reference_sdk reference_sdk_arch binary_arch build_metadata binary_sdk

  verify_macho_slice_policy \
    "$APP_PATH" \
    "主 App" \
    "" \
    "$REQUIRE_TEAM_SIGNING" \
    "" \
    "$REQUIRE_DEVELOPER_ID" \
    "$REQUIRE_DEVELOPER_ID"
  app_team="$RESOLVED_SLICE_TEAM_ID"
  VERIFIED_APP_TEAM_ID="$app_team"

  # 先完整写入 NUL 分隔临时清单并显式校验 find 退出状态，避免遍历部分失败后仍报告通过。
  local manifest_file="$CHECK_TEMP_DIR/app-macho-manifest.nul"
  if ! find -H "$APP_PATH" -type f -print0 > "$manifest_file"; then
    echo "Mac 安装包校验失败：枚举 App 内文件时 find 失败。" >&2
    exit 1
  fi

  # 不只检查已知入口；后续新增的 framework、helper 或工具也必须带有效签名、hardened runtime、
  # 同 Team ID / Developer ID（按策略）、arm64 及可识别的 macOS 构建元数据。
  macho_count=0
  while IFS= read -r -d '' candidate_path; do
    candidate_kind="$(file -b "$candidate_path")"
    if [[ "$candidate_kind" != Mach-O* ]]; then
      continue
    fi

    macho_count=$((macho_count + 1))
    # codesign --deep 不会可靠拒绝 Resources 下新增的裸 Mach-O。逐个校验，避免未签名
    # sidecar 或残留损坏签名一直拖到 Apple 公证阶段才暴露。
    codesign --verify --strict --verbose=2 "$candidate_path"

    verify_macho_slice_policy \
      "$candidate_path" \
      "${candidate_path#"$APP_PATH"/}" \
      "" \
      "$REQUIRE_TEAM_SIGNING" \
      "$app_team" \
      "$REQUIRE_DEVELOPER_ID" \
      "$REQUIRE_DEVELOPER_ID"
    candidate_team_identifier="$RESOLVED_SLICE_TEAM_ID"

    # Bun 编译的适配器在 hardened runtime 下必须对全部架构切片启用布尔 true 的 JIT 权限。
    if [[ "$candidate_path" == "$ADAPTER_PATH" ]]; then
      verify_boolean_true_entitlements \
        "$candidate_path" \
        "Claude 适配器" \
        com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory
    elif [[ "$candidate_path" == "$AGY_ADAPTER_PATH" ]]; then
      verify_boolean_true_entitlements \
        "$candidate_path" \
        "Antigravity 适配器" \
        com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory
    fi

    if [[ "$check_arch_and_vtool" != "1" ]]; then
      continue
    fi

    binary_archs="$(lipo -archs "$candidate_path")"
    if [[ " $binary_archs " != *" arm64 "* ]]; then
      echo "Mac 安装包校验失败：${candidate_path#"$APP_PATH"/} 是 x86-only Mach-O，缺少 arm64。" >&2
      exit 1
    fi

    reference_sdk=""
    reference_sdk_arch=""
    for binary_arch in $binary_archs; do
      build_metadata="$(xcrun vtool -arch "$binary_arch" -show-build "$candidate_path")"
      if ! grep -Eq 'platform[[:space:]]+MACOS|cmd[[:space:]]+LC_VERSION_MIN_MACOSX' <<<"$build_metadata" \
        || ! grep -Eq '(minos|version)[[:space:]]+[0-9]+' <<<"$build_metadata" \
        || ! grep -Eq 'sdk[[:space:]]+[1-9][0-9]*(\.[0-9]+)*' <<<"$build_metadata"; then
        echo "Mac 安装包校验失败：${candidate_path#"$APP_PATH"/} 的 ${binary_arch} 切片缺少可识别的 macOS 构建元数据。" >&2
        exit 1
      fi

      binary_sdk="$(awk '$1 == "sdk" { print $2; exit }' <<<"$build_metadata")"
      # Claude / Antigravity 适配器的两个切片是 Bun 上游预编译的运行时，各自的 SDK 由上游决定，不要求一致。
      if [[ "$candidate_path" == "$ADAPTER_PATH" || "$candidate_path" == "$AGY_ADAPTER_PATH" ]]; then
        continue
      fi
      if [[ -z "$reference_sdk" ]]; then
        reference_sdk="$binary_sdk"
        reference_sdk_arch="$binary_arch"
      elif [[ "$binary_sdk" != "$reference_sdk" ]]; then
        echo "Mac 安装包校验失败：${candidate_path#"$APP_PATH"/} 的 ${reference_sdk_arch}/${binary_arch} SDK 不一致（${reference_sdk}/${binary_sdk}）。" >&2
        exit 1
      fi
    done
  done < "$manifest_file"

  if [[ "$macho_count" -eq 0 ]]; then
    echo "Mac 安装包校验失败：App 内没有找到 Mach-O 产物。" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarization)
      REQUIRE_NOTARIZATION=1
      REQUIRE_DEVELOPER_ID=1
      REQUIRE_TEAM_SIGNING=1
      shift
      ;;
    --require-developer-id)
      REQUIRE_DEVELOPER_ID=1
      REQUIRE_TEAM_SIGNING=1
      shift
      ;;
    --require-team-signing)
      REQUIRE_TEAM_SIGNING=1
      shift
      ;;
    --app)
      CHECK_APP_ONLY=1
      shift
      ;;
    --verify-app-macho-signatures)
      VERIFY_APP_MACHO_SIGNATURES=1
      shift
      ;;
    --verify-capabilities-json)
      if [[ $# -lt 3 ]]; then
        usage >&2
        exit 2
      fi
      VERIFY_CAPABILITIES_KIND="$2"
      VERIFY_CAPABILITIES_VERSION="$3"
      shift 3
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$TARGET_PATH" ]]; then
        usage >&2
        exit 2
      fi
      TARGET_PATH="$1"
      shift
      ;;
  esac
done

if [[ -n "$VERIFY_CAPABILITIES_KIND" ]]; then
  if [[ "$CHECK_APP_ONLY" == "1" || "$VERIFY_APP_MACHO_SIGNATURES" == "1" || "$REQUIRE_NOTARIZATION" == "1" || "$REQUIRE_DEVELOPER_ID" == "1" || "$REQUIRE_TEAM_SIGNING" == "1" || -n "$TARGET_PATH" ]]; then
    echo "Mac 安装包校验失败：--verify-capabilities-json 不能与其他校验选项混用。" >&2
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Mac 安装包校验失败：缺少命令 python3。" >&2
    exit 127
  fi
  stdin_capabilities="$(cat)"
  validate_adapter_capabilities_json "$VERIFY_CAPABILITIES_KIND" "$VERIFY_CAPABILITIES_VERSION" "$stdin_capabilities"
  exit 0
fi

if [[ "$CHECK_APP_ONLY" == "1" && "$VERIFY_APP_MACHO_SIGNATURES" == "1" ]]; then
  echo "Mac 安装包校验失败：--app 与 --verify-app-macho-signatures 不能同时使用。" >&2
  exit 2
fi
if [[ "$CHECK_APP_ONLY" == "1" && "$REQUIRE_NOTARIZATION" == "1" ]]; then
  echo "Mac 安装包校验失败：--require-notarization 必须校验完整 DMG，不能与 --app 同时使用；仅验证 Developer ID 签名请使用 --require-developer-id。" >&2
  exit 2
fi
if [[ "$VERIFY_APP_MACHO_SIGNATURES" == "1" && "$REQUIRE_NOTARIZATION" == "1" ]]; then
  echo "Mac 安装包校验失败：--require-notarization 必须校验完整 DMG，不能与 --verify-app-macho-signatures 同时使用；仅验证 Developer ID 签名请使用 --require-developer-id。" >&2
  exit 2
fi

if [[ "$VERIFY_APP_MACHO_SIGNATURES" == "1" ]]; then
  if [[ -z "$TARGET_PATH" || ! -d "$TARGET_PATH" ]]; then
    usage >&2
    exit 2
  fi
  for command_name in awk codesign file find grep lipo mktemp plutil python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Mac 安装包校验失败：缺少命令 ${command_name}。" >&2
      exit 127
    fi
  done
  CHECK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-check-macos-installer.XXXXXX")"
  APP_PATH="$(resolve_physical_dir "$TARGET_PATH")"
  ADAPTER_PATH="$APP_PATH/Contents/Resources/mimi-claude-adapter"
  AGY_ADAPTER_PATH="$APP_PATH/Contents/Resources/mimi-agy-adapter"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  verify_app_machos 0
  echo "Mac App Mach-O 签名校验通过：已枚举 ${macho_count} 个 Mach-O。"
  exit 0
fi

if [[ "$CHECK_APP_ONLY" == "1" ]]; then
  if [[ -z "$TARGET_PATH" || ! -d "$TARGET_PATH" ]]; then
    usage >&2
    exit 2
  fi
  for command_name in arch awk codesign file find grep lipo mktemp plutil python3 sed sysctl xcrun; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Mac 安装包校验失败：缺少命令 ${command_name}。" >&2
      exit 127
    fi
  done
  CHECK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-check-macos-installer.XXXXXX")"
  APP_PATH="$(resolve_physical_dir "$TARGET_PATH")"
else
  DMG_PATH="$TARGET_PATH"
  if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    usage >&2
    exit 2
  fi
  for command_name in arch awk codesign file find grep hdiutil lipo mktemp osascript plutil python3 sed shasum sips spctl strings sysctl xcrun; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Mac 安装包校验失败：缺少命令 ${command_name}。" >&2
      exit 127
    fi
  done
  CHECK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-check-macos-installer.XXXXXX")"
  DMG_PATH="$(resolve_physical_dir "$(dirname "$DMG_PATH")")/$(basename "$DMG_PATH")"

  hdiutil verify "$DMG_PATH" >/dev/null
  SHA_PATH="$DMG_PATH.sha256"
  if [[ -f "$SHA_PATH" ]]; then
    (
      CDPATH= cd -P -- "$(dirname "$DMG_PATH")" >/dev/null
      shasum -a 256 -c "$(basename "$SHA_PATH")" >/dev/null
    )
  fi

  ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
  MOUNT_TARGET="$(awk -F '\t' '$1 ~ /^\/dev\/disk/ { device=$1; sub(/[[:space:]]+$/, "", device); print device; exit }' <<<"$ATTACH_OUTPUT")"
  MOUNTED=1
  MOUNT_DIR="$(awk -F '\t' '$NF ~ /^\/Volumes\// { mount_path=$NF } END { print mount_path }' <<<"$ATTACH_OUTPUT")"
  if [[ -z "$MOUNT_TARGET" || -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "Mac 安装包校验失败：无法解析 DMG 挂载点。" >&2
    printf '%s\n' "$ATTACH_OUTPUT" >&2
    exit 1
  fi
  if [[ ! -d "$MOUNT_DIR/Mimi Remote Mac.app" ]]; then
    echo "Mac 安装包校验失败：DMG 缺少 Mimi Remote Mac.app。" >&2
    exit 1
  fi
  APP_PATH="$(resolve_physical_dir "$MOUNT_DIR/Mimi Remote Mac.app")"
fi

APP_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Mimi Remote Mac"
AGENT_PATH="$APP_PATH/Contents/Resources/agentd"
BRIDGE_PATH="$APP_PATH/Contents/Resources/alleycat-claude-bridge"
ADAPTER_PATH="$APP_PATH/Contents/Resources/mimi-claude-adapter"
AGY_ADAPTER_PATH="$APP_PATH/Contents/Resources/mimi-agy-adapter"
TAILCAT_PATH="$APP_PATH/Contents/Resources/mimi-tailcat-experiment"
LAUNCH_AGENT_PATH="$APP_PATH/Contents/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"

if [[ ! -d "$APP_PATH" || ! -x "$APP_EXECUTABLE_PATH" || ! -x "$AGENT_PATH" || ! -x "$BRIDGE_PATH" || ! -x "$ADAPTER_PATH" || ! -x "$AGY_ADAPTER_PATH" || ! -x "$TAILCAT_PATH" || ! -f "$LAUNCH_AGENT_PATH" ]]; then
  echo "Mac 安装包校验失败：缺少 App、agentd、Claude 适配器、Antigravity 适配器、旧 Claude bridge、Tailcat 或 LaunchAgent。" >&2
  exit 1
fi
bash "$ROOT_DIR/scripts/check-macos-notices.sh" "$APP_PATH"
if [[ "$CHECK_APP_ONLY" != "1" ]]; then
  if [[ ! -L "$MOUNT_DIR/Applications" || "$(readlink "$MOUNT_DIR/Applications")" != "/Applications" ]]; then
    echo "Mac 安装包校验失败：DMG 缺少 Applications 拖放入口。" >&2
    exit 1
  fi
  BACKGROUND_PATH="$MOUNT_DIR/.background/dmg-background.png"
  if [[ ! -f "$BACKGROUND_PATH" ]]; then
    echo "Mac 安装包校验失败：DMG 缺少 Finder 背景 PNG。" >&2
    exit 1
  fi
  BACKGROUND_DIMENSIONS="$(sips -g pixelWidth -g pixelHeight "$BACKGROUND_PATH")"
  BACKGROUND_WIDTH="$(awk '$1 == "pixelWidth:" { print $2; exit }' <<<"$BACKGROUND_DIMENSIONS")"
  BACKGROUND_HEIGHT="$(awk '$1 == "pixelHeight:" { print $2; exit }' <<<"$BACKGROUND_DIMENSIONS")"
  if [[ "$BACKGROUND_WIDTH" != "660" || "$BACKGROUND_HEIGHT" != "400" ]]; then
    echo "Mac 安装包校验失败：Finder 背景必须是 660x400，实际为 ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}。" >&2
    exit 1
  fi
  if [[ ! -f "$MOUNT_DIR/.DS_Store" ]]; then
    echo "Mac 安装包校验失败：DMG 缺少 Finder 布局元数据 .DS_Store。" >&2
    exit 1
  fi
  FINDER_METADATA="$(strings -a "$MOUNT_DIR/.DS_Store")"
  if [[ "$FINDER_METADATA" != *"backgroundImageAlias"* || "$FINDER_METADATA" != *"dmg-background.png"* ]]; then
    echo "Mac 安装包校验失败：Finder 布局未保存可恢复的背景图 alias。" >&2
    exit 1
  fi

  # 真实打开只读卷，验证 Finder 确实恢复了图标视图、窗口和位置。
  if ! osascript - "$MOUNT_DIR" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  tell application "Finder"
    set mountedAlias to (POSIX file mountPath) as alias
    set mountedDisk to disk of mountedAlias
    open mountedDisk
    set dmgWindow to missing value
    try
      repeat with attempt from 1 to 20
        try
          set dmgWindow to «class cwnd» of mountedDisk
          set ignoredBounds to «class pbnd» of dmgWindow
          exit repeat
        on error errorMessage
          if attempt = 20 then error ("Finder 无法打开 DMG 窗口：" & errorMessage)
        end try
        delay 0.25
      end repeat
      if dmgWindow is missing value then error "Finder 在 5 秒内没有打开 DMG 窗口。"
      if «class pvew» of dmgWindow is not «constant ecvwicnv» then error "DMG 未使用图标视图。"
      if «class pbnd» of dmgWindow is not {100, 100, 760, 500} then error "DMG 窗口尺寸或位置不正确。"
      if position of item "Mimi Remote Mac.app" of dmgWindow is not {170, 185} then error "App 图标位置不正确。"
      if position of item "Applications" of dmgWindow is not {490, 185} then error "Applications 图标位置不正确。"
      close dmgWindow
    on error errorMessage number errorNumber
      if dmgWindow is not missing value then close dmgWindow
      error errorMessage number errorNumber
    end try
  end tell
end run
APPLESCRIPT
  then
    echo "Mac 安装包校验失败：Finder 无法完整还原品牌拖放布局。" >&2
    exit 1
  fi
fi

plutil -lint "$LAUNCH_AGENT_PATH" >/dev/null

# 主 App 通过 agentd supervisor 承担隐私授权责任：LaunchAgent 只能启动主可执行文件的
# supervisor 模式，不能再直接启动裸 agentd。
launch_bundle_program="$(plutil -extract BundleProgram raw -o - "$LAUNCH_AGENT_PATH" 2>/dev/null || true)"
launch_argument_zero="$(plutil -extract ProgramArguments.0 raw -o - "$LAUNCH_AGENT_PATH" 2>/dev/null || true)"
launch_argument_one="$(plutil -extract ProgramArguments.1 raw -o - "$LAUNCH_AGENT_PATH" 2>/dev/null || true)"
if [[ "$launch_bundle_program" != "Contents/MacOS/Mimi Remote Mac" \
      || "$launch_argument_zero" != "Mimi Remote Mac" \
      || "$launch_argument_one" != "--agentd-supervisor" ]] \
    || plutil -extract ProgramArguments.2 raw -o - "$LAUNCH_AGENT_PATH" >/dev/null 2>&1; then
  echo "Mac 安装包校验失败：LaunchAgent 必须只通过主 App 的 agentd supervisor 启动后台服务。" >&2
  exit 1
fi

for usage_key in NSPhotoLibraryUsageDescription NSDesktopFolderUsageDescription NSDocumentsFolderUsageDescription NSDownloadsFolderUsageDescription; do
  usage_description="$(plutil -extract "$usage_key" raw -o - "$INFO_PLIST_PATH" 2>/dev/null || true)"
  if [[ -z "$usage_description" ]]; then
    echo "Mac 安装包校验失败：Info.plist 缺少非空的 ${usage_key}。" >&2
    exit 1
  fi
done

# 运行时按 Info.plist 的 CFBundleExecutable 解析 TCC 责任进程；最终 Release 包仍只应
# 包含这个主程序，避免把 Debug/Preview dylib 或其他未预期入口带进安装产物。
macos_exec_manifest="$CHECK_TEMP_DIR/macos-executables.nul"
if ! find -H "$APP_PATH/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print0 > "$macos_exec_manifest"; then
  echo "Mac 安装包校验失败：枚举 Contents/MacOS 可执行文件时 find 失败。" >&2
  exit 1
fi
main_executable_count=0
while IFS= read -r -d '' _exec_entry; do
  main_executable_count=$((main_executable_count + 1))
done < "$macos_exec_manifest"
if [[ "$main_executable_count" != "1" ]]; then
  echo "Mac 安装包校验失败：Contents/MacOS 必须恰好有一个可执行文件，实际 ${main_executable_count} 个。" >&2
  exit 1
fi

# 在执行任何二进制版本/能力探针前，必须先完成全部结构、签名、逐片策略、entitlements 与公证校验。
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$AGENT_PATH"
codesign --verify --strict --verbose=2 "$BRIDGE_PATH"
codesign --verify --strict --verbose=2 "$ADAPTER_PATH"
codesign --verify --strict --verbose=2 "$AGY_ADAPTER_PATH"
codesign --verify --strict --verbose=2 "$TAILCAT_PATH"

verify_app_machos 1
app_team_identifier="$VERIFIED_APP_TEAM_ID"

for binary_path in "$APP_EXECUTABLE_PATH" "$AGENT_PATH" "$BRIDGE_PATH" "$ADAPTER_PATH" "$AGY_ADAPTER_PATH" "$TAILCAT_PATH"; do
  binary_archs="$(lipo -archs "$binary_path")"
  for required_arch in arm64 x86_64; do
    if [[ " $binary_archs " != *" $required_arch "* ]]; then
      echo "Mac 安装包校验失败：$(basename "$binary_path") 缺少 ${required_arch}。" >&2
      exit 1
    fi
  done
done

verify_macho_slice_policy "$APP_PATH" "主 App" "com.gaixianggeng.mimi.mac" "$REQUIRE_TEAM_SIGNING" "$app_team_identifier" "$REQUIRE_DEVELOPER_ID" "$REQUIRE_DEVELOPER_ID"
verify_macho_slice_policy "$AGENT_PATH" "agentd" "com.gaixianggeng.mimi.mac.agentd" "$REQUIRE_TEAM_SIGNING" "$app_team_identifier" "$REQUIRE_DEVELOPER_ID" "$REQUIRE_DEVELOPER_ID"
verify_macho_slice_policy "$BRIDGE_PATH" "alleycat-claude-bridge" "com.gaixianggeng.mimi.mac.claude-bridge" "$REQUIRE_TEAM_SIGNING" "$app_team_identifier" "$REQUIRE_DEVELOPER_ID" "$REQUIRE_DEVELOPER_ID"
verify_macho_slice_policy "$ADAPTER_PATH" "mimi-claude-adapter" "com.gaixianggeng.mimi.mac.claude-adapter" "$REQUIRE_TEAM_SIGNING" "$app_team_identifier" "$REQUIRE_DEVELOPER_ID" "$REQUIRE_DEVELOPER_ID"
verify_macho_slice_policy "$AGY_ADAPTER_PATH" "mimi-agy-adapter" "com.gaixianggeng.mimi.mac.agy-adapter" "$REQUIRE_TEAM_SIGNING" "$app_team_identifier" "$REQUIRE_DEVELOPER_ID" "$REQUIRE_DEVELOPER_ID"
verify_macho_slice_policy "$TAILCAT_PATH" "mimi-tailcat-experiment" "com.gaixianggeng.mimi.mac.tailcat" "$REQUIRE_TEAM_SIGNING" "$app_team_identifier" "$REQUIRE_DEVELOPER_ID" "$REQUIRE_DEVELOPER_ID"

verify_boolean_true_entitlements \
  "$APP_PATH" \
  "主 App" \
  com.apple.security.personal-information.photos-library

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

# macOS 27 的前向兼容通知由 Rosetta 进程启动触发。Apple silicon 上显式选择
# arm64，避免版本探针继承调用方的翻译架构偏好，反而由发布检查制造误报。
run_native_version_probe() {
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
    /usr/bin/arch -arm64 "$@"
    return
  fi
  "$@"
}

run_native_version_probe "$AGENT_PATH" version >/dev/null
run_native_version_probe "$TAILCAT_PATH" version >/dev/null
bridge_version_output="$(run_native_version_probe "$BRIDGE_PATH" --version)"
if [[ "$bridge_version_output" =~ ^alleycat-claude-bridge[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  bridge_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
else
  echo "Mac 安装包校验失败：Claude bridge 未返回标准版本：${bridge_version_output}" >&2
  exit 1
fi

adapter_version_output="$(run_native_version_probe "$ADAPTER_PATH" --version)"
if [[ "$adapter_version_output" =~ ^mimi-claude-adapter[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  adapter_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
else
  echo "Mac 安装包校验失败：Claude 适配器未返回标准版本：${adapter_version_output}" >&2
  exit 1
fi
adapter_capabilities="$(run_native_version_probe "$ADAPTER_PATH" --capabilities)"
validate_adapter_capabilities_json claude "$adapter_version" "$adapter_capabilities"

agy_adapter_version_output="$(run_native_version_probe "$AGY_ADAPTER_PATH" --version)"
if [[ "$agy_adapter_version_output" =~ ^mimi-agy-adapter[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  agy_adapter_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
else
  echo "Mac 安装包校验失败：Antigravity 适配器未返回标准版本：${agy_adapter_version_output}" >&2
  exit 1
fi
agy_adapter_capabilities="$(run_native_version_probe "$AGY_ADAPTER_PATH" --capabilities)"
validate_adapter_capabilities_json agy "$agy_adapter_version" "$agy_adapter_capabilities"

minimum_agy_version_source="$ROOT_DIR/internal/agybridge/binary.go"
minimum_agy_adapter_version="$(
  sed -nE 's/^[[:space:]]*MinimumVersion[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' \
    "$minimum_agy_version_source"
)"
if [[ ! "$minimum_agy_adapter_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Mac 安装包校验失败：无法从 agentd 源码读取 Antigravity 适配器最低版本。" >&2
  exit 1
fi
if ! version_at_least "$agy_adapter_version" "$minimum_agy_adapter_version"; then
  echo "Mac 安装包校验失败：Antigravity 适配器 ${agy_adapter_version} 低于 agentd 要求的 ${minimum_agy_adapter_version}。" >&2
  exit 1
fi

minimum_version_source="$ROOT_DIR/internal/claudebridge/version.go"
minimum_bridge_version="$(
  sed -nE 's/^[[:space:]]*MinimumVersion[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' \
    "$minimum_version_source"
)"
if [[ ! "$minimum_bridge_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Mac 安装包校验失败：无法从 agentd 源码读取 Claude bridge 最低版本。" >&2
  exit 1
fi
if ! version_at_least "$bridge_version" "$minimum_bridge_version"; then
  echo "Mac 安装包校验失败：Claude bridge ${bridge_version} 低于 agentd 要求的 ${minimum_bridge_version}。" >&2
  exit 1
fi

team_summary=""
if [[ "$REQUIRE_TEAM_SIGNING" == "1" ]]; then
  team_summary="、Team ID ${app_team_identifier} 一致"
fi
if [[ "$CHECK_APP_ONLY" == "1" ]]; then
  echo "Mac App 快照校验通过（--app 模式，跳过 DMG/Finder 布局）：已枚举 ${macho_count} 个 Mach-O，全部已签名、包含 arm64 且 macOS 构建元数据可读取；universal App、agentd、Claude 适配器 ${adapter_version}、Antigravity 适配器 ${agy_adapter_version}（要求 >= ${minimum_agy_adapter_version}）、旧 Claude bridge ${bridge_version}（要求 >= ${minimum_bridge_version}）、Tailcat、LaunchAgent 和签名结构完整${team_summary}。"
else
  echo "Mac 安装包校验通过：已枚举 ${macho_count} 个 Mach-O，全部已签名、包含 arm64 且 macOS 构建元数据可读取；universal App、agentd、Claude 适配器 ${adapter_version}、Antigravity 适配器 ${agy_adapter_version}（要求 >= ${minimum_agy_adapter_version}）、旧 Claude bridge ${bridge_version}（要求 >= ${minimum_bridge_version}）、Tailcat、LaunchAgent、拖放入口和签名结构完整${team_summary}。"
fi
