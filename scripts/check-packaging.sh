#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "Packaging 门禁失败：$1" >&2
  exit 1
}

for command_name in awk bash cmp grep mktemp shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Packaging 门禁失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done

for required_file in \
  .github/workflows/pr-gate.yml \
  .github/workflows/docs-ci.yml \
  .github/workflows/go-ci.yml \
  .github/workflows/release.yml \
  .goreleaser.yml \
  README.md \
  macos/MimiRemoteMac/MimiRemoteMac.xcodeproj/project.pbxproj \
  macos/MimiRemoteMac/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist \
  macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements \
  packaging/skill/install-mimi-remote/SKILL.md \
  packaging/skill/install-mimi-remote/agents/openai.yaml \
  packaging/systemd/mimi-remote.service \
  packaging/windows/mimi-remote.iss \
  packaging/windows/register-service.ps1 \
  scripts/build-macos-installer.sh \
  scripts/ci-pr-scope.sh \
  scripts/check-docs-static.sh \
  scripts/check-critical-regressions.sh \
  scripts/check-pr-gate.sh \
  scripts/check-macos-installer.sh \
  scripts/build-windows-installer.ps1 \
  scripts/check-windows-installer.ps1 \
  scripts/test-windows-install.ps1 \
  scripts/install-linux.sh \
  scripts/ios-dev.sh \
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
  scripts/ci-pr-scope.sh \
  scripts/check-docs-static.sh \
  scripts/check-critical-regressions.sh \
  scripts/check-pr-gate.sh \
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
grep -Fq 'bash ./scripts/ios-dev.sh build-for-testing' \
  packaging/skill/install-mimi-remote/SKILL.md \
  || fail "安装 Skill 的 iOS 测试构建没有使用统一 ios-dev.sh 入口。"
if grep -Fq 'xcodebuild' packaging/skill/install-mimi-remote/SKILL.md; then
  fail "安装 Skill 不得绕过 ios-dev.sh 直接调用 xcodebuild。"
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
# 只发布完整主仓库；历史后端快照导出链路已退役。
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
rust_target_setup_count="$(
  grep -Fc 'rustup target add aarch64-apple-darwin x86_64-apple-darwin' \
    .github/workflows/release.yml
)"
[[ "$rust_target_setup_count" == "2" ]] \
  || fail "Release workflow 的 verify/release job 必须安装 universal macOS Rust targets。"
grep -Fq 'scripts/build-macos-installer.sh' .github/workflows/release.yml \
  || fail "Release workflow 没有构建 Mac DMG。"
grep -Fq 'scripts/check-macos-installer.sh --require-notarization' .github/workflows/release.yml \
  || fail "Release workflow 没有校验 Developer ID 与 notarization。"
grep -Fq -- '--development-signing' scripts/build-macos-installer.sh \
  || fail "Mac 安装包构建没有提供同团队签名的本地初始化验收模式。"
grep -Fq -- '--require-team-signing' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有提供 App/agentd/bridge Team ID 一致性校验。"
grep -Fq 'com.gaixianggeng.mimi.mac.claude-bridge' scripts/build-macos-installer.sh \
  || fail "Mac 安装包构建没有为内嵌 Claude bridge 设置稳定签名 identifier。"
grep -Fq 'com.gaixianggeng.mimi.mac.tailcat' scripts/build-macos-installer.sh \
  || fail "Mac 安装包构建没有为内嵌 Tailcat 设置稳定签名 identifier。"
grep -Fq 'for binary_path in "$AGENT_PATH" "$BRIDGE_PATH" "$TAILCAT_PATH"' scripts/build-macos-installer.sh \
  || fail "Mac 安装包构建没有在公证前直接校验内嵌二进制签名。"
! grep -Fq 'com.apple.security.personal-information.photos-library' \
  macos/MimiRemoteMac/Resources/MimiRemoteMac.entitlements \
  || fail "Mac App 仍声明已移除的照片图库 entitlement。"
