# GH-491 · Mac 模块管理开发交接

Refs #491；实现接续 PR #507 的设计交接。只改变 Mac App 与 agentd，不改变 iOS 协议实现、不部署服务、不自动关闭 issue。

## 实现边界

菜单与设置按 AI Agent / 连接方式组织。Codex 与 Claude 独立开关，DeepSeek 明确不可操作。额度只属于对应 Agent 的窗口；未知不当成 0，过期明确标记。设置包含通用、AI Agent、连接方式、文件访问、服务五组，原实验窗口不再作为入口。

配置意图来自 `status.module_configuration`，驻留服务应用值来自 `runtime_status.modules`；配对同时校验意图、驻留值及可用性。轻量 readiness 不会因刻意省略额度而每分钟把正常快照标旧。状态读取与开关写入共享序号/单 writer，Tailcat 读取也有独立序号保护。

`agentd module --module=codex|claude|tailscale|lan --enabled=true|false --json` 是配置事务接口。返回无凭证的 `previous`、配置 SHA-256 `revision` 和 `restart_required`。Mac 保存后沿现有 ServiceManagement 重载并核对驻留值；失败做 CAS 回滚。恢复接口要求 `--restore=<previous JSON> --if-revision=<revision>`；不能覆盖 CLI 或其他实例后来写入的配置。CLI 调用者须自行根据 `restart_required` 重启服务。

Codex 缺省开启；Tailscale 缺省保留旧监听语义。首次显式网络切换保留另一个通道的既有意图。独立网络策略启用后，服务始终保留 loopback 管理入口，关闭通道不只影响二维码，还限制绑定/HTTP 请求入口。不会调用系统 VPN 开关。LAN 只接受私有本地地址与私有来源（Tailscale 地址单独分类），并继续使用现有鉴权。

关闭 Codex 不再让其 CLI、上游准备和就绪检查阻断 Claude-only 或全部 Agent 关闭状态。不会退出 Codex Desktop。模块配置重载会短暂影响其他移动连接，不能承诺无中断。无法可靠获知活跃任务数，所以关闭 Agent、最后连接方式和退出使用保守确认，不显示猜测的任务数量。

Tailcat 仍使用现有独立热控制接口；开关不重置配对，中继设置/重置保留在连接设置。6 秒撤销只保存开关意图，不保存 Token 或完整配置。Tailcat 热控制没有同一配置 revision 协议，撤销会重新读取其状态后启用。

## 验证记录与剩余范围

已经执行的具体 CI 结果以 PR 描述及 Actions 日志为准。源码类型检查不是签名 App 的完整打包，也不是 SMAppService、真实网络、账号或真机验证。

本地先运行 `bash scripts/verify-change.sh --plan`，再使用仓库现有 Mac 构建流程重建 App（含内嵌 agentd）。不能只替换 Swift 界面或继续使用旧包内 agentd。保持当前 main/PR 代码版本一致，勿把临时 assembly 分支当作交付分支。

建议依次验证：

1. 原配置升级：Codex/Claude/Tailscale/LAN 的实际启用意图与旧配置一致，Token、项目、Claude provider 和配对没有意外变化。退出重开后开关仍保持。
2. Agent 矩阵：双开、Codex-only、Claude-only、全部关闭。Claude-only 不要求 Codex 上游就绪；全部关闭时本地服务和设置仍可用、禁止配对。开关开着但 CLI 缺失/未登录时显示不可用而不是伪装已连接。
3. 网络矩阵：TS-only、LAN-only、双开、全部关闭、Tailcat-only。VPN 未登录不得自动开启 LAN；TS 关闭但 LAN 开启时从 Tailscale 地址发起的请求仍被拒绝；全部关闭后 Mac 仍能重新开启。
4. 配对窗口保持打开时切换/关闭通道，二维码立即失效展示，不可复制旧码；关闭最后路径有确认；重新恢复可用通道后可生成新码。后台 readiness 每分钟运行时不应让可配对状态闪空。
5. 失败/并发：模拟服务重载失败、配置并发修改、快速连续点击和六秒撤销。开关不假成功；CAS 冲突不覆盖新配置；撤销重载失败有明确恢复结果。
6. UI 与权限：菜单高度/窄屏、深浅外观、键盘与 VoiceOver；两家账号的额度不会混合；未知/过期/API Key 显示正确；原照片/磁盘权限、日志、更新、Homebrew 恢复入口仍可用。

确认签名构建、服务登记、真实网络及 iPhone/iPad 回归后，再决定合并及关闭 #491。
