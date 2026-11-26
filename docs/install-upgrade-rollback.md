# 安装、升级与回滚

## 目标

桌面端可先在离线电脑安装和启动，升级沿用已有配对凭据。首次连接时再准备一个可用助手和一种手机可达的通道。四种助手的配置与图形入口见[快速入门](quickstart.md)。

## 方案

- macOS 普通用户使用已签名并公证的 DMG；Mac App 内嵌 `agentd`，不要求安装 Homebrew。
- Windows 普通用户使用按用户 EXE 安装器；后台由当前用户计划任务托管，Codex App Server 只监听本机 loopback WebSocket。
- Linux 使用发布包中的 user-systemd 模板；`agentd` 默认连接 Codex 标准 Unix control socket，与本机终端共享 resident，不要求 SSH。
- Homebrew 保留给命令行、服务器、自动化和故障恢复场景。
- 配置和移动端配对 Token 都留在系统用户配置目录，升级二进制不会删除它们。
- 回滚先恢复可用性：优先运行旧 keg 或旧 Release 二进制，再决定是否回滚 Homebrew Formula。

## 实现

### Windows 首次安装、升级与回滚

Windows 安装要求 Windows 10/11 x64 和当前桌面用户权限。选择 Codex 时再安装并登录受支持的 CLI。Windows 的 Codex App Server 由 agentd 管理，通过本机 loopback WebSocket 通信。

从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 下载同版本的 `Mimi-Remote-Setup-*.exe`、`.sha256` 和 `.metadata.json`。在 PowerShell 中验证摘要和签名状态：

```powershell
$setup = Get-Item .\Mimi-Remote-Setup-*.exe
(Get-FileHash $setup -Algorithm SHA256).Hash
(Get-AuthenticodeSignature $setup).Status
```

摘要必须与 `.sha256` 一致。元数据为 `authenticode-pfx` 时，签名状态必须为 `Valid`；元数据为 `unsigned-release` 时，状态应为 `NotSigned`，Windows 可能显示 Microsoft Defender SmartScreen 警告。

安装器按用户安装到 `%LOCALAPPDATA%\Programs\Mimi Remote`。它回读当前用户计划任务的 SID、Limited 权限及唯一的无窗口宿主动作，然后在一次启动操作中等待经鉴权的核心服务就绪。首次安装时可选择一个现有目录，同时授予扫描和浏览权限。跳过确认或静默新装会保存待确认状态并阻止配对。覆盖安装沿用原 Token、目录授权和确认状态。配置位于 `%APPDATA%\mimi-remote`，日志位于 `%LOCALAPPDATA%\Mimi Remote\logs`。

Windows 防火墙规则和 LAN 监听默认不启用。用户确认工作区并明确选择 LAN 访问后，签名安装器会检查网络是否为“专用网络”。获准后，它创建限于 Private profile 和 `LocalSubnet` 的规则。

公共网络、规则过宽或未获管理员授权时，安装器关闭应用的 LAN 入口，保留环回和其他已配置的通道。它只清理当前用户由本版安装器创建的规则。旧规则或其他软件创建的规则请在 Windows 防火墙中核对归属。静默安装不会请求 UAC。也可在 Tailscale 已就绪后启用它，再重启一次：

```powershell
& "$env:LOCALAPPDATA\Programs\Mimi Remote\agentd.exe" network --tailscale-enabled=true
& "$env:LOCALAPPDATA\Programs\Mimi Remote\agentd.exe" restart --no-pair --wait 30s
```

安装包还内置与 agentd 同版本的实验性 Tailcat 辅助程序 `mimi-tailcat-experiment.exe`，默认关闭。没装 Tailscale、也没开 LAN（例如处在 Public 网络）时，在托盘控制面板点“开启 Tailcat”，或在托盘菜单选“开启 Tailcat…”。确认后 agentd 启动辅助程序，托盘以 agentd 回读的运行状态为准。随后在“配对设备”中点“用 Tailcat”生成 Tailcat 二维码；Tailscale 和局域网都没有开启或不可用时，会直接显示 Tailcat 二维码。Tailcat 只发起出站连接，不新增防火墙规则：能直连时点对点，否则经 DERP 中继转发，默认中继由 Tailscale 运营。

