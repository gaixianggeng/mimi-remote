# 共享 App Server

本文描述 macOS 与 Linux 默认使用的本机 Unix control socket transport、显式指定远端 SSH target 时的 SSH transport，以及 Codex Desktop 如何接入同一个共享 App Server。本机模式不要求 sshd、SSH 密钥或 macOS 的“远程登录”，也不使用 Desktop 私有 IPC。

## 目标

Mimi、本机终端和 Codex Desktop 共用同一个 Unix App Server。任一入口创建的普通 Codex Thread 都可以由其他入口接续。

```text
Mimi App -> agentd 鉴权 WebSocket -> unix:// ----------------------------------┐
本机终端 ----------------------------> codex --remote unix:// -----------------+-> 标准 control socket
本机 Desktop ---> localhost SSH -----> codex app-server proxy -----------------+
远程 Desktop ---> Mac SSH -----------> codex app-server proxy -----------------┘
Mac App：标准 socket 由 launchd 持有 -> GUI 前门 -> 私有 backend socket -> 同一个 Aqua App Server
```

OpenClaw 和不使用 control socket 的普通本地模式继续使用自己的 App Server。agentd 不枚举、不停止，也不重配这些进程。

## 配置

macOS 的 `~/Library/Application Support/mimi-remote/config.json` 与 Linux 的对应配置文件默认为：

```json
{
  "app_server": {
    "transport": "local",
    "auto_title": true
  }
}
```

agentd 直接连接标准 control socket。Mac App 安装版启动服务前自动登记登录用户的 launchd 前门；由它持有标准 socket，并在 Aqua 环境启动独立的 Codex backend。前门未就绪时 agentd 只报告 Codex 不可用，不自行争夺标准 socket。Linux 的 socket 缺失时仍由 agentd 优先通过独立 user-systemd scope 启动 resident；macOS Homebrew 版沿用已登录用户的 Aqua 启动方式。三种方式都把 open-file soft limit 提到至少 8192；agentd 重启不终止 resident。本机终端通过 `codex --remote unix://` 接入同一个后端；普通 `codex` 仍会启动自己的本地运行时。

### macOS Mac App 前门

Mac App 自动创建 `~/Library/LaunchAgents/com.gaixianggeng.mimi.mac.codex-front.plist`。launchd 在 Aqua 会话持续持有 `~/.codex/app-server-control/app-server-control.sock`，权限为 `0600`。首次连接时，它以 **Mimi Remote Mac** 为授权主体启动前门；前门再启动监听 `app-server-backend.sock` 的官方 Codex CLI，并转发 Unix 字节流。前门、agentd 或单条 SSH 连接重启时，独立 backend 保留正在运行的模型回合。

Desktop 继续使用原来的 SSH Host。它执行的 `codex app-server --listen unix://` 发现标准 socket 已被占用后退出，随后官方 `codex app-server proxy` 经前门接入同一个 backend。无需指定 Mimi 与 Desktop 的启动顺序，也无需修改 SSH 密钥、`authorized_keys` 或 Host 别名。macOS 可能在首次登记时提示新增后台项目；平时启动不出现 Mimi 自定义确认弹窗。

首次安装时若已有 resident 占用标准 socket，自动登记不会抢占，主服务保留诊断。先结束共享任务、断开所有 Desktop SSH 页面并停止 Mimi 服务。Background 实例可按下文的一次性修复流程释放；Aqua 实例需要人工核对进程、确认已无其他客户端和活动任务，再向该进程发送 SIGTERM。然后重启 Mimi Remote Mac 登记前门。

已登记的前门在 Mac 登录后可能遇到登录前由 Desktop 启动的旧 resident。此时新连接会等待旧实例完全退出，不能提前进入私有 backend。旧客户端仍连接时不发信号；客户端断开后，只有能确认旧 Codex 版本支持重复 SIGHUP 的优雅退出语义，才自动请求 drain。版本或进程身份无法确认时拒绝自动迁移，保留旧任务供人工处理。独立 `command/exec` 不属于模型回合 drain 保证，迁移前仍应结束这类命令。

检查前门状态或在安全修复后重新登记，可运行已安装 App 内的命令：

```bash
"/Applications/Mimi Remote Mac.app/Contents/Resources/agentd" codex-front status
"/Applications/Mimi Remote Mac.app/Contents/Resources/agentd" codex-front install
```

若 App 安装在 `~/Applications`，将命令中的 `/Applications` 改为 `$HOME/Applications`。回退旧版前，先结束共享任务并断开 Desktop，记录 `codex-front status` 返回的 `backend_pid`，用新版本的 `agentd codex-front uninstall --stop-idle-backend` 确认私有 backend 空闲、请求优雅退出并卸载前门。命令失败时不要替换 App；不要只换回旧 App 而留下仍指向新版本的 LaunchAgent。

