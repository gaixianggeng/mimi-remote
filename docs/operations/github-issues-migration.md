# GitHub Issues 迁移记录

## 使用方式

从 2026-09-06 起，`gaixianggeng/mimi-remote` 的 GitHub Issues 是唯一问题账本。Linear 保留历史，不再双向同步。

- 搜索 `MIM-编号` 或 `label:migrated-from-linear` 查找迁移问题。
- 未完成问题保持 Open，只使用一个 `status: Backlog`、`status: Todo`、`status: In Progress` 或 `status: Verify` 标签。
- 达到 AGENTS.md 的完成条件后，移除状态标签并关闭，不因 PR 合并提前关闭。
- 复用已有 MIM 分支和 PR；PR 用 `Refs #编号` 关联，不因迁移重新派发任务。

```bash
gh issue list --repo gaixianggeng/mimi-remote --state open --label migrated-from-linear --limit 100
gh issue list --repo gaixianggeng/mimi-remote --state open --label "status: Todo" --limit 100
```

## 迁移范围

本次创建 32 张 GitHub Issue，保留原标题、验收要求、分类、迁移时状态、来源链接和 PR 记录。133 条原评论按时间顺序合并为 20 条带时间标记的历史评论。历史评论中的状态和完成结论不是当前状态，后续以标签和新评论为准。

迁移期间 MIM-230 被重新打开，因此比准备阶段的 31 张增加一张。未完成问题均指派给仓库维护者。已完成、已取消和重复的问题没有重建。

本机备份包含 275 张问题、1859 条原评论、状态历史和关联元数据；未下载附件文件。公开正文中的本机用户路径、真实 IP、内部设备/会话标识、私有后台与对话链接已脱敏。原记录与迁移映射保存在仓库外，不提交原始备份。

## 对照表

下列状态仅表示迁移时快照。每行均为本次新建的 GitHub Issue，分类标签保留在问题页面。

