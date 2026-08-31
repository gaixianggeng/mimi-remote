# 安装、升级与回滚

## 目标

让个人开发者在 Windows、Mac 或 Linux 电脑上快速启动 `agentd`，升级时不轮换已有配对凭据，失败时能先恢复服务再排查。生产主路径是“单机 + 私网连接 + 用户自己的 Codex CLI”，跨网络优先使用 Tailscale，同一局域网可直接连接。

## 方案

- macOS 普通用户使用已签名并公证的 DMG；Mac App 内嵌 `agentd`，不要求安装 Homebrew。
- Windows 普通用户使用按用户 EXE 安装器；后台由当前用户计划任务托管，Codex App Server 只监听本机 loopback WebSocket。
- Homebrew 保留给命令行、服务器、自动化和故障恢复场景。
- Linux 使用发布包中的 user-systemd 模板；当前不伪装成与 Homebrew 同等的一键体验。
- 配置和移动端配对 Token 都留在系统用户配置目录，升级二进制不会删除它们。
- 回滚先恢复可用性：优先运行旧 keg 或旧 Release 二进制，再决定是否回滚 Homebrew Formula。

## 实现

### Windows 首次安装、升级与回滚

前置条件：Windows 10/11 x64，并且当前 Windows 用户已安装、登录 Codex CLI 0.149.1 或更高版本。Windows 宿主不依赖 POSIX SSH 或 Unix Socket。`agentd` 启动并管理一个只监听 `ws://127.0.0.1:4222` 的 Codex App Server；它不连接 Codex Desktop 私有 IPC，也不向局域网暴露该端口。

从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 下载同版本的 `Mimi-Remote-Setup-*.exe`、`.sha256` 和 `.metadata.json`。在 PowerShell 中验证摘要和签名状态：

```powershell
$setup = Get-Item .\Mimi-Remote-Setup-*.exe
(Get-FileHash $setup -Algorithm SHA256).Hash
(Get-AuthenticodeSignature $setup).Status
```

摘要必须与 `.sha256` 一致。元数据为 `authenticode-pfx` 时，签名状态必须为 `Valid`；元数据为 `unsigned-release` 时，状态应为 `NotSigned`，Windows 可能显示 Microsoft Defender SmartScreen 警告。

安装器按用户安装到 `%LOCALAPPDATA%\Programs\Mimi Remote`。它注册名为 `Mimi Remote agentd` 的 limited 当前用户任务，并在完成前等待 `/api/readyz` 和真实 App Server `initialize`。配置与配对 Token 保留在 `%APPDATA%\mimi-remote`，日志保留在 `%LOCALAPPDATA%\Mimi Remote\logs`。覆盖安装不会轮换现有 Token。

Windows 防火墙规则和 LAN 监听默认不启用。只有用户明确选择 LAN 访问时，安装器才要求默认网络为“专用网络”，并创建限制为 Private profile 和 `LocalSubnet` 的规则。不得把规则放宽到 Public profile 或任意公网来源。

常用命令：

```powershell
$agentd = "$env:LOCALAPPDATA\Programs\Mimi Remote\agentd.exe"
& $agentd status
& $agentd pair --qr-only
& $agentd doctor --fix
& $agentd logs -n 200
& $agentd restart --no-pair --wait 30s
```

升级时直接覆盖安装新版本。回滚时重新运行上一版来自正式 Release 且摘要匹配的安装器。不要先删除 `%APPDATA%\mimi-remote`。卸载会停止并删除计划任务、移除程序文件和由安装器创建的可选防火墙规则，但保留配置、Token 与日志。

### macOS 首次安装（推荐）

前置条件：macOS 15 或更高版本，已安装并登录 Codex CLI，Mac 与移动设备位于同一私有网络。启用“远程登录”，并先确认 `ssh 127.0.0.1 codex --version` 无需输入登录密码即可成功。跨网络使用时需要登录同一个 Tailscale 网络；同一局域网内不要求安装 Tailscale。

从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 下载 `Mimi-Remote-Mac.dmg` 和 `Mimi-Remote-Mac.dmg.sha256`，在同一目录执行 `shasum -a 256 -c Mimi-Remote-Mac.dmg.sha256`。校验通过后打开 DMG，将 **Mimi Remote Mac** 拖入“应用程序”，再从菜单栏选择代码目录并完成首次设置。安装包内已包含 `agentd` 和兼容的 `alleycat-claude-bridge`。