旧版 macOS setup 自动写入的 `transport=ssh` + `ssh_target=127.0.0.1` 会在 agentd 启动、`agentd setup` 或 `agentd doctor --fix` 时先完成 CLI 可用性和本机 socket 路径预检，再原子改写为 `local`。macOS 设置与配置迁移不创建共享进程，真实连接由 GUI 服务启动时验证。带用户名的 target 或远端主机不会被自动迁移；静态预检失败时原配置保持不变。

### 可选：隔离普通 Desktop 与 SSH/Mimi 的会话目录

Mac App 可用 `app_server.shared_codex_home` 为共享 backend 指定独立的绝对目录。默认不设置，升级不会自动启用或移动历史。此配置只支持 Mac App 的 `local` 前门；Linux、Homebrew 直启 resident、远端 `ssh` transport 不支持。

启用后，普通 Desktop “This Mac” 仍读取原 `~/.codex`；SSH 与 Mimi 继续连接原标准 socket，前门把两者转发到独立目录中的同一个 backend。无需修改 Desktop 安装包、SSH Host、密钥或 shell 配置。新建的共享会话不再被普通 Desktop 从原目录扫描到。

独立目录同时隔离 Codex 配置、认证、历史、skills/plugins 等状态。需要在新目录重新登录并按需配置；本功能不复制凭据、不迁移 SQLite 或 rollout，不改变旧会话 ID。旧历史留在原目录，已经被普通 Desktop 发现的旧会话不会自动重新归类。切换后的旧会话迁移应另行安排，不能把两份目录的历史直接拼接。

目录必须已存在，且不能与公共 socket 所属的 CODEX_HOME 相同、互为父子目录或通过符号链接指向同一目录。推荐使用 `~/.codex-mimi`，不要修改现有 `codex.env.CODEX_HOME`；后者决定 Desktop SSH 仍在使用的公共 socket。

准备独立目录并登录（只操作新目录）：

```bash
mkdir -p "$HOME/.codex-mimi"
chmod 700 "$HOME/.codex-mimi"
CODEX_HOME="$HOME/.codex-mimi" codex login
```

实际切换前，结束所有共享任务与队列，关闭 Desktop SSH 页面，在 Mac App 中停止服务并退出 App。先用**原配置**安全卸载前门；任何失败都应停止，不能继续修改目录或强杀后台任务：

```bash
"/Applications/Mimi Remote Mac.app/Contents/Resources/agentd" codex-front uninstall --stop-idle-backend
```

卸载成功后，备份并只更新这一项配置。以下脚本保留其他字段，使用同目录临时文件原子替换，输出备份位置而不输出配置内容：

```bash
python3 - <<'PYCODE'
import json
import os
import shutil
import tempfile
from pathlib import Path

config_path = Path.home() / "Library/Application Support/mimi-remote/config.json"
shared_home = (Path.home() / ".codex-mimi").resolve(strict=True)
config = json.loads(config_path.read_text())
if config.get("app_server", {}).get("transport") != "local":
    raise SystemExit("此步骤只适用于现有 local 前门配置")
fd, backup = tempfile.mkstemp(prefix="config.before-shared-home.", suffix=".json", dir=config_path.parent)
os.close(fd)
shutil.copyfile(config_path, backup)
config["app_server"]["shared_codex_home"] = str(shared_home)
fd, staged = tempfile.mkstemp(prefix=".config.", dir=config_path.parent)
try:
    with os.fdopen(fd, "w") as output:
        json.dump(config, output, ensure_ascii=False, indent=2)
        output.write("\n")
    os.replace(staged, config_path)
finally:
    if os.path.exists(staged):
        os.unlink(staged)
print("配置备份：", backup)
PYCODE
```

再启动 Mac App，由它登记前门。检查状态，并从 SSH 与 Mimi 各创建/续聊一个新共享会话：

```bash
"/Applications/Mimi Remote Mac.app/Contents/Resources/agentd" codex-front status
```

状态中的 `backend_codex_home` 应为新目录，`isolated_history` 应为 `true`，且没有 `configuration_error`。这些字段描述配置，不能代替实际连接验证。Mimi 每次连接还会核对上游 `initialize.codexHome`；字段缺失或目录不符时拒绝连接，不能把旧 backend 当作隔离服务。旧版 Codex 若不返回这个字段，也不能启用隔离。