辅助程序的身份、已配对设备和本机控制通道 `control.sock` 保存在 `%APPDATA%\mimi-remote\tailcat`，由用户配置文件的 ACL 保护；控制通道使用 Windows 10 1803 起内置的 AF_UNIX socket。agentd 停止或重启时，通过控制通道让辅助程序正常退出。计划任务和辅助程序各自的 kill-on-close Job Object 负责兜底，agentd 异常退出也不会留下进程。升级和卸载前，安装器会等待辅助程序退出，必要时强制结束。`agentd doctor` 的 `tailcat` 项报告辅助程序是否存在及其版本，缺失时重新运行同版本安装器。关闭 Tailcat 会断开正在使用它的设备，不影响 Tailscale 和 LAN 连接。

电脑通过 Windows 系统代理上网时（“设置 → 网络和 Internet → 代理”，本机代理软件开启“系统代理”后也写在这里），Codex 与 Claude 适配器不会自己读取这项设置（#884）。所以 agentd 启动时，会在 `127.0.0.1` 上开一个带随机凭据的本机中转，并把它作为 `HTTPS_PROXY` / `HTTP_PROXY` 交给这两个子进程；本机地址经 `NO_PROXY` 保持直连。中转在每个连接建立时读取当时的系统代理：支持不需要认证的手动代理及其例外列表，也支持代理自动配置脚本（PAC）；系统代理关闭时直连。因此代理软件晚于 agentd 启动，或中途开关系统代理，都无需重启服务。不使用“自动检测设置”（WPAD）。本机中转不处理上游代理返回的 407 认证挑战，因此不支持需要 NTLM、Negotiate 或其他挑战认证的上游代理；这类环境应在 `codex.env` 或 `claude.env` 中配置可直接使用的代理。`agentd doctor` 的 `windows-system-proxy` 项会分别说明 Codex 与 Claude 的当前联网方式，不显示代理地址。如果在 agentd 配置的 `codex.env`、`claude.env` 中自行设置了 `HTTPS_PROXY`、`HTTP_PROXY`、`ALL_PROXY` 或 `NO_PROXY`，agentd 以这些设置为准，不再使用中转；想让它们始终直连，就设置 `"NO_PROXY": "*"`。

常用命令：

```powershell
$agentd = "$env:LOCALAPPDATA\Programs\Mimi Remote\agentd.exe"
& $agentd status
& $agentd pair --qr-only
& $agentd doctor --fix
& $agentd logs -n 200
& $agentd restart --no-pair --wait 30s
& $agentd tailcat status
& $agentd tailcat enable
& $agentd tailcat pair --qr-only
& $agentd tailcat disable
```

升级时直接覆盖安装新版本。回滚时重新运行上一版来自正式 Release 且摘要匹配的安装器。不要先删除 `%APPDATA%\mimi-remote`。卸载会停止并删除计划任务、移除程序文件，并保留配置、Token 与日志。交互式卸载获管理员授权后才移除可选防火墙规则。静默卸载或拒绝授权后可在 Windows 防火墙中核对残留规则的程序路径和归属。

#### Windows 托盘与 App 的维护调用约定