检测到旧 `homebrew.mxcl.mimi-remote` 时，不要先手工停服。让 Mac App 执行接管：它会先跑 Doctor，停止 Homebrew service，注册内嵌 LaunchAgent 并等待就绪；失败时尝试恢复旧 Homebrew 服务。迁移保留 Application Support 中的配置、Token 和配对关系。

### macOS 命令行安装（高级）

```bash
brew update
brew install gaixianggeng/tap/mimi-remote

codex --version
codex app-server --help
agentd up
agentd status
```

`agentd status` 将进程存活和业务就绪分开显示；脚本使用 `agentd status --json` 时，`process_ok` 只代表 `/healthz` 可达，`service_ok` 才代表配置、鉴权、当前平台的 App Server transport、Codex 版本和真实 `initialize` 均已通过。安装与升级只能以后者为成功条件。

`agentd up` 会创建 `~/Library/Application Support/mimi-remote/config.json`，以 `0600` 保存，并通过 localhost SSH 连接共享 Unix App Server，然后启动 Homebrew 后台服务。检测到 Tailscale 时优先使用；否则自动启用 LAN 监听并生成当前局域网地址。重复运行会复用现有配置和移动端 Token，不会停止共享 App Server、Desktop 普通本地实例或 OpenClaw 实例。

Agent 或自动化首次安装必须使用安全模式，初始化与启动逻辑不变，但不输出二维码、Endpoint 或长期访问码：

```bash
agentd up --no-pair
agentd up --no-pair --json
```

JSON 安全模式只返回 `version`、`service_ok` 和可选的安全 warning，不包含带 Token 的完整 setup `result`。需要配对时由用户在不会进入远程任务日志的本机终端执行 `agentd pair --qr-only`。

### macOS App 升级与回滚

首个 DMG 不带自动更新。升级时下载目标正式版本的 DMG 和 SHA-256 文件，校验后用新 App 覆盖“应用程序”中的现有版本；不要先删除旧 App，也不要删除 `~/Library/Application Support/mimi-remote`。打开新版本后确认 service owner 仍是 `Mimi Remote Mac`，版本、Doctor、Codex 和已启用的 Claude channel 均正常。

需要回滚时安装上一个仍可从正式 Release 获取、经过 Developer ID 签名和 Apple 公证的 DMG。优先只回滚 App 和内嵌二进制；除非确认新版本写入了旧版本无法读取的配置，否则继续复用现有配置。snapshot、ad-hoc 或未公证构建不能作为稳定回滚版本。

移动或删除 App 前，先在菜单栏执行“退出并停止服务”。如果要回到 Homebrew，在设置中执行“停止 App 服务并恢复 Homebrew”，确认旧服务重新就绪后再移除 App，避免系统保留指向不存在 bundle 的 LaunchAgent 注册。

### macOS Homebrew 升级

先做本地备份。备份目录含 Token，不能上传到 Issue、PR 或网盘公开链接。

```bash
set -euo pipefail

config_dir="$HOME/Library/Application Support/mimi-remote"
backup_dir="$HOME/Library/Application Support/mimi-remote-backups/$(date +%Y%m%d-%H%M%S)"
umask 077
mkdir -p "$backup_dir"

if [[ -f "$config_dir/config.json" && ! -L "$config_dir/config.json" ]]; then
  cp -p "$config_dir/config.json" "$backup_dir/config.json"
fi

brew update
brew upgrade mimi-remote
agentd restart
agentd status
```

macOS 上的 `agentd restart` 会让 launchd 通过单次 `kickstart` 原子重启已经加载的服务；它不会先卸载服务再尝试重新加载。因此即使重启命令来自当前 `agentd` 托管的 Codex 任务，新进程也会由 launchd 独立拉起，不会因调用链随旧进程退出而长期停机。服务原本未加载时，命令才会安全回退到 `brew services start`。

不要在 `agentd` 提供的远程任务中直接运行 `brew services restart mimi-remote`。该命令包含独立的停止、启动两步，第一步可能终止正在执行第二步的任务。

### macOS 源码构建与文件授权

macOS 的文件隐私授权不是只按路径保存。系统还会记录可执行文件的 designated requirement，用它判断升级后的程序是不是原来的程序。Go 默认生成的 ad-hoc 签名只有当前二进制的 `cdhash`；每次重新编译都会改变，因此把普通 `go build` 产物直接覆盖到 Homebrew Cellar 后，下一次启动可能再次请求 Desktop、Documents、Downloads、网络卷、其他 App 容器或完全磁盘访问权限。