前门将安装时的 backend 目录固定在 LaunchAgent 中。直接编辑运行中配置不能热切换目录；安装和启动都会拒绝不一致的配置。切换必须经过上述原配置的安全卸载，确保旧 backend 无连接、活动回合或队列；独立目录模式不允许仅卸载前门而留下 backend。

回退时，同样先结束共享任务、关闭客户端并退出 Mac App，用**当前隔离配置**执行 `codex-front uninstall --stop-idle-backend`。成功后从配置中删除 `app_server.shared_codex_home`，再启动 Mac App。也可恢复切换前的配置备份，但应先确认期间没有其他配置更新。独立目录中的新历史保留，不删除、不自动合入原历史。不要只替换旧版安装包：旧版本不理解此配置，会重新接入默认历史。

### 显式远端 SSH（高级）

要把 Codex 放到另一台主机时，显式指定 target；agentd 用 `ssh -T <target> codex app-server proxy` 连接远端的共享 socket：

```json
{
  "app_server": {
    "transport": "ssh",
    "ssh_target": "user@mac-host",
    "auto_title": true
  }
}
```

`ssh_target` 是传给 OpenSSH 的单个目标参数。它可以是主机名、`user@host`，或 `~/.ssh/config` 中的 Host 别名。目标必须登录运行共享 App Server 的同一个用户，并使用同一个默认 `~/.codex`。

首次 `setup` / `up` 可以用命令行参数或环境变量指定目标。命令行参数优先；成功预检后，目标连同 `pin_transport: true` 一起写入配置，后台服务不需要继承安装终端的环境变量，之后不带参数的自动迁移也不会把显式选择的本机回环 target 改回 `local`。已经是 `local` 的配置用同样的命令即可切到 SSH，不需要 `setup --force`：

```bash
agentd up --app-server-ssh-target user@mac-host
AGENTD_APP_SERVER_SSH_TARGET=user@mac-host agentd up
```

agentd 不保存 SSH 密码或私钥。SSH 模式启动前必须确保远端的 Remote Login、host key 和非交互密钥认证可用：

```bash
ssh user@mac-host true
```

首次运行会要求确认 SSH host key。命令必须在无需输入登录密码的情况下成功。agentd 的固定远端命令会显式补齐 `~/.local/bin`、`~/.npm-global/bin`、mise shims / latest Codex、Homebrew 和系统目录，不依赖非交互 SSH 是否加载 shell rc。完成后运行：

```bash
agentd doctor
agentd up --no-pair
agentd status
```

## 启动与连接

本机模式下 agentd 先探测 control socket 并执行真实 WebSocket 初始化；SSH 模式下则先通过 SSH 打开 `codex app-server proxy`。Mac App 的 backend 由前门在首次连接时启动；Linux 与 macOS Homebrew 版在默认 socket 尚未提供服务时由 agentd 启动。Codex 启动参数如下；前门仅将监听地址替换为私有 backend socket：

```bash
open_file_limit=$(ulimit -Sn)
if test "$open_file_limit" != unlimited && test "$open_file_limit" -lt 8192; then
  ulimit -Sn 8192
fi
CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1 \
  codex -c features.code_mode_host=true app-server --listen unix://
```

macOS 本机模式还通过 `command/exec` 查询 resident 的 `launchctl managername`，仅复用 Aqua 环境。每条新的业务连接都以独立探针校验，并核对探针与业务连接的 Unix peer，避免实例替换期间沿用旧的校验结果。若检查失败或已有 resident 属于 Background，agentd 拒绝该 Codex 连接，但保留主服务诊断；不终止旧进程。Mac App 的 supervisor 与前门 LaunchAgent 均限定为 Aqua。Homebrew 用户应通过已登录用户的 `agentd up` 启动 GUI 服务，不能把 SSH 中直接执行 `agentd serve` 当作等价启动方式。

Desktop 的 SSH proxy 与 Mimi 通过前门接入同一个 backend，任务历史与接续方式不变。Mac 尚未登录、前门未加载时，远程 Desktop 仍可能先创建 Background resident；用户登录后按上文步骤做一次安全迁移。Mimi 不控制 Desktop 自己的启动逻辑。

launchd 启动的进程和 SSH 登录在 macOS 上的 open-file soft limit 通常只有 256。agentd 启动新 resident 前会读取当前值；低于 8192 时先提高到 8192，无法提高时拒绝启动。它不会降低已经更高的限制。

这个容量余量不能替代订阅释放。App Server 会为每个已加载 Thread 保留 session 和 MCP 资源；取消最后一个订阅后，官方实现仍有 30 分钟无活动宽限期，之后才卸载 Thread。

