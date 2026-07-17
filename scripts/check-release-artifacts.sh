#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="${1:-dist}"
EXPECTED_GO_VERSION="go$(awk '$1 == "go" { print $2; exit }' go.mod)"
EXPECTED_ARCHIVES=(
  "darwin_amd64"
  "darwin_arm64"
  "linux_amd64"
  "linux_arm64"
)
REQUIRED_FILES=(
  "agentd"
  "README.md"
  "LICENSE"
  "NOTICE.md"
  "THIRD_PARTY_NOTICES.md"
  "SECURITY.md"
  "config.example.json"
  "packaging/systemd/mimi-remote.service"
  "scripts/install-linux.sh"
)

for command_name in awk basename cmp find go grep mktemp tar tr wc; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "发布产物门禁失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
    return
  fi
  echo "发布产物门禁失败：缺少 sha256sum 或 shasum。" >&2
  return 127
}

if [[ ! -d "$DIST_DIR" || ! -f "$DIST_DIR/checksums.txt" ]]; then
  echo "发布产物门禁失败：$DIST_DIR 不存在或缺少 checksums.txt。" >&2
  exit 1
fi

# 校验摘要，避免归档在生成后被意外改写。
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && sha256sum -c checksums.txt >/dev/null)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && shasum -a 256 -c checksums.txt >/dev/null)
else
  echo "发布产物门禁失败：缺少 sha256sum 或 shasum。" >&2
  exit 127
fi

formula="$DIST_DIR/homebrew/Formula/mimi-remote.rb"
if [[ ! -f "$formula" ]] || ! grep -Fq 'service do' "$formula" || ! grep -Fq 'agentd", "serve"' "$formula"; then
  echo "发布产物门禁失败：Homebrew Formula 缺失或没有 agentd serve 服务定义。" >&2
  exit 1
fi
if grep -Fq 'codex-ipad-agent' "$formula"; then
  echo "发布产物门禁失败：Homebrew Formula 仍引用旧仓库 codex-ipad-agent。" >&2
  exit 1
fi
if ! grep -Fqx '  homepage "https://github.com/gaixianggeng/mimi-remote"' "$formula"; then
  echo "发布产物门禁失败：Homebrew Formula homepage 不是公开目标仓库。" >&2
  exit 1
fi
if command -v ruby >/dev/null 2>&1 && ! ruby -c "$formula" >/dev/null; then
  echo "发布产物门禁失败：Homebrew Formula 不是有效的 Ruby 文件。" >&2
  exit 1
fi
formula_url_count="$(grep -Ec '^[[:space:]]+url "' "$formula" || true)"
if [[ "$formula_url_count" != "${#EXPECTED_ARCHIVES[@]}" ]]; then
  echo "发布产物门禁失败：Homebrew Formula 下载 URL 数量为 ${formula_url_count}，期望 ${#EXPECTED_ARCHIVES[@]}。" >&2
  exit 1
fi