! grep -Fq 'NSPhotoLibraryUsageDescription' macos/MimiRemoteMac/Resources/Info.plist \
  || fail "Mac App 仍声明已移除的照片图库用途说明。"
[[ ! -e macos/MimiRemoteMac/Sources/App/CodexDaemonSupervisor.swift ]] \
  || fail "Mac App 仍包含已移除的 Codex shared daemon supervisor。"
grep -Fq -- 'CommandLine.arguments.contains("--codex-daemon-supervisor")' macos/MimiRemoteMac/Sources/App/MimiRemoteMacApp.swift \
  || fail "Mac App 缺少旧 shared daemon supervisor 的无 UI 退场保护。"
! grep -Fq -- '--codex-desktop-sync' macos/MimiRemoteMac/Sources/Infrastructure/AgentCommandClient.swift \
  || fail "Mac App 仍包含已移除的 Desktop IPC 实验开关。"
grep -Fq 'main_executable_count' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有校验 Contents/MacOS 主可执行文件唯一性。"
grep -Fq 'BRIDGE_PATH="$APP_PATH/Contents/Resources/alleycat-claude-bridge"' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有校验内嵌 Claude bridge。"
grep -Fq 'TAILCAT_PATH="$APP_PATH/Contents/Resources/mimi-tailcat-experiment"' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有校验内嵌 Tailcat。"
grep -Fq 'codesign --verify --strict --verbose=2 "$candidate_path"' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有逐个校验 App 内 Mach-O 签名。"
grep -Fq 'internal/claudebridge/version.go' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有读取 agentd 的 Claude bridge 最低版本。"
grep -Fq 'version_at_least "$bridge_version" "$minimum_bridge_version"' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有校验内嵌 Claude bridge 与 agentd 的版本兼容性。"
grep -Fq '/usr/bin/arch -arm64' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有在 Apple silicon 上固定使用 arm64 执行版本探针。"
grep -Fq 'find "$APP_PATH" -type f -print0' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有枚举 App 内全部 Mach-O。"
grep -Fq 'xcrun vtool -arch' scripts/check-macos-installer.sh \
  || fail "Mac 安装包门禁没有逐架构检查 macOS 构建元数据。"
grep -Fq 'gh release upload "$RELEASE_TAG"' .github/workflows/release.yml \
  || fail "Release workflow 没有上传 Mac DMG 到 GitHub Release。"
grep -Fq 'scripts/package-skill.sh' .github/workflows/release.yml \
  || fail "Release workflow 没有构建 Codex Skill 发布包。"
grep -Fq 'dist-skill/install-mimi-remote.zip' .github/workflows/release.yml \
  || fail "Release workflow 没有上传 Codex Skill 发布包。"
grep -Fq 'runs-on: windows-latest' .github/workflows/release.yml \
  || fail "Release workflow 没有 Windows runner。"
grep -Fq 'scripts/build-windows-installer.ps1' .github/workflows/release.yml \
  || fail "Release workflow 没有构建 Windows 安装器。"
grep -Fq 'scripts/check-windows-installer.ps1' .github/workflows/release.yml \
  || fail "Release workflow 没有校验 Windows 安装器。"
grep -Fq 'WINDOWS_SIGN_PFX' .github/workflows/release.yml \
  || fail "Release workflow 没有接入 Windows Authenticode 凭据。"
grep -Fq 'Upload verified Windows installer' .github/workflows/release.yml \
  || fail "Release workflow 没有保留已验证的 Windows artifact。"
grep -Fq 'publish-windows:' .github/workflows/release.yml \
  || fail "Release workflow 没有公开发布 Windows 安装包。"
grep -Fq 'gh release upload $env:RELEASE_TAG $files.FullName --clobber' .github/workflows/release.yml \
  || fail "Windows 发布 job 没有上传已验证安装包、摘要和元数据。"

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
