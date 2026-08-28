# MIM-148 跨端验收矩阵

## 前置条件

- macOS 安装并登录白名单内的 Codex Desktop：`26.820.60940 (7119)` 或 `26.825.31414 (7287)`。
- Mac App 已开启“同步 Codex Desktop 会话（实验）”，状态为 `ready`。
- iOS App 已通过配对连接同一 Mac；移动端只连接 Mimi 独立 App Server。
- 每条用例使用独立、可识别的 Thread，并记录 Desktop、Mimi 和 agentd 日志中的 Thread ID。

## 主路径

| 用例 | 操作 | 预期 |
| --- | --- | --- |
| Desktop → Mimi 历史 | Desktop 新建 Thread 并完成一轮；Mimi 打开同一 Thread | Mimi 加载完整历史，包含消息、Reasoning、工具项和完成状态 |
| Desktop → Mimi 写入 | Mimi 对 Desktop-owned Thread 续问、Steer、中断 | 操作只进入 Desktop；无重复 Turn，状态实时回到 Mimi；中断后 Turn 进入 `interrupted` 且不产生最终回复 |
| Desktop → Mimi 交互 | Desktop-owned Turn 触发审批、补充输入或 MCP elicitation | 卡片只出现一次；响应回到 Desktop；取消和超时状态明确 |
| Mimi → Desktop | Mimi 新建并运行 Thread；Desktop 打开同一 Thread | Desktop 收到 `conversationState` 投影并可继续；Mimi 仍是唯一 writer |
| Browser 宿主 | Desktop-owned Turn 从 Mimi 触发 Browser | Browser 仍由 Desktop 原生工具宿主执行，Mimi 不启动替代进程 |

## 恢复和竞争

| 用例 | 操作 | 预期 |
| --- | --- | --- |
| 反复切换 | 两端反复打开同一 Thread 并交替发送 | writer 始终明确；无 `already has an active writer`、重复审批或重复 Turn |
| 移动端断线 | Turn 运行中断开并恢复 iOS WebSocket | 恢复后加载完整快照或从明确 revision 继续，不重放 `turn/start` |
| agentd 重启 | Turn 运行中重启 agentd | Desktop-owned 状态不被猜测；连接恢复后重新请求完整历史 |
| Desktop 重启 | Desktop 退出并重新打开 | socket 断开期间保持只读；重新握手、build gate 和完整快照通过后恢复 |
| Desktop 保持关闭 | 退出 Desktop，等待状态变为 `desktop_not_running`，再从 Mimi 新建并继续 Thread | IPC overlay 不参与请求；独立 App Server 正常读写，不需要重启 agentd |
| 长历史 | 使用大量消息、Reasoning、工具项和附件的 Thread | 首个完整快照可加载，patch 缺口自动回完整历史，内容不截断为错误状态 |

## 阻断路径

| 用例 | 条件 | 预期 |
| --- | --- | --- |
| 未知 build | Desktop 正在运行且 build 不在 7119/7287 白名单 | `unsupported_build`，所有写操作暂停；关闭 Desktop 后独立 App Server 恢复 |
| Desktop 未运行 | Desktop 已关闭并经过下一次进程检查 | `desktop_not_running`；IPC overlay 退出，独立 App Server 正常读写 |
| Desktop 运行但 socket 不可用 | Desktop 进程存在，但 socket 尚未建立或异常 | `socket_unavailable`，所有写操作暂停，不将请求本地重跑 |
| 协议错误 | initialize、revision 或 follower 响应不符合当前 build profile | `protocol_error`，返回可重试且交付状态不确定的错误 |
| owner 不明确 | Desktop 和 Mimi 均无法证明 Thread ownership | 只读；不向任一 writer 猜测转发 |
| 旧配置 | 检测到旧 shared fallback、plist 或迁移标记 | `legacy_cleanup_required`；确认 Desktop 已退出后才允许一次性清理 |

## 通过标准

所有主路径、恢复和阻断用例通过；全程没有重复 Turn、双重审批、写入竞态或敏感 IPC 字段泄露。未知 build 和任何无法证明 owner 的情况必须 fail closed。验收日志必须能按短标识对齐移动端请求、gateway 路由、Desktop 回执、Turn 终态和工具项终态，且不包含提示词、命令、工作区或完整 ID。