仓库提供的开发重启流水线保持 Homebrew 配置、label 和 Token 不变，只替换服务二进制：

```bash
# 本机终端发起并等待 readyz
bash ./scripts/restart-agentd-dev-macos.sh

# 从当前 agentd/Codex 托管的远程任务发起
bash ./scripts/restart-agentd-dev-macos.sh --no-wait

# 新服务连接恢复后检查结果
bash ./scripts/restart-agentd-dev-macos.sh --status
agentd doctor
```

完整顺序是：

1. 使用当前源码构建带 Git revision 的候选二进制；
2. 使用 Keychain 中的 `Apple Development` identity 和固定 identifier `com.gaixianggeng.mimi-remote.agentd.dev` 签名；
3. 备份当前 Homebrew 二进制，把后续工作提交给独立的 launchd 一次性 job；
4. 交接 job 原子替换二进制，对既有 `homebrew.mxcl.mimi-remote` 执行单次 `kickstart`；
5. 最多等待 25 秒，通过 `agentd status --json` 同时验证版本和 `service_ok=true`；
6. 新版本失败时恢复原二进制，再次 kickstart 并验证旧版本；结果写入 `~/Library/Application Support/mimi-remote/dev-restart/latest-status`，日志写入 `~/Library/Logs/mimi-remote-dev-restart.log`。

如果自动回滚本身也失败，终态会包含旧二进制备份路径并保留该文件，供人工恢复，不会清掉最后一份可用备份。

独立交接 job 是必要的：如果直接让当前远程任务承担“停止旧服务之后的替换、验证和回滚”，旧 agentd 退出时可能一起终止调用链。`--no-wait` 会先完成 launchd 交接并返回，然后延迟两秒再替换，适合人不在 Mac 前时从 iPad 发起。

新进程进入 `serve` 后，会在启动其他运行时组件前发起异步文件权限预检：读取每个 project、`scan_roots`、`browse_roots` 和已配置 Worktree 根的至多一个目录项；如果 `browse_roots` 覆盖当前用户 Home，还会分别探测 `~/Desktop`、`~/Documents`、`~/Downloads`。这会把相应的 macOS“文件与文件夹”提示提前到重启阶段，而不是等到第一个真实任务访问该路径时才出现。预检不递归遍历、不读取文件正文、不创建测试文件。

预检故意不阻塞 HTTP 服务启动。系统权限对话框可能一直等待本机点击，如果为此阻断 readyz，远程重启会被误判失败并回滚，反而让无人值守恢复更困难。预检进行中或发现不可访问目录时，`file-access-preflight` 以 warning 出现在 `agentd status --json` / Doctor，并把具体路径写入 `agentd logs`；它不会掩盖 Token、Codex upstream 等真正的服务错误。

