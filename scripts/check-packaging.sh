#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "Packaging 门禁失败：$1" >&2
  exit 1
}

for command_name in awk bash cmp grep mktemp ruby shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Packaging 门禁失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done

for required_file in \
  .github/workflows/go-ci.yml \
  .github/workflows/release.yml \
  .goreleaser.yml \
  README.md \
  macos/MimiRemoteMac/MimiRemoteMac.xcodeproj/project.pbxproj \
  macos/MimiRemoteMac/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist \
  packaging/skill/install-mimi-remote/SKILL.md \
  packaging/skill/install-mimi-remote/agents/openai.yaml \
  packaging/systemd/mimi-remote.service \
  scripts/build-macos-installer.sh \
  scripts/check-macos-installer.sh \
  scripts/install-linux.sh \
  scripts/test-install-linux.sh \
  scripts/check-release-prerequisites.sh \
  scripts/check-macos-release-signing.sh \
  scripts/check-release-artifacts.sh \
  scripts/package-skill.sh \
  scripts/sign-agentd-dev-macos.sh \
  scripts/restart-agentd-dev-macos.sh \
  scripts/restart-agentd-dev-handoff-macos.sh \
  scripts/verify-release.sh \
  docs/install-upgrade-rollback.md; do
  [[ -f "$required_file" ]] || fail "缺少 ${required_file}。"
done

bash -n \
  scripts/build-macos-installer.sh \
  scripts/check-macos-installer.sh \
  scripts/check-release-prerequisites.sh \
  scripts/check-macos-release-signing.sh \
  scripts/check-release-artifacts.sh \
  scripts/package-skill.sh \
  scripts/sign-agentd-dev-macos.sh \
  scripts/restart-agentd-dev-macos.sh \
  scripts/restart-agentd-dev-handoff-macos.sh \
  scripts/install-linux.sh \
  scripts/test-install-linux.sh \
  scripts/verify-release.sh
bash ./scripts/check-release-prerequisites.sh --self-test >/dev/null
bash ./scripts/check-macos-release-signing.sh --self-test >/dev/null
bash ./scripts/restart-agentd-dev-macos.sh --self-test >/dev/null
bash ./scripts/verify-release.sh --self-test >/dev/null
bash ./scripts/install-linux.sh --self-test >/dev/null
bash ./scripts/test-install-linux.sh >/dev/null

if [[ -f SKILL.md ]] && ! cmp -s SKILL.md packaging/skill/install-mimi-remote/SKILL.md; then
  fail "根 SKILL.md 与独立 Skill 包内容不一致。"
fi
# BSD 与 GNU mktemp 对 -t 模板的语义不同；显式使用带 XXXXXX 的完整路径，
# 保证 macOS 本地发布和 Linux GitHub Actions 使用同一实现。
skill_dist="$(mktemp -d "${TMPDIR:-/tmp}/mimi-skill-check.XXXXXX")"
trap 'rm -rf "$skill_dist"' EXIT
bash ./scripts/package-skill.sh "$skill_dist" >/dev/null
[[ -f "$skill_dist/install-mimi-remote.zip" ]] \
  || fail "Skill 打包脚本没有生成 install-mimi-remote.zip。"
[[ -f "$skill_dist/install-mimi-remote.zip.sha256" ]] \
  || fail "Skill 打包脚本没有生成 SHA-256。"
(
  cd "$skill_dist"
  shasum -a 256 -c install-mimi-remote.zip.sha256 >/dev/null
) || fail "Skill 发布包 SHA-256 校验失败。"
rm -rf "$skill_dist"
trap - EXIT

service_file="packaging/systemd/mimi-remote.service"
grep -Fqx 'ExecStart=%h/.local/bin/agentd serve --config %h/.config/mimi-remote/config.json' "$service_file" \
  || fail "systemd ExecStart 没有固定使用用户安装目录和 mimi-remote 默认配置。"
grep -Fqx 'Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin' "$service_file" \
  || fail "systemd PATH 缺少用户二进制目录或系统目录。"
grep -Fqx 'UMask=0077' "$service_file" \
  || fail "systemd service 没有使用私有文件 umask。"
grep -Fqx 'NoNewPrivileges=true' "$service_file" \
  || fail "systemd service 缺少 NoNewPrivileges。"
grep -Fqx 'WantedBy=default.target' "$service_file" \
  || fail "systemd user service 没有挂到 default.target。"
if grep -Eq '^(User=root|Group=root)|/root/' "$service_file"; then
  fail "systemd user service 不得依赖 root。"
fi

grep -Fq 'packaging/systemd/mimi-remote.service' .goreleaser.yml \
  || fail "GoReleaser 归档没有包含 systemd 模板。"
grep -Fq 'run [opt_bin/"agentd", "serve"]' .goreleaser.yml \
  || fail "Homebrew service 没有执行 agentd serve。"
grep -Fq 'system "#{bin}/agentd", "version"' .goreleaser.yml \
  || fail "Homebrew Formula 缺少安装后 version 测试。"