这个 App Server 只接受 Unix Socket 上的连接：agentd 直连、本机终端或 SSH proxy。启动命令会关闭它的 Remote Control 注册，防止它继承 Desktop 已保存的同一套服务端身份。ChatGPT 移动端和 Desktop 普通 “This Mac” 模式继续连接官方 App Server，不会被共享 resident 接管。

Mac App 使用前门后，标准 Socket 的 owner 始终是 launchd；前门用进程内互斥和跨进程文件锁确保并发连接只启动一个私有 backend。Linux 与 macOS Homebrew 版仍由 agentd 在进程内串行探测与启动；多个入口竞争时，只有成功绑定默认 Socket 的 App Server 成为 owner。

agentd 或单条 Mimi WebSocket 退出时只关闭自己的连接或对应 SSH proxy，不停止共享 App Server。socket、SSH、Codex 版本或协议初始化失败时，Codex 链路明确失败，不回退到独立 WebSocket、stdio 或 Desktop IPC。本机 transport 已建立而 readiness 失败时，agentd 继续提供诊断；静态配置、CLI 预检或其他启动阶段错误仍可能阻止主服务启动。

若默认 Socket 文件仍存在，但无法完成初始化，agentd 会报告 Codex 不可用并保留诊断服务。它不会猜测 owner 或删除共享 Socket。环境检查失败时，刷新后的 runtime 状态使用 `shared_local_session_unavailable`；`/healthz` 的 200 只证明主服务存活。Mac App 用户先运行 `codex-front status`，确认登录项与私有 backend 状态，再从 Mac App 重启服务；不要手工在标准 Socket 启动另一个 Codex。Linux 与 macOS Homebrew 用户确认没有仍在使用该 Socket 的 App Server 后，可以手工运行上面的 `codex ... app-server --listen unix://`；Codex 会按自己的启动锁和 stale-socket 规则恢复。恢复 Aqua 实例后，下一条连接重新校验，不需要重启 agentd。

## macOS 文件访问权限

Mac App 安装版的 Codex backend 由前门启动。launchd 先启动 Mimi Remote Mac 主程序，再由它启动包内 agentd，因此授权主体仍是 Mimi Remote Mac（照片图库在 App 的“设置 → 文件访问”中允许）。Homebrew 版 resident 由 agentd 启动，授权主体是 agentd 本身。显式 SSH 模式下 resident 是 sshd 的子进程；若“远程登录”里开启了“允许远程用户完全访问磁盘”（macOS 默认勾选），它会继承 sshd 的完全磁盘访问。因此从 SSH 切到本机模式后，照片图库、Mail、Safari 等“完全磁盘访问”范围内的目录可能从可读变为需要授权；桌面、文稿、下载仍按首次访问时的系统提示授权。需要无人值守访问受保护目录时，按[安装、升级与回滚](install-upgrade-rollback.md)为 Mimi Remote Mac（Homebrew 版为 agentd）授予完全磁盘访问。

### 一次性修复旧的 Background resident

`gh` 登录信息相同，不代表不同 macOS 安全会话都能读取登录钥匙串。旧 resident 由 SSH 创建时，后续 GUI agentd 即使改为直连，仍会复用旧进程的安全环境。重复新建任务或重启 agentd 不会改变这个环境。

先结束所有共享 Codex 任务和其他 Mimi 活动任务，并关闭 Desktop 的 SSH 共享页面。Mac App 用户在“诊断”中选择“修复共享运行环境…”，确认后 App 会停止自己的服务，调用一次性释放命令，再由 Aqua supervisor 重建服务。它不删除任务历史，不复制 GitHub Token，也不修改钥匙串 ACL。

Homebrew 用户在已登录的本机终端执行：

```bash
agentd stop
agentd repair-codex-session --confirm-disconnected
agentd start
```

只有确认 resident 属于当前用户、默认 socket 的真实 peer、Background 环境，且没有其他连接、活动任务或待执行队列，命令才对该 PID 发送一次 SIGTERM。缺少协议或系统检查结果时拒绝操作；不使用 SIGKILL，不删除 socket。已处于 Aqua 或 socket 不存在时返回无需释放。命令本身不启动 replacement，仍由原有 GUI 服务负责。

Codex `0.155.1` 的 Unix 服务实现可以通过 SIGHUP 停止接纳新的模型回合，等待已接纳的提交和运行回合结束；重复 SIGHUP 不升级为强制退出。这不是 JSON-RPC 方法，也不是单个 Thread 的交接接口。独立 `command/exec` 可能随服务退出而终止，且 Desktop 重连仍可能先创建新的 Background 实例。因此当前一次性修复继续要求其他客户端断开、任务与队列空闲，不把 drain 当作自动接管依据。确认后到修复结束前不要重新打开 SSH 共享页面。此操作不能解决钥匙串本身被用户锁定、凭证失效或其他独立授权问题。