for platform in "${EXPECTED_ARCHIVES[@]}"; do
  shopt -s nullglob
  archives=("$DIST_DIR"/mimi-remote_*_"$platform".tar.gz)
  shopt -u nullglob
  if [[ "${#archives[@]}" -ne 1 || ! -f "${archives[0]}" ]]; then
    echo "发布产物门禁失败：平台 $platform 应当且只能有一个归档。" >&2
    exit 1
  fi

  archive="${archives[0]}"
  archive_name="$(basename "$archive")"
  archive_listing="$(tar -tzf "$archive")"
  for required_file in "${REQUIRED_FILES[@]}"; do
    if ! grep -Fxq -- "$required_file" <<<"$archive_listing"; then
      echo "发布产物门禁失败：$(basename "$archive") 缺少 ${required_file}。" >&2
      exit 1
    fi
  done

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  tar -xzf "$archive" -C "$temp_dir" \
    agentd \
    packaging/systemd/mimi-remote.service \
    scripts/install-linux.sh
  if [[ ! -x "$temp_dir/agentd" ]]; then
    echo "发布产物门禁失败：$(basename "$archive") 中的 agentd 没有可执行权限。" >&2
    exit 1
  fi
  if ! cmp -s packaging/systemd/mimi-remote.service "$temp_dir/packaging/systemd/mimi-remote.service"; then
    echo "发布产物门禁失败：$(basename "$archive") 中的 systemd 模板与仓库源文件不一致。" >&2
    exit 1
  fi
  if ! cmp -s scripts/install-linux.sh "$temp_dir/scripts/install-linux.sh"; then
    echo "发布产物门禁失败：$(basename "$archive") 中的 Linux 安装脚本与仓库源文件不一致。" >&2
    exit 1
  fi
  bash "$temp_dir/scripts/install-linux.sh" --self-test >/dev/null

  # go version -m 可跨平台读取二进制，不需要在当前机器上执行 Linux 产物。
  build_metadata="$(go version -m "$temp_dir/agentd")"
  binary_go_version="$(awk 'NR == 1 { print $2 }' <<<"$build_metadata")"
  if [[ "$binary_go_version" != "$EXPECTED_GO_VERSION" ]]; then
    echo "发布产物门禁失败：$(basename "$archive") 使用 ${binary_go_version} 编译，期望 ${EXPECTED_GO_VERSION}。" >&2
    exit 1
  fi

  expected_goos="${platform%%_*}"
  expected_goarch="${platform##*_}"
  binary_goos="$(awk '$1 == "build" && $2 ~ /^GOOS=/ { sub(/^GOOS=/, "", $2); print $2; exit }' <<<"$build_metadata")"
  binary_goarch="$(awk '$1 == "build" && $2 ~ /^GOARCH=/ { sub(/^GOARCH=/, "", $2); print $2; exit }' <<<"$build_metadata")"
  binary_cgo="$(awk '$1 == "build" && $2 ~ /^CGO_ENABLED=/ { sub(/^CGO_ENABLED=/, "", $2); print $2; exit }' <<<"$build_metadata")"
  if [[ "$binary_goos" != "$expected_goos" || "$binary_goarch" != "$expected_goarch" ]]; then
    echo "发布产物门禁失败：$(basename "$archive") 实际目标为 ${binary_goos}/${binary_goarch}，期望 ${expected_goos}/${expected_goarch}。" >&2
    exit 1
  fi
  if [[ "$binary_cgo" != "0" ]]; then
    echo "发布产物门禁失败：$(basename "$archive") 不是 CGO_ENABLED=0 的可移植构建。" >&2
    exit 1
  fi

  # Formula 必须引用目标公开仓库中的同名归档，并写入归档的真实摘要。
  # 这能阻止本地旧 Git remote 悄悄生成可发布但无法安装的 Formula。
  formula_url="$(awk -v archive_name="$archive_name" '
    $1 == "url" && index($0, "/" archive_name "\"") {
      gsub(/\"/, "", $2)
      print $2
      exit
    }
  ' "$formula")"
  if [[ "$formula_url" != https://github.com/gaixianggeng/mimi-remote/releases/download/*/"$archive_name" ]]; then
    echo "发布产物门禁失败：$archive_name 的 Formula 下载地址未指向 gaixianggeng/mimi-remote。" >&2
    exit 1
  fi
  formula_sha256="$(awk -v archive_name="$archive_name" '
    $1 == "url" && index($0, "/" archive_name "\"") { found = 1; next }
    found && $1 == "sha256" {
      gsub(/\"/, "", $2)
      print $2
      exit
    }
  ' "$formula")"
  archive_sha256="$(sha256_file "$archive")"
  if [[ "$formula_sha256" != "$archive_sha256" ]]; then
    echo "发布产物门禁失败：$archive_name 的 Formula SHA-256 与真实归档不一致。" >&2
    exit 1
  fi

  rm -rf "$temp_dir"
  trap - EXIT
done

archive_count="$(find "$DIST_DIR" -maxdepth 1 -type f -name 'mimi-remote_*.tar.gz' | wc -l | tr -d ' ')"
if [[ "$archive_count" != "${#EXPECTED_ARCHIVES[@]}" ]]; then
  echo "发布产物门禁失败：归档数量为 ${archive_count}，期望 ${#EXPECTED_ARCHIVES[@]}。" >&2
  exit 1
fi

echo "发布产物门禁通过：4 个平台归档均使用 ${EXPECTED_GO_VERSION}，Formula URL/SHA-256、部署与许可证文件完整。"