release_target="$(awk '
  $0 == "release:" { in_release = 1; next }
  in_release && /^[^[:space:]#]/ { exit }
  in_release && $1 == "owner:" { owner = $2 }
  in_release && $1 == "name:" { name = $2 }
  END { print owner "/" name }
' .goreleaser.yml)"
[[ "$release_target" == "gaixianggeng/mimi-remote" ]] \
  || fail "GoReleaser release.github 必须固定为 gaixianggeng/mimi-remote。"
grep -Fqx '  mode: keep-existing' .goreleaser.yml \
  || fail "GoReleaser 必须保留已有 Release 说明，支持同 tag 恢复。"
grep -Fqx '  replace_existing_artifacts: true' .goreleaser.yml \
  || fail "GoReleaser 必须允许 tap 失败后重跑同 tag 附件。"
grep -Fq 'scripts/install-linux.sh' .goreleaser.yml \
  || fail "GoReleaser 归档没有包含 Linux 安装脚本。"
grep -Fq 'envOrDefault "MIMI_MACOS_SIGNING" "disabled"' .goreleaser.yml \
  || fail "GoReleaser 没有为正式 tag 启用 macOS 签名开关。"
grep -Fq 'MACOS_SIGN_P12' .goreleaser.yml \
  || fail "GoReleaser 没有接入 Developer ID 证书。"
grep -Fq 'MACOS_NOTARY_KEY' .goreleaser.yml \
  || fail "GoReleaser 没有接入 Apple notarization。"

for workflow_file in .github/workflows/go-ci.yml .github/workflows/release.yml; do
  grep -Fq 'version: "v2.15.3"' "$workflow_file" \
    || fail "$workflow_file 的 GoReleaser 版本未固定为 v2.15.3。"
done
grep -Fq 'GORELEASER_VERSION="2.15.3"' scripts/verify-release.sh \
  || fail "本地发布脚本的 GoReleaser 版本未固定为 v2.15.3。"
grep -Fq 'bash ./scripts/check-release-prerequisites.sh' .github/workflows/release.yml \
  || fail "Release workflow 没有调用公开发布前置门禁。"
grep -Fq 'bash ./scripts/check-macos-release-signing.sh' .github/workflows/release.yml \
  || fail "Release workflow 没有在发布前校验 macOS 签名凭据。"
grep -Fq 'MIMI_REQUIRE_MACOS_SIGNATURE: "1"' .github/workflows/release.yml \
  || fail "Release workflow 没有对已发布 Darwin 归档执行签名门禁。"
grep -Fq 'runs-on: macos-26' .github/workflows/release.yml \
  || fail "Release workflow 没有使用支持当前 Mac deployment target 的 macos-26 runner。"
grep -Fq 'scripts/build-macos-installer.sh' .github/workflows/release.yml \
  || fail "Release workflow 没有构建 Mac DMG。"
grep -Fq 'scripts/check-macos-installer.sh --require-notarization' .github/workflows/release.yml \
  || fail "Release workflow 没有校验 Developer ID 与 notarization。"
grep -Fq 'gh release upload "$GITHUB_REF_NAME"' .github/workflows/release.yml \
  || fail "Release workflow 没有上传 Mac DMG 到 GitHub Release。"
grep -Fq 'scripts/package-skill.sh' .github/workflows/release.yml \
  || fail "Release workflow 没有构建 Codex Skill 发布包。"
grep -Fq 'dist-skill/install-mimi-remote.zip' .github/workflows/release.yml \
  || fail "Release workflow 没有上传 Codex Skill 发布包。"

if [[ -f scripts/export-public-backend.sh ]]; then
  grep -Fq 'packaging/skill/install-mimi-remote' scripts/export-public-backend.sh \
    || fail "公开镜像导出脚本没有包含 Codex Skill。"
  grep -Fq 'scripts/package-skill.sh' scripts/export-public-backend.sh \
    || fail "公开镜像导出脚本没有包含 Skill 打包入口。"
  grep -Fxq '/dist-skill/' packaging/public/.gitignore \
    || fail "公开镜像没有忽略 Skill 构建目录，GoReleaser 正式发布会因工作区不干净而失败。"
fi

release_docs=(README.md docs/install-upgrade-rollback.md)
[[ -f docs/p0-p1-roadmap.md ]] && release_docs+=(docs/p0-p1-roadmap.md)
if grep -Fq 'go run github.com/goreleaser/goreleaser' "${release_docs[@]}"; then
  fail "公开发布文档仍在使用会切换构建工具链的 go run GoReleaser 命令。"
fi
grep -Fq 'bash ./scripts/verify-release.sh' README.md \
  || fail "README 没有使用统一的本地发布校验入口。"
if [[ -f docs/p0-p1-roadmap.md ]]; then
  grep -Fq 'bash ./scripts/verify-release.sh' docs/p0-p1-roadmap.md \
    || fail "P0/P1 清单没有使用统一的本地发布校验入口。"
fi
grep -Fq 'bash ./scripts/install-linux.sh install' docs/install-upgrade-rollback.md \
  || fail "Linux 安装文档没有使用归档内的一键安装入口。"
grep -Fq 'replace_existing_artifacts' docs/install-upgrade-rollback.md \
  || fail "运维文档没有说明 Release/tap 部分失败的恢复边界。"

echo "Packaging 门禁通过：Homebrew、systemd、Codex Skill 与本地发布入口保持一致。"
