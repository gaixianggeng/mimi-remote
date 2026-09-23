# Desktop 的专用 SSH 入口

此入口让 Desktop 的 SSH 启动命令和 Mimi 使用同一个 macOS 登录环境。需要已登录并运行的 Mimi Remote Mac、系统“远程登录”，以及一次专用 SSH 密钥配置。默认关闭。

```text
Desktop → 系统 sshd 认证专用密钥 → agentd ssh-bridge
                                      ↓ 当前用户私有 Unix socket
                              GUI agentd → 用户登录 shell → Codex 官方 CLI
Mimi App → agentd WebSocket ──────────────────────────────→ 同一个 App Server
```

系统 sshd 继续负责认证和网络连接。命令桥只转发 stdin、stdout、stderr 与退出码，不解析 Desktop 启动脚本，不改 Codex 协议或 writer 锁。所有启动命令都从 GUI 执行，因此 Desktop 当前使用的 `nohup` 启动、官方 daemon 冷启动和重启都继承 Aqua。断开 SSH 时桥只停止前台命令，保留 Desktop 启动的后台 App Server。无需让 Mimi 抢先绑定 Codex socket。

## 一次配置

先安装包含此功能的 Mac App。在现有 `~/Library/Application Support/mimi-remote/config.json` 中加入下面字段，保留其他配置；`app_server.transport` 必须为 `local`：

```json
{ "desktop_ssh": { "enabled": true } }
```

通过 Mimi Remote Mac 重启服务。命令桥必须由 GUI 服务启动；从系统 SSH 中直接运行 `agentd serve` 不能代替这一步。

在 Desktop 所在电脑上创建专用密钥。若该路径已有密钥，不要覆盖，改用一个新名称并对应调整后续路径：

```bash
ssh-keygen -t ed25519 -f "$HOME/.ssh/mimi-desktop" -C mimi-desktop
ssh-add "$HOME/.ssh/mimi-desktop"
```

只将 `.pub` 公钥传到服务宿主。下面命令在服务宿主生成待添加的 `authorized_keys` 行；它不写入 SSH 配置。输入公钥文件路径，本机接入可直接输入 `~/.ssh/mimi-desktop.pub`：

```bash
printf '专用公钥文件路径：'
IFS= read -r MIMI_PUBLIC_KEY
python3 - "$MIMI_PUBLIC_KEY" <<'PY'
import json, shlex, subprocess, sys
from pathlib import Path
key = Path(sys.argv[1]).expanduser()
subprocess.run(['ssh-keygen', '-lf', str(key)], check=True, stdout=subprocess.DEVNULL)
parts = key.read_text().split()
if len(parts) < 2 or parts[0] != 'ssh-ed25519':
    raise SystemExit('需要新建的 Ed25519 公钥')
app = Path('/Applications/Mimi Remote Mac.app/Contents/Resources/agentd')
if not app.is_file():
    app = Path.home() / 'Applications/Mimi Remote Mac.app/Contents/Resources/agentd'
if not app.is_file():
    raise SystemExit('请先安装 Mimi Remote Mac')
command = shlex.quote(str(app)) + ' ssh-bridge'
print('command=' + json.dumps(command, ensure_ascii=False) + ',no-pty ' + ' '.join(parts[:2]) + ' mimi-desktop')
PY
```

备份宿主的 `~/.ssh/authorized_keys` 后，将输出作为**新的一行**加入。不要用普通 SSH 已在使用的公钥，也不要删除原有密钥。专用公钥若已存在于其他行，应先核对重复项，否则 sshd 可能选择未带命令桥的旧行。持有这把专用私钥的客户端可通过原始 SSH 命令在当前用户的 GUI 环境执行命令，访问范围高于普通 Background SSH；只给可信 Desktop 使用，妥善保护私钥。远程接入时可在 `authorized_keys` 行增加 OpenSSH 的 `from=` 来源限制。

在 Desktop 所在电脑的 `~/.ssh/config` 中复制原有可用 Host 配置，使用新的 Host 别名，并将 `IdentityFile` 改为 `~/.ssh/mimi-desktop`，加入 `IdentitiesOnly yes`。保留原 Host 的地址、端口、用户与跳板配置。将新条目放在通配的 `Host *` 之前，因为 OpenSSH 使用先匹配到的选项值。设置 `ControlMaster no` 和 `ControlPath none`，避免复用普通 SSH 已认证的旧连接；使用 `ssh -G <新别名>` 核对最终身份文件与控制路径。

本机接入可用下面命令生成配置片段。若配置中已有通配 `Host *`，将片段插入其前面；否则可追加到 `~/.ssh/config`：

```bash
python3 - <<'PY'
import getpass
print('Host mimi-local\n  HostName 127.0.0.1\n  User ' + getpass.getuser()
      + '\n  IdentityFile ~/.ssh/mimi-desktop\n  IdentitiesOnly yes\n  ControlMaster no\n  ControlPath none')
PY
```

在 Desktop 的 SSH Connections 中选择这个新 Host。专用入口只支持 SSH exec，不提供交互式 SSH shell/PTY；普通 SSH Host 保持原样。

## 验证与旧实例迁移

本机别名配置完成后，下面命令必须输出 `Aqua`。非本机接入将 `mimi-local` 换成新建的 Host 别名：

```bash
ssh -T mimi-local /bin/launchctl managername
ssh -T mimi-local 'codex app-server daemon start'
```

如果已有 Background Codex resident，新入口不会迁移或终止它。先完成正在运行的任务，断开旧 Desktop SSH 页面，再使用[一次性修复](shared-ssh-app-server.md#一次性修复旧的-background-resident)。之后通过专用 Host 连接。继续使用旧 Host 启动 Codex，仍可能重新创建 Background 实例。

验收应覆盖：Desktop 创建任务后 Mimi 接续、Mimi 创建任务后 Desktop 接续、agentd 重启期间的活动回合、官方 daemon 正常重启、并发重连、钥匙串与受保护目录。CLI/隔离实验不能替代 Desktop UI 和实际安装包的权限验收。

## 失败与回退

- GUI 服务未运行、入口未启用或 Unix peer 身份不符时，专用 SSH 命令失败。不会回退到系统 SSH 的 Background 环境，也不会自动启动第二个 Codex 实例。
- 命令桥目录仅供当前用户访问，socket 为 `0600`。双方核对 Unix peer UID。不会新增 TCP 监听或复制凭据。
- agentd 停止时会结束自己转发的 SSH 命令连接；Codex 的独立 resident 继续运行。Desktop 需要重连，活动模型回合不重新提交。
- 回退时将 `desktop_ssh.enabled` 设为 `false` 并重启 Mimi，移除专用公钥行和新 Host 配置，恢复原 Host。不要删除普通密钥或 Codex 历史。回退后原生 SSH 的 Background 启动限制仍然存在。