| 原编号 | GitHub 问题 | 迁移时状态 |
|---|---|---|
| MIM-9 | [#348 完善 Catalyst Keychain 与首次连接超时诊断](https://github.com/gaixianggeng/mimi-remote/issues/348) | Backlog |
| MIM-43 | [#349 连接时自动兼容或提示局域网与 Tailscale 地址](https://github.com/gaixianggeng/mimi-remote/issues/349) | In Progress |
| MIM-60 | [#350 降低核心运行链路复杂度并清理架构漂移](https://github.com/gaixianggeng/mimi-remote/issues/350) | Backlog |
| MIM-75 | [#351 在 Mimi Remote 中创建并管理 Mac 本地定时任务](https://github.com/gaixianggeng/mimi-remote/issues/351) | Backlog |
| MIM-93 | [#352 建立远程指令持久化、断线恢复与纵深防御基线](https://github.com/gaixianggeng/mimi-remote/issues/352) | Backlog |
| MIM-112 | [#353 在锁屏通知中安全处理 Agent 待审批请求](https://github.com/gaixianggeng/mimi-remote/issues/353) | In Progress |
| MIM-129 | [#354 长会话断线后因 active writer 卡住，无法重连或继续发送](https://github.com/gaixianggeng/mimi-remote/issues/354) | Backlog |
| MIM-146 | [#355 Mimi App 发起的会话缺少创建独立任务能力](https://github.com/gaixianggeng/mimi-remote/issues/355) | Verify |
| MIM-150 | [#356 让 agentd 网关通过本地 Prometheus 持续观测连接、时延与吞吐](https://github.com/gaixianggeng/mimi-remote/issues/356) | In Progress |
| MIM-151 | [#357 以 Tailcat 和官方 DERP 提供 Mimi 托管连接](https://github.com/gaixianggeng/mimi-remote/issues/357) | In Progress |
| MIM-199 | [#358 切换 App 时容易崩溃（TestFlight 1.2 build 100089）](https://github.com/gaixianggeng/mimi-remote/issues/358) | Backlog |
| MIM-200 | [#359 在 iPad Pro 会话页空白区域轮换展示操作技巧](https://github.com/gaixianggeng/mimi-remote/issues/359) | Backlog |
| MIM-209 | [#360 文件读取被拒绝时按标准目录主动请求 Mac 授权](https://github.com/gaixianggeng/mimi-remote/issues/360) | In Progress |
| MIM-217 | [#361 收敛会话历史状态文件的职责边界](https://github.com/gaixianggeng/mimi-remote/issues/361) | Todo |
| MIM-226 | [#362 Mac 菜单及时识别 Codex 服务未就绪](https://github.com/gaixianggeng/mimi-remote/issues/362) | Verify |
| MIM-230 | [#363 外部取消归档后会话仍从 iPad 列表消失](https://github.com/gaixianggeng/mimi-remote/issues/363) | In Progress |
| MIM-233 | [#364 将 App Store 名称统一为 Mimi Remote 并替换新版截图](https://github.com/gaixianggeng/mimi-remote/issues/364) | Verify |
| MIM-236 | [#365 普通 Desktop 本地会话在 App 中无法显示实时运行状态](https://github.com/gaixianggeng/mimi-remote/issues/365) | Backlog |
| MIM-237 | [#366 在会话列表轻量标识 Desktop 本地会话](https://github.com/gaixianggeng/mimi-remote/issues/366) | Todo |
| MIM-238 | [#367 Linux 默认使用本地托管 Codex App Server，免除 SSH 配置](https://github.com/gaixianggeng/mimi-remote/issues/367) | Verify |
| MIM-239 | [#368 Linux 桌面提供顶栏托盘菜单，集中查看状态与常用操作](https://github.com/gaixianggeng/mimi-remote/issues/368) | Verify |
| MIM-244 | [#369 量化验证 Tailcat 比 Tailscale 更快更稳定的原因](https://github.com/gaixianggeng/mimi-remote/issues/369) | Verify |
| MIM-249 | [#370 Claude 会话里显示的是 Codex 的技能列表](https://github.com/gaixianggeng/mimi-remote/issues/370) | Todo |
| MIM-250 | [#371 Claude 会话无法归档、分支、压缩与审阅](https://github.com/gaixianggeng/mimi-remote/issues/371) | Todo |
| MIM-254 | [#372 建立无登录的 StoreKit 匿名订阅权益服务](https://github.com/gaixianggeng/mimi-remote/issues/372) | Verify |
| MIM-258 | [#373 在 iOS 中购买和恢复 Mimi 托管连接](https://github.com/gaixianggeng/mimi-remote/issues/373) | Verify |
| MIM-262 | [#374 完成 Mimi 托管连接的隐私、App Store 与 TestFlight 上线验收](https://github.com/gaixianggeng/mimi-remote/issues/374) | In Progress |
| MIM-266 | [#375 会话 tab 首屏要等数秒，Claude 会话明显晚于 Codex 出现](https://github.com/gaixianggeng/mimi-remote/issues/375) | Todo |
| MIM-268 | [#376 引导 Codex Desktop 接入 Mimi Remote 共享运行时](https://github.com/gaixianggeng/mimi-remote/issues/376) | In Progress |
| MIM-273 | [#377 复用 iOS 定向测试的构建结果，避免 quick 重复编译与排队](https://github.com/gaixianggeng/mimi-remote/issues/377) | Todo |
| MIM-274 | [#378 精简协作规则，避免重复确认和过度验证](https://github.com/gaixianggeng/mimi-remote/issues/378) | Verify |
| MIM-275 | [#379 工作区手动刷新拿到新会话，Store 却没有合并进列表](https://github.com/gaixianggeng/mimi-remote/issues/379) | Todo |

## 自动巡检

应用接口确认原 `mimi-linear-issue` 自动化已不存在。本机旧配置文件不代表仍有已注册的定时任务。本次没有重建或启用新巡检。仓库中的巡检与阻塞检测模板已改用 GitHub；保留原 guard 路径与文件名，以复用原排他租约。

迁移历史中的任务标识已脱敏。继续旧任务前先从本机分支、Worktree 和执行记录核对，不得因公开页面缺少任务标识就重复派发。