- 正式签名发行版的 UI 使用已验证发布者、已绑定到当前安装版本的 `agentd.exe`，按参数数组调用 `installer-maintenance modify`。使用普通桌面用户权限，等待退出后重新读取 `status --json` 的 `workspace_confirmed` 和 LAN 状态。已有授权的用户无需再选一次目录。
- 桌面端从受信安装位置读取 `maintenance-identity.p7m`。这是带内容的 CMS SignedData，UTF-8 JSON 的 schema 为 `mimi.windows.maintenance/v1`。用发布渠道预置信任的代码签名发布者验证唯一签名人和证书链，再核对预期安装版本 `version`、固定角色名 `broker=agentd.exe` 与 `maintenance=Mimi-Remote-Maintenance.exe`。`broker_sha256` 和 `maintenance_sha256` 均指完整签名文件。启动代理前，用同一打开文件校验 Authenticode 和摘要，固定路径各级目录与映像直至启动完成。旧签名收据、可写元数据及任意系统信任的其他发布者均不能替代这些校验。
- 安装器构建先签名独立的 `Mimi-Remote-Maintenance.exe`，再把完整文件的 SHA-256 编入同版签名 agentd。代理只从自身安装目录打开这个固定文件，核对摘要并在同一文件句柄上通过 Windows Authenticode 验证。校验到维护结束期间固定目录和映像，拒绝重解析点。卸载程序、注册表命令、下载目录和 PATH 均不参与选择。调用方须先验证代理本身的可信身份。
- Modify 的目录确认和核心服务操作以普通用户运行。仅修改防火墙时，代理再次验证同一维护映像，并向 UAC 提交固定动作。提升权限的程序从实际安装目录读取签名收据，核对发布者、版本和两个固定映像的摘要后，只为该目录的 agentd 管理 Private/LocalSubnet 规则。标准用户可在 UAC 中使用管理员凭据。
- 无签名构建、维护程序缺失、身份校验失败或旧桌面端缺少可信代理入口时，显示下载正式安装包的指引。UI 不执行安装路径、注册表或诊断信息中的命令。恢复入口为[桌面端正式下载](https://github.com/gaixianggeng/mimi-remote/releases/latest)。

### macOS 首次安装（推荐）

macOS 安装要求 macOS 15 或更高版本。有安装包即可先配置桌面端。使用 Codex 桌面共享时才需要额外设置，见[共享 App Server](shared-ssh-app-server.md)。

从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 下载 `Mimi-Remote-Mac.dmg` 和 `Mimi-Remote-Mac.dmg.sha256`，在同一目录执行 `shasum -a 256 -c Mimi-Remote-Mac.dmg.sha256`。校验通过后打开 DMG，将 **Mimi Remote Mac** 拖入“应用程序”并打开。首次打开会自动弹出设置窗口：选好代码文件夹并保存。服务、助手与通道就绪后，用移动端 App（主屏上叫 mimi）扫描新生成的二维码。之后要再次显示二维码，点菜单栏的 Mimi Remote 图标，选“配对设备…”。安装包内已包含 `agentd`、默认使用的 Claude 适配器 `mimi-claude-adapter`、回退用的 `alleycat-claude-bridge`，以及实验性 Tailcat 辅助程序 `mimi-tailcat-experiment`（默认关闭）。

检测到旧 `homebrew.mxcl.mimi-remote` 时，不要先手工停服。让 Mac App 执行接管：它会先跑 Doctor，停止 Homebrew service，注册内嵌 LaunchAgent 并等待就绪；失败时尝试恢复旧 Homebrew 服务。迁移保留 Application Support 中的配置、Token 和配对关系。

### macOS 命令行安装（高级）

```bash
brew update
brew install gaixianggeng/tap/mimi-remote

agentd up --no-pair
agentd status
```

`agentd status --json` 中，`service_ok` 表示已核验当前后台服务的归属、版本与鉴权就绪。助手的版本、登录状态和手机连接通道在配对前另行检查。

首次执行 `agentd up --no-pair` 会保存用户私有配置并启动 Homebrew 后台服务。请先准备代码目录（默认 `~/code`），或使用桌面向导选择目录。默认配置仅允许本机访问，之后可开启所需通道。重复运行会沿用现有身份。

Agent 或自动化首次安装必须使用安全模式，初始化与启动逻辑不变，但不输出二维码、Endpoint 或长期访问码：

```bash
agentd up --no-pair
agentd up --no-pair --json
```

JSON 安全模式只返回 `version`、`service_ok` 和可选的安全 warning，不包含带 Token 的完整 setup `result`。需要配对时由用户在不会进入远程任务日志的本机终端执行 `agentd pair --qr-only`。

### macOS App 升级与回滚

首个 DMG 不带自动更新。升级时下载目标正式版本的 DMG 和 SHA-256 文件，校验后用新 App 覆盖“应用程序”中的现有版本；不要先删除旧 App，也不要删除 `~/Library/Application Support/mimi-remote`。打开新版本后确认 service owner 仍是 `Mimi Remote Mac`，版本及核心服务就绪，随后检查自己启用的助手。前门会按包内 agentd 二进制摘要判断是否换代；有活动共享连接或任务时会暂缓，结束任务并断开 Desktop SSH 页面后重启 App 服务即可再次尝试，不强制中断 backend。

需要回滚时安装上一个仍可从正式 Release 获取、经过 Developer ID 签名和 Apple 公证的 DMG。优先只回滚 App 和内嵌二进制；除非确认新版本写入了旧版本无法读取的配置，否则继续复用现有配置。若要回到不支持 Codex 前门的旧版，先按[共享 App Server](shared-ssh-app-server.md#macos-mac-app-前门)卸载前门并安全结束私有 backend，再替换 App。snapshot、ad-hoc 或未公证构建不能作为稳定回滚版本。

永久移动或删除 App 前，先在菜单栏执行“退出并停止服务”，再用当前 App 内的 `agentd codex-front uninstall --stop-idle-backend` 安全卸载前门；命令失败时先结束共享任务和 Desktop SSH 页面，不要直接删除 App。如果要回到 Homebrew，在设置中执行“停止 App 服务并恢复 Homebrew”：App 会先确认私有 backend 空闲并卸载前门，失败则恢复 App 服务；确认 Homebrew 就绪后再移除 App。

### Claude 通道切回旧 bridge

Mac App 与 Windows 安装包默认使用随包的 Claude 适配器（#660）。只是 Claude 通道在新版本里出问题时，不必回滚整个安装包，可以先切回随包的旧 Rust bridge：

1. 在 agentd 配置（macOS `~/Library/Application Support/mimi-remote/config.json`，Windows `%APPDATA%\mimi-remote\config.json`）的 `claude` 段加上 `"legacy_bridge": true`，保持文件权限 `0600`。
2. 重启服务：Mac App 用菜单栏重启服务；命令行运行 `agentd restart`。
3. 运行 `agentd doctor`，`claude-bridge` 一项应显示旧 bridge 的版本。

删除这一项或改为 `false` 并重启即恢复默认。命令行运行的 agentd 也可以用环境变量 `AGENTD_CLAUDE_LEGACY_BRIDGE=1`。这个开关保留一个版本周期，之后旧 bridge 从安装包中移除。适配器要求 Claude Code 2.1.294 或更新版本，过旧时先在终端运行 `claude update`，不需要切回旧 bridge。

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

授权记在谁名下取决于安装方式。Mac App 安装版的 LaunchAgent 启动的是主 App 的 `--agentd-supervisor` 模式，由它拉起包内 agentd 并常驻等待，所以 agentd、它启动的 Codex resident 和 Claude bridge 都沿责任链使用 **Mimi Remote Mac** 的授权；系统弹窗和设置列表里显示的也是 Mimi Remote Mac。Homebrew 版没有 App 外壳，授权主体仍是 agentd 本身。

- 只处理普通项目：在首次启动时分别允许系统弹出的 Desktop、Documents、Downloads 权限即可；
- 预览会话里从“照片”拖入的图片：照片图库（`.photoslibrary`）不属于“文件与文件夹”。Mac App 安装版在菜单栏 App 的“设置 → 文件访问”中点“允许访问照片”，之前拒绝过则点“打开照片隐私设置”开启 Mimi Remote Mac；Homebrew 版只能在“完全磁盘访问”中添加 `/opt/homebrew/opt/mimi-remote/bin/agentd`；
- 需要人不在电脑前也能访问整个 Home 或其他 App 数据：在“系统设置 → 隐私与安全性 → 完全磁盘访问”中添加 Mimi Remote Mac（Homebrew 版添加 `/opt/homebrew/opt/mimi-remote/bin/agentd`）。从旧版本升级到 supervisor 版本后，之前授予裸 agentd 的完全磁盘访问不再生效，需要改为授予 Mimi Remote Mac；
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

### 旧安装包读到新配置时先升级安装包

配置由较新版本写入、实际运行的却是较旧安装包时，`agentd` 可能既认不出其中的取值，也不再支持对应的迁移。典型现象是 Mac App 报“后台服务首次启动失败 / 自动重新登记仍未恢复”，而 launchd 每 3 秒重拉一次、每次都立刻以退出码 1 结束：登记本身没有坏，换多少次登记都不会变。

先用一次只读检查拿到 agentd 自己的判断：

```bash
agentd check-config --json
```

`code=config_requires_newer_version` 表示这份配置需要更新版本的 `agentd`，对应动作是安装最新发布包，而不是 `setup --force`：后者会重建配置并轮换配对 Token。反过来，已经移除的历史 transport（例如 `stdio`）会报 `config_invalid`：最新的 `agentd` 同样不支持它，升级安装包修不好，只能 `setup --force` 重置配置；其余 `config_invalid` 回到 `doctor --fix` 与 `agentd logs`。Mac App 在检测到拉起失败循环时会自动运行同一检查，并把 agentd 的原始报错和对应的下一步显示出来，不再只提示“服务记录可能已过期”。

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

收到停止信号后，`agentd` 会先关闭 HTTP listener，最多等待 5 秒让普通请求完成，再关闭自己的会话资源。macOS 和 Linux 显式远端模式会关闭每条连接对应的 SSH proxy，但保留共享 Unix App Server；Windows 与 Linux 默认模式会停止自己管理的 loopback App Server 子进程。核心服务与各助手独立报告就绪情况，Codex 运行时异常可以在助手诊断中查看；`/healthz` 仍只表示 HTTP 进程存活。

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

只有确认新版本改写了不兼容配置时，才从备份恢复 `config.json`。共享本机 socket 与 SSH 模式都不生成 App Server WebSocket Token。恢复前必须先停止服务，恢复后保持文件权限为 `0600`：

```bash
brew services stop mimi-remote
install -m 600 "<备份目录>/config.json" "$HOME/Library/Application Support/mimi-remote/config.json"
agentd start
```

### Linux user-systemd

Linux 桌面安装同时提供顶栏托盘、自启动入口和本机管理面板，使用方法与 GNOME/KDE/Waybar 支持边界见 [Linux 桌面托盘](linux-tray.md)。

Linux Release 包同时包含 agentd、同版本的 Tailcat 辅助程序、托盘、user-systemd 模板和安装脚本，不使用 Homebrew。下面示例明确指定版本，校验 `checksums.txt` 后再安装，避免“latest”在无人确认时升级：

```bash
set -euo pipefail

read -r -p "输入要安装的正式版本标签（含 v）：" version
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
bash ./scripts/install-linux.sh install
```

可以在另一台机器上下载对应架构的归档及校验文件，复制到离线电脑后就地校验、解压并安装。安装器用临时 HOME 和临时代码目录运行只读预检，无需访问 Codex 或登录任何助手。选择本机 Codex 时，它可以使用该用户的 Unix control socket。

若确实要把 Codex 放到另一台 SSH 主机，可显式执行 `AGENTD_APP_SERVER_SSH_TARGET=user@host bash ./scripts/install-linux.sh install`。实际使用远端 Codex 时，请配置 host key 和非交互密钥认证；安装器仍不会修改 `authorized_keys` 或放宽 sshd。首次 setup 会把目标持久化到配置，systemd unit 不需要继承该环境变量。

脚本只接受正式版本号，拒绝 `devel`、错误架构、root、非默认 `AGENTD_CONFIG` 和不一致的 `XDG_CONFIG_HOME`。它会：

- 暂存并核对 agentd、同版本 Tailcat 辅助程序和 user-systemd unit。
- 首次安装时静默保存一次配置，扫描和浏览均限定为 `~/code`。升级保留配置、Token 和可回滚的上一版文件。
- 对已运行的服务执行一次重启，首次启动等待本机鉴权和版本核验。可选助手的诊断不会阻塞核心服务。
- 启动失败时输出有界去敏诊断并恢复安装前文件、备份及服务状态。首次保存的身份可用于重试。如果旧版本无法读取配置，停止服务并提示使用兼容版本修复。
- 结束时调用已安装 `agentd status --pairing` 输出当前配对前提与下一步（回滚到不支持该参数的旧版本时自动回退到静态前提说明，不回滚事务、不发起联网）。满足前提后再执行 `agentd pair --qr-only`（或联网启用 Tailcat 后执行 `agentd tailcat pair --qr-only`），或在安装命令后加 `--pair`（安装器会根据当前可用连接方式自动选择直连或 Tailcat 配对）。出码失败可以单独重试。

`mimi-remote.service` 保留 `PrivateTmp=true` 沙箱加固，并由 systemd 托管服务专属 `RuntimeDirectory=mimi-remote`（`0700`、`RuntimeDirectoryPreserve=no`，停止服务后自动清理）与环境变量 `MIMI_SHARED_CODEX_UNSAFE_MARKER=%t/mimi-remote/codex-daemon.unsafe`；同时配置 `ExecStartPre=-+`（在沙箱外先清理暂存路径与旧告警标记，再校验 `/tmp/codex-daemon-%U` 不是符号链接、确为当前用户拥有的目录并收紧权限 `0700`，缺失时自动创建；仅在全部校验通过后才建立 `%t/mimi-remote/codex-daemon` → `/tmp/codex-daemon-%U` 暂存链接；若该路径被占位、属主不符或为符号链接，则清理暂存路径、输出告警日志并写入服务专属 `.unsafe` 标记，不阻断核心服务启动）与 `BindPaths=-%t/mimi-remote/codex-daemon:/tmp/codex-daemon-%U`（暂存链接不存在时 systemd 直接跳过挂载）。同时，`agentd` 在使用本机共享 Codex socket 或执行 `/api/local/preflight` 前也会只读校验服务专属标记（仅受管服务注入，不影响前台进程）、`/tmp/codex-daemon-<uid>` 及 control socket 符号链接目标所在目录：必须是真实目录、非符号链接且属主匹配当前用户，否则仅将本机共享 Codex 标记为不可用并记录清晰日志，不会尝试连接。这是因为 Codex `app-server --listen unix://` 会把 `$CODEX_HOME/app-server-control/app-server-control.sock` 建成指向真实 `/tmp/codex-daemon-<uid>/<hash>` 的符号链接，而独立运行的 resident 与本机终端 `codex --remote unix://` 都工作在真实 `/tmp` 下；通过该组合，agentd 在保留私有 `/tmp` 与核心服务可用性的同时即可安全直连共享 control socket。已安装的 Linux 用户只需执行 `bash ./scripts/install-linux.sh upgrade`，安装器会自动替换 `~/.config/systemd/user/mimi-remote.service` 并重新加载生效。

安装器不会修改 `.bashrc`、`.zshrc` 等 shell 配置。若成功输出提示当前 `PATH` 没有 `~/.local/bin`，可在当前 shell 执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

安装后的日常配对、状态、日志和重启统一使用 agentd CLI。下面刻意使用绝对路径，当前 shell 尚未刷新 PATH 时也能直接执行：

```bash
"$HOME/.local/bin/agentd" status
"$HOME/.local/bin/agentd" status --pairing
"$HOME/.local/bin/agentd" pair --qr-only
"$HOME/.local/bin/agentd" logs -n 200
"$HOME/.local/bin/agentd" logs -n 200 -f
"$HOME/.local/bin/agentd" restart
"$HOME/.local/bin/agentd" stop
```

全新离线安装默认不开启外部连接且不含已登录助手。配对前先用 `agentd status --pairing` 查看当前缺少的助手或连接方式：同一局域网可运行 `agentd network --lan-enabled=true` 后执行 `agentd restart --no-pair`；Tailscale 可运行 `agentd network --tailscale-enabled=true` 后执行 `agentd restart --no-pair`；联网环境也可运行 `agentd tailcat enable` 后用 `agentd tailcat pair` 配对。`agentd start` 与 `agentd restart` 在服务已就绪但可选配对失败时仅输出警告，不会把已成功启停的服务判为失败。

`pair --qr-only` 只输出 Endpoint、短期 Pair 链接、过期时间和二维码，请只在可信的本机终端显示；普通 `pair` 继续保留长期 Token/connect link，作为扫码不可用时的手动 fallback。其余命令在 Linux 只做一层薄映射，实际仍由 `systemctl --user` 和 `journalctl --user` 管理；不会额外创建 PID 文件或自建守护进程。`logs -n` 的正数范围固定为 1 到 5000，`0` 或负数使用默认 120 行，超限直接报错；`-f` 仍可与合法行数组合。unit 缺失时 CLI 会明确提示先从正式 Release 解压目录运行 `bash ./scripts/install-linux.sh install`。需要绕过 CLI 排查 systemd 本身时，仍可直接运行 `systemctl --user status mimi-remote.service`。

若希望退出 SSH 登录后服务仍运行，需要由当前机器管理员明确开启 user lingering：

```bash
sudo loginctl enable-linger "$USER"
```

Linux 升级时，按首次安装示例下载并校验目标版本，解压后在新目录执行：

```bash
bash ./scripts/install-linux.sh upgrade
```

脚本会同时校验并安装 agentd 与 mimi-tailcat-experiment，自动保留上一版两个二进制和 unit；若新版本无法就绪会当场恢复安装前版本及原有回滚备份。缺少辅助程序、无法执行或版本不一致的包会在修改安装前被拒绝。需要稍后主动回滚时，使用安装成功后保存到本机的脚本：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback
"$HOME/.local/bin/agentd" logs -n 200
```

从没有 Tailcat 的旧安装升级时，回滚会恢复当时缺少辅助程序的状态并明确提示。若旧备份没有辅助程序且没有对应的缺失标记，安装器拒绝猜测版本，请从目标版本完整 Release 包重新安装。出现「未安装 mimi-tailcat-experiment」时，下载并校验包含该文件的 Linux Release，在解压目录执行 `bash ./scripts/install-linux.sh upgrade`，然后重试内置连接；不需要另装 Tailscale。

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

Windows verify job 会构建 release 二进制、编译 Inno Setup，并验证 SHA-256、内嵌文件和签名模式；元数据版本和内置 Tailcat 辅助程序的版本都必须与 tag 一致。验证通过后，独立的 `publish-windows` job 把安装器、摘要和元数据上传到同一个 GitHub Release。PFX 临时文件不会进入 artifact。两个 Secret 都存在时强制验证 Authenticode；两个都缺失时构建明确标记的 `unsigned-release`。

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

该入口固定校验 GoReleaser `v2.15.3` 官方预编译包的 SHA-256，并拒绝当前 Go 版本偏离 `go.mod`。它会验证四个平台二进制的 Go 版本、GOOS/GOARCH、CGO 状态、可执行权限、许可证文件、systemd 模板和 Homebrew service；还会逐一核对 Formula 下载 URL 必须指向 `gaixianggeng/mimi-remote`，其中 SHA-256 必须与实际归档一致。Linux 归档还必须包含独立 module 构建的 Tailcat 辅助程序；在 Linux 宿主执行产物门禁时，会用当前架构的真实二进制和本机临时 DERP 验证启动、配对信息与正常退出。该检查不使用生产中继或现有用户配置。普通安装用户不需要运行这个脚本。

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


### Windows 无窗口宿主

计划任务通过同目录的 `mimi-agent-host.exe` 启动 `agentd.exe`。宿主为 GUI 子系统、
agentd 保留控制台子系统。宿主退出时 Job Object 清理其进程树；客户端退出不停止服务。
宿主启动失败时检查 `%LOCALAPPDATA%\Mimi Remote\agent-host.last-error.log`（每次覆盖，最多 4 KiB）。

升级清理旧的开始菜单日志快捷方式，配置和配对数据保留。回退到不含宿主的旧安装器后，
旧版会恢复原计划任务动作，可能留下未被旧版安装器识别的宿主文件；不要手动删除用户配置。
Windows 10 22H2、Windows 11 默认 Terminal、重新登录和真实手机会话仍需分别走查。

开发验证：在 Windows PowerShell 7 中执行 `./scripts/test-windows-app.ps1`。
它使用仓库外共享缓存，验证 Native AOT、PE 子系统、退出码、参数转义和隔离子进程树，
不会停止正在使用的计划任务。窗口阳性对照会短暂显示测试控制台；不可观察时验证失败。