“当前用户目录”不是 macOS TCC 的单一授权边界。[Apple 的“文件与文件夹”说明](https://support.apple.com/guide/mac-help/mchld5a35146/mac)明确将 Desktop、Documents、Downloads 作为分别管理的位置；Home 顶层可读不代表这些目录已获授权。[Apple 的“隐私与安全性”说明](https://support.apple.com/guide/mac-help/mchl211c911f/mac)则把 Mail、Messages、Safari、Time Machine 等其他 App 数据归入“完全磁盘访问”的范围。因此：

- 只处理普通项目：在首次启动时分别允许系统弹出的 Desktop、Documents、Downloads 权限即可；
- 需要人不在电脑前也能访问整个 Home 或其他 App 数据：在“系统设置 → 隐私与安全性 → 完全磁盘访问”中添加稳定签名的 `/opt/homebrew/opt/mimi-remote/bin/agentd`；
- 不能通过程序自动点击或绕过这个设置，也不应使用 `tccutil reset` 作为重启步骤，它会清除已有授权。

可直接打开对应设置页，然后点击 `+`；文件选择器中按 `Command-Shift-G` 输入上述绝对路径：

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

第一次从历史 ad-hoc 二进制切换到 `Apple Development` 身份时，新身份不满足旧的 cdhash requirement，macOS 可能仍要求最后一次人工确认。完成这次迁移后，只要继续使用同一开发证书和 identifier，后续重新编译与重启即可复用授权。更换开发团队、证书或 identifier 会形成新身份，需要重新授权，这是预期的安全边界。

Doctor 的 `macos-code-signing` 项会识别 cdhash-only 构建；服务端 Doctor 和 `agentd status --json` 的 `file-access-preflight` 会显示本次启动预检结果。两项都以 warning 报告，不会让仍可连接的健康服务变成不可用。不要用全局关闭 Codex/Claude 审批或 `CLAUDE_BRIDGE_BYPASS_PERMISSIONS=true` 代替系统签名；两者属于不同权限层，后者会扩大远程执行风险。

如果就绪检查失败：

```bash
agentd doctor --fix
agentd logs
```

`doctor --fix` 只执行可证明安全的局部修复；不会为了“修好”而重建项目列表或轮换外侧配对 Token。

从历史产品目录升级时，如果新版默认配置不存在，`agentd` 会把 `codex-ipad-agent/config.json` 原样复制到 `mimi-remote/config.json`，保留旧文件和其中引用的绝对路径。两边都存在时永远使用新版目录；显式自定义配置时不自动迁移。

### 停止与异常恢复

后台服务由系统服务管理器负责，不额外维护容易失真的 PID 文件：

- Mimi Remote Mac owner：从菜单栏选择“退出并停止服务”。
- Homebrew owner：执行 `agentd stop`。
- Linux owner：执行 `"$HOME/.local/bin/agentd" stop`。

```bash
agentd stop
```

`agentd stop` 不读取 Token、不等待 ready，只把停止动作交给当前平台服务管理器。若 `agentd` 命令本身不可用，再使用底层命令排障：

```bash
# macOS
brew services stop mimi-remote

# Linux
systemctl --user stop mimi-remote.service
```

收到停止信号后，`agentd` 会先关闭 HTTP listener，最多等待 5 秒让普通请求完成，再关闭自己的会话资源。macOS/Linux 会关闭每条连接对应的 SSH proxy，但保留共享 Unix App Server。Windows 会停止自己管理的 loopback App Server 完整子进程树。App Server 或 transport 异常时，`/api/readyz` 和 `agentd status --json` 会报告不可用；`/healthz` 仍只表示 HTTP 进程存活。

### macOS Homebrew 应急回滚

先查看 Homebrew Cellar 是否还保留旧版本：

```bash
cellar="$(brew --cellar mimi-remote)"
find "$cellar" -maxdepth 2 -type f -path '*/bin/agentd' -print
```

如果旧 keg 仍在，先停止新服务并以前台方式恢复访问：

```bash
old_version="<上一版本，例如 0.1.0>"
config="$HOME/Library/Application Support/mimi-remote/config.json"

brew services stop mimi-remote
"$(brew --cellar mimi-remote)/$old_version/bin/agentd" version
"$(brew --cellar mimi-remote)/$old_version/bin/agentd" serve --config "$config"
```

该命令占用当前终端，但恢复路径最短，也不会改写配置。确认旧版本可用后，如果需要恢复后台服务，再从 tap 的历史 commit 安装上一版 Formula：

```bash
formula_commit="<homebrew-tap 中上一版 Formula 的 commit SHA>"
formula_dir="$(mktemp -d -t mimi-remote-formula)"
formula_file="$formula_dir/mimi-remote.rb"

curl -fsSL \
  "https://raw.githubusercontent.com/gaixianggeng/homebrew-tap/$formula_commit/Formula/mimi-remote.rb" \
  -o "$formula_file"

brew services stop mimi-remote || true
brew uninstall mimi-remote
brew install --formula "$formula_file"
agentd start
agentd status
rm -f "$formula_file"
rmdir "$formula_dir"
```

只有确认新版本改写了不兼容配置时，才从备份恢复 `config.json`。共享 SSH 模式不生成 App Server WebSocket Token。恢复前必须先停止服务，恢复后保持文件权限为 `0600`：

```bash
brew services stop mimi-remote
install -m 600 "<备份目录>/config.json" "$HOME/Library/Application Support/mimi-remote/config.json"
agentd start
```

### Linux user-systemd

Linux Release 包同时包含二进制、user-systemd 模板和安装脚本，不使用 Homebrew。下面示例明确指定版本，校验 `checksums.txt` 后再安装，避免“latest”在无人确认时升级：

```bash
set -euo pipefail

version="v0.1.0"
release_version="${version#v}"
case "$(uname -m)" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "不支持的架构：$(uname -m)" >&2; exit 1 ;;
esac

archive="mimi-remote_${release_version}_linux_${arch}.tar.gz"
work_dir="$(mktemp -d)"
cd "$work_dir"

curl --fail --location --remote-name \
  "https://github.com/gaixianggeng/mimi-remote/releases/download/${version}/${archive}"
curl --fail --location --remote-name \
  "https://github.com/gaixianggeng/mimi-remote/releases/download/${version}/checksums.txt"

awk -v archive="$archive" '$2 == archive { print }' checksums.txt | sha256sum -c -
tar -xzf "$archive"
ssh 127.0.0.1 codex --version
AGENTD_APP_SERVER_SSH_TARGET=127.0.0.1 bash ./scripts/install-linux.sh install
```

先配置本机 sshd、host key 和非交互密钥认证。安装脚本会在替换二进制或 unit 前，用候选版本完成 SSH、Codex 版本和真实 `initialize` 预检。首次 setup 会把环境变量中的目标持久化到配置；systemd unit 不需要继承该环境变量。

脚本只接受正式版本号，拒绝 `devel`、错误架构、root、非默认 `AGENTD_CONFIG` 和不一致的 `XDG_CONFIG_HOME`。它会：

- 原子安装 `~/.local/bin/agentd` 和 user-systemd unit；
- 首次安装时静默创建默认配置，已有配置和 Token 不会被覆盖；服务真正就绪且安装事务提交后，才输出不含长期 Token/connect link 的短期配对二维码；
- 升级前保存 `agentd.previous` 和上一版 unit；
- 显式重启已经运行的旧进程，并等待服务健康；
- 任一步骤、服务健康或 Doctor 必要检查在 10 秒内失败时，先输出最多 40 行去敏状态摘要和 80 行去敏 journal，再自动恢复安装前二进制、unit 和服务状态；首次 setup 已安全生成的配置与 Token 会保留，不会因服务失败再次轮换；
- 若安装后的二维码生成失败，只提示使用绝对路径重试 `pair --qr-only`，不会回滚已经就绪的服务。

安装器不会修改 `.bashrc`、`.zshrc` 等 shell 配置。若成功输出提示当前 `PATH` 没有 `~/.local/bin`，可在当前 shell 执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

安装后的日常配对、状态、日志和重启统一使用 agentd CLI。下面刻意使用绝对路径，当前 shell 尚未刷新 PATH 时也能直接执行：

```bash
"$HOME/.local/bin/agentd" pair --qr-only
"$HOME/.local/bin/agentd" status
"$HOME/.local/bin/agentd" logs -n 200
"$HOME/.local/bin/agentd" logs -n 200 -f
"$HOME/.local/bin/agentd" restart
"$HOME/.local/bin/agentd" stop
```

`pair --qr-only` 只输出 Endpoint、短期 Pair 链接、过期时间和二维码，适合安装器或可能留存日志的终端；普通 `pair` 继续保留长期 Token/connect link，作为扫码不可用时的手动 fallback。其余命令在 Linux 只做一层薄映射，实际仍由 `systemctl --user` 和 `journalctl --user` 管理；不会额外创建 PID 文件或自建守护进程。`logs -n` 的正数范围固定为 1 到 5000，`0` 或负数使用默认 120 行，超限直接报错；`-f` 仍可与合法行数组合。unit 缺失时 CLI 会明确提示先从正式 Release 解压目录运行 `bash ./scripts/install-linux.sh install`。需要绕过 CLI 排查 systemd 本身时，仍可直接运行 `systemctl --user status mimi-remote.service`。

若希望退出 SSH 登录后服务仍运行，需要由当前机器管理员明确开启 user lingering：

```bash
sudo loginctl enable-linger "$USER"
```

Linux 升级时，按首次安装示例下载并校验目标版本，解压后在新目录执行：

```bash
bash ./scripts/install-linux.sh upgrade
```

脚本会自动保留上一版二进制和 unit；若新版本无法就绪会当场自动恢复。需要稍后主动回滚时，使用安装成功后保存到本机的脚本：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback
"$HOME/.local/bin/agentd" logs -n 200
```

如果 Codex CLI 不在模板的 `PATH` 中，先用 `command -v codex` 找到安装目录，再编辑 `~/.config/systemd/user/mimi-remote.service` 的 `Environment=PATH=...`，随后执行 `systemctl --user daemon-reload` 和重启。

### Linux 卸载

安装成功后的 helper 会安全停止并禁用 user-systemd service，再删除当前/上一版二进制、unit 和 helper 自身：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" uninstall
```

`uninstall` 不接受 `sudo`，也不提供隐式 purge。如果已安装的 unit 无法停止或禁用，脚本会在删除任何安装文件前中止。成功后 helper 会随安装文件一起删除；需要再次确认状态时，可从原 Release 解压目录运行 `bash ./scripts/install-linux.sh uninstall`，无剩余安装文件时会幂等成功。

为了让后续重装无需重新配对，脚本会完整保留 `~/.config/mimi-remote` 及其中的 Token。只有在确认不再使用且接受原配对凭据永久失效时，才手动删除：

```bash
rm -rf -- "$HOME/.config/mimi-remote"
```

## 风险与优化

### 维护者发布前本地验收

正式 tag 依赖 GitHub、Homebrew Tap 和 Apple Developer 三组外部资源：canonical 主仓库必须是 PUBLIC 的 `gaixianggeng/mimi-remote`，`gaixianggeng/homebrew-tap` 也必须是 PUBLIC，并且主仓库 Secret `TAP_DEPLOY_KEY` 对应的公钥必须作为可写 Deploy Key 安装在 Tap。仓库删除与改名是独立于代码合并的短维护窗口人工操作，具体顺序见[中文仓库改名 runbook](operations/github-repository-rename-runbook.zh-CN.md)。Deploy Key 只授权这一个仓库，避免把维护者账号的广域 PAT 放进公开仓库 Actions。

正式发布只接受官方仓库的 `vX.Y.Z` tag，而且 tag 指向的 commit 必须已经进入当前 `origin/main`。为避免非 main tag 携带并执行它自己的高权限 workflow，单纯 push tag 不再触发正式发布；维护者通过 `repository_dispatch:release` 传入 tag，GitHub 固定从默认分支加载 workflow。workflow 会先 checkout 受信的 main SHA 并运行不读取任何 Secret 的 `source-trust` job，确认 checker 自身、workflow SHA 和当前 `origin/main` 一致，再用 `git merge-base --is-ancestor` 验证目标 tag 来源；后续 macOS 发布和 Windows 安装器兼容性验证都依赖该结果并绑定只允许 `main` 的 `production-release` Environment。仓库 ruleset 另外禁止删除或改写 `v*` tag；部分失败只允许在同一个 tag、同一个 commit 上重跑。

macOS 产物还必须配置以下 GitHub Actions Secrets：

| Secret | 内容 | 权限边界 |
| --- | --- | --- |
| `MACOS_SIGN_P12` | `Developer ID Application` 证书与私钥导出的 PKCS#12，再整体 base64 | 用于签名 agentd Darwin 二进制、Mac App 和 DMG |
| `MACOS_SIGN_PASSWORD` | PKCS#12 导出密码 | 不写文件、不输出日志 |
| `MACOS_NOTARY_KEY` | App Store Connect API `.p8` 私钥的 base64 | 只用于 Apple notarization |
| `MACOS_NOTARY_KEY_ID` | 10 位 API Key ID | 与 `.p8` 配套 |
| `MACOS_NOTARY_ISSUER_ID` | App Store Connect Issuer UUID | 与 `.p8` 配套 |

Windows 安装器可选配置以下 Authenticode Secrets：

| Secret | 内容 | 权限边界 |
| --- | --- | --- |
| `WINDOWS_SIGN_PFX` | Windows 代码签名证书与私钥导出的 PFX，再整体 base64 | 只用于签名两份 `.exe` 和最终安装器 |
| `WINDOWS_SIGN_PFX_PASSWORD` | PFX 导出密码 | 只在 Windows release job 的临时文件生命周期内使用 |

Windows verify job 会构建 release 二进制、编译 Inno Setup，并验证 SHA-256、内嵌文件和签名模式。验证通过后，独立的 `publish-windows` job 把安装器、摘要和元数据上传到同一个 GitHub Release。PFX 临时文件不会进入 artifact。两个 Secret 都存在时强制验证 Authenticode；两个都缺失时构建明确标记的 `unsigned-release`。

Release 的 verify job 会在构建前解码到临时 `0700` 目录，确认 PKCS#12 确实包含 `Developer ID Application` 证书、密码可解密、`.p8` 是有效 PKCS#8 私钥，并校验 Key ID/Issuer 格式；不会打印证书正文或私钥。正式 job 会先生成并公证 universal Mac DMG，再由 GoReleaser 按“构建 Darwin 二进制 → Developer ID 签名 → Apple notarization → 归档 → checksum/Formula”顺序发布后端，最后把已经通过 Gatekeeper 校验的 DMG 和 SHA-256 上传到同一 GitHub Release。普通 snapshot 不读取 Apple 私钥。

发布后的产物门禁会从两个 Darwin 归档重新解包 `agentd`，执行 `codesign --verify --strict`，并要求存在 `Developer ID Application` Authority、TeamIdentifier、identifier + certificate anchor 形式的稳定 designated requirement，同时拒绝 cdhash-only 身份。Mac DMG 会另外验证 `arm64/x86_64` 双架构、内嵌 `agentd`、LaunchAgent、Applications 拖放入口、Developer ID、notarization ticket 和 Gatekeeper 结果。任一步失败都会让 tag workflow 失败，不能把未签名或未公证产物视为成功 Release。

Release workflow 会在 GoReleaser 前读取 GitHub API JSON，检查两个仓库的 `visibility=public` / `private=false`，再使用 Deploy Key 对 Tap `main` 执行 dry-run push 验证写权限，不在日志中回显私钥或 API JSON 原文。如果只需在本地验证 JSON 分支而不连接 GitHub，执行：

```bash
bash ./scripts/check-release-prerequisites.sh --self-test
bash ./scripts/check-macos-release-signing.sh --self-test
bash ./scripts/restart-agentd-dev-macos.sh --self-test
```

维护者在打 tag 前从仓库根目录执行：

```bash
bash ./scripts/verify-release.sh
```

校验通过后创建并推送 tag，再发送只能从默认分支加载 workflow 的 Release 事件：

```bash
release_tag="v0.3.1"
git tag "$release_tag"
git push origin "$release_tag"
gh api --method POST \
  repos/gaixianggeng/mimi-remote/dispatches \
  -f event_type=release \
  -f "client_payload[release_tag]=$release_tag"
```

该入口固定校验 GoReleaser `v2.15.3` 官方预编译包的 SHA-256，并拒绝当前 Go 版本偏离 `go.mod`。它会验证四个平台二进制的 Go 版本、GOOS/GOARCH、CGO 状态、可执行权限、许可证文件、systemd 模板和 Homebrew service；还会逐一核对 Formula 下载 URL 必须指向 `gaixianggeng/mimi-remote`，其中 SHA-256 必须与实际归档一致。普通安装用户不需要运行这个脚本。

### GitHub Release 成功、tap 更新失败

GoReleaser 发布 GitHub 附件和推送 Homebrew tap 不是跨仓库事务。若 workflow 已创建 Release，但在 tap 阶段因 Deploy Key、仓库权限或临时网络错误失败：

1. 不要移动或重建同名 tag，也不要先手工删除已经公开的 Release；
2. 修复 `TAP_DEPLOY_KEY`、Tap 的 Deploy Key 写权限或仓库状态；
3. 在原 workflow 上执行 **Re-run failed jobs**；
4. `.goreleaser.yml` 的 `mode: keep-existing` 会保留原发布说明，`replace_existing_artifacts: true` 允许同一 tag 重建并替换同名附件，然后继续推送 Formula；
5. 重跑成功后确认 Release 包含四个平台归档和 `checksums.txt`，tap 的 Formula URL、版本和 SHA-256 与该 Release 一致。

该恢复能力只服务于“同一个 tag、同一个提交”的部分失败。若 tag 指向发生变化，必须停止重跑并先调查；不能用附件替换掩盖 retag。

- Homebrew Formula 回滚依赖 tap 历史 commit 和旧 Release 附件仍可访问；每次正式发布必须保留 tag、附件和 Formula 历史。
- 配置备份包含长期凭据，默认仅保存在本机 `0700` 目录内；不用 Git 管理，不通过聊天发送。
- Linux user service 会以当前用户权限访问项目目录和 Codex 配置；不要改成 root system service。
- 当前没有自动数据库迁移或跨版本降级框架。配置变更继续保持向后兼容；真的出现不兼容格式时，再引入带版本号的迁移，不提前建设复杂升级系统。