## 会话和消息规则

- `thread/start` 创建 Thread，`thread/resume` 订阅和接续现有 Thread。
- Mimi 在同一个 Thread 的最后一个本地事件观察者离开时发送 `thread/unsubscribe`。启用 `app_server.approval_broker` 后，agentd 为仍在运行、排队或等待审批的任务保留上游订阅，先确认页面退订，任务结束后才向 App Server 退订。重新进入页面会取消尚未执行的退订；已发出的退订须先收到响应，再恢复订阅。空闲任务仍直接释放。
- App 进入后台会主动断开业务连接，iOS 无需持续运行。agentd 以 `thread/queue/add` 的提交标识和 `thread/resume` 的运行状态补齐保活信息，继续接收任务事件并发送 APNs；客户端回来后读取权威历史。单个 Mac 后台连接最多保留 24 小时，受原有连接数量上限约束，进程重启后不保留这些观察状态。
- Mimi 的普通消息只使用 `thread/queue/add`。运行中的 Thread 会在 App Server 内排队，空闲后自动开始，不会被误解释成 `turn/steer`。
- 同一个 Thread 同时最多有一条由 Mimi 提交、尚未开始的服务端队列消息。下一条继续保留在 Mimi 本地，避免后一次线程设置覆盖前一条尚未开始的消息。
- 发送结果不确定时，Mimi 使用相同的 `clientUserMessageId` 完整分页查询 `thread/queue/list` 和 `thread/items/list`，并在两者切换的竞态窗口再次查询队列。找不到记录时保留待发送状态，由用户确认是否重试。
- 模型、工作目录、权限和协作模式属于共享 Thread 状态。Mimi 创建新 Thread 时通过 `thread/start` 写入初始设置；恢复 Thread 或发送普通消息时不隐式覆盖当前设置。其他入口可以继续修改这些共享设置。
- 历史读取使用 `thread/read(includeTurns:false)`、`thread/turns/list` 和 `thread/items/list`，不再请求整段历史。
- 标准审批和补充输入会广播给订阅该 Thread 的入口，第一个响应生效。Mimi 不自动拒绝未知的 Desktop 私有请求。

## Desktop 使用方式

本机 Desktop 需要新增一个指向 `127.0.0.1` 的 SSH 主机，并从这个主机打开共享项目。只有这一步才需要开启 macOS 的“远程登录”并配置本机非交互 SSH 认证；只用 Mimi 不需要。远程 Desktop 使用指向这台 Mac 的 SSH 主机。两个入口都必须登录与 agentd 相同的 macOS 用户。

普通 “This Mac” 模式仍可用于 ChatGPT Desktop 私有的 `codex_app`、Browser 和专用渲染能力，但它不属于共享运行时。不要同时用普通本地模式和 SSH 模式打开同一个活动 Thread。

Thread writer 锁仍然生效。若普通 “This Mac” 模式和共享模式同时恢复同一个活动 Thread，后恢复的一方会明确失败。该限制用于保护历史文件，不能通过取消 writer 锁规避。

## 诊断与验收

```bash
agentd doctor
agentd status --json
ps -axo pid,ppid,command | grep '[c]odex.*app-server'
lsof -U | grep app-server-control.sock
```

升级到包含 open-file 修复的版本后，已经运行的 resident 不会自动获得新限制。Mac App 的私有 backend 可通过 `codex-front status` 找到 PID；先结束所有共享 Thread 的活动 Turn，并关闭对应的 Mimi 和 SSH Desktop 页面，再核对并重启该 PID。Linux 与 macOS Homebrew 的标准 Socket resident 可用：

```bash
ps -axo pid=,ppid=,command= | grep '[c]odex.*app-server --listen unix://'
kill -TERM <上一步确认的-resident-pid>
agentd doctor
```

不要对模糊的 `pgrep codex` 结果批量执行 `kill`。普通 “This Mac”、OpenClaw 和共享 resident 可能同时存在。

验收至少覆盖：Mimi-first、远程 Desktop-first、本机 Desktop-first、并发排队、审批首响应、agentd 重启和分页历史。验收前后分别记录 OpenClaw 的 App Server PID；二者必须保持不变。

`thread/queue/*` 当前是 Codex 实验接口。本版本要求远端 Codex 不低于已验证的 `0.149.1`；接口不支持时发送会明确失败，不降级为有竞态的 `turn/start`。
