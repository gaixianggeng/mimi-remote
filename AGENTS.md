# 项目协作约定

## Linear 问题归档与执行

### 目标

- Linear 是本项目的问题账本和状态看板，Codex 是主要的问题输入与执行入口。
- Linear 工作区使用 `Gai Studio`，团队使用 `Mimi`，Issue 前缀为 `MIM`。
- 用户不需要先打开 Linear；在 Codex 中报告 case、Bug、UI 问题、逻辑问题或发送问题截图即可。
- 一个可独立验收、独立合并的用户结果对应一张 Issue；不要按文件、代码修改点或聊天轮次拆分 Issue。

### 自动归档触发条件

- 当用户针对本仓库发送问题截图、复现步骤，或明确描述一个可操作的 case、Bug、UI 问题、逻辑问题、改进点时，视为已授权使用 Linear MCP 在 `Mimi` 团队查重并创建或更新 Issue。
- 如果用户只是在询问概念、讨论方案、要求解释代码，或描述一个明显的假设例子，不自动创建 Issue。
- 如果用户明确说“进入问题收集模式”或说明还会连续发送多个问题，在用户说“收集结束”前只按 `B1`、`B2`、`B3` 编号确认，不创建 Issue、不修改代码、不创建分支；收到“收集结束”后再统一查重、合并或拆分并归档。
- 如果当前已经有关联的 Linear Issue，新问题属于同一用户结果、同一根因或同一验收范围，优先更新原 Issue，不重复创建。

### 归档流程

1. 优先使用 Linear MCP 查询和写入，不通过浏览器手工操作，除非 MCP 缺少所需能力。
2. 创建前搜索标题、描述和相关关键词，检查是否存在重复或高度相关的未完成 Issue。
3. 有明确重复项时，更新原 Issue 的证据、复现信息或验收标准，并返回原 Issue ID 和链接。
4. 没有重复项时创建新 Issue，默认指派给当前用户。
5. 新 Issue 默认状态：
   - 问题明确、具备复现信息、可以执行：`Todo`
   - 只是想法、证据不足、暂不确定是否处理：`Backlog`
   - 用户在同一条消息中明确要求立即修复或开始处理：`In Progress`
6. 根据内容自动选择标签：
   - 缺陷：`Bug`
   - 新能力：`Feature`
   - 体验或实现优化：`Improvement`
   - 按影响范围补充 `UI`、`iOS`、`Mac/agentd`、`Release`
7. 除非用户明确给出优先级、截止时间、Project 或 Cycle，不自行设置这些字段，也不为了完整性引入额外项目结构。
8. 禁止静默创建或更新 Linear Issue。每次发生 Linear 写入后，都必须在当前 Codex 回复中明确告知用户。
9. 完成归档后按实际结果返回：
   - 新建成功：`已创建`、Issue ID、标题、状态、标签、链接，以及“仅归档”或“已开始处理”的结论。
   - 命中已有问题：`未重复创建，已更新`、原 Issue ID、更新内容摘要和链接。
   - 创建或更新失败：明确说明`未写入 Linear`、失败原因和建议的下一步；不得假装已经成功。
   - 一次创建或更新多张 Issue：使用简短列表或表格逐项返回结果，不能只给总数。

### Issue 内容要求

- 标题描述用户可感知的结果或问题，不使用“修改某文件”“调整某函数”这类实现动作作为标题。
- 描述至少包含：
  - `目标`
  - `现状与证据`
  - `复现步骤`（可复现时）
  - `实际结果`
  - `期望结果`
  - `验收标准`
  - `实现边界`
- 从截图中提取界面、状态和错误信息作为证据；如果当前工具不能把截图直接上传到 Linear，就在描述中准确记录可见证据，不虚构附件。
- 截图、日志或描述中包含访问码、Token、账号、用户数据或其他敏感信息时，先脱敏再写入 Linear。
- 信息不足时仍可先创建 Backlog Issue，但必须标记未知项，不猜测根因、优先级或复现条件。

### 是否立即处理

- 默认行为是“先归档，不修改代码”。仅报告 case、发送截图或描述问题，不等于授权立即实现。
- 只有用户明确表达“处理”“修复”“开始做”“直接改”“现在解决”等执行意图时，才开始修改代码。
- 用户在报告问题的同一条消息中已经明确要求处理时，先查重并创建或关联 Issue，设为 `In Progress`，随后直接继续实现，不停下来等待二次确认。
- 问题大小用于决定组织方式和给出处理建议，不单独构成开始修改代码的授权：
  - 当前 Issue 内的小修正：更新原 Issue 并在当前 Codex 任务中继续，不新建 Issue 或任务。
  - 可独立验收、需要独立分支或 PR：创建独立 Issue。
  - 范围较大、包含多个独立结果：先创建一个父 Issue 或提出拆分建议；创建多个子 Issue 前先让用户确认拆分方案。
- 默认同时最多保持 2 张独立 Issue 为 `In Progress`。准备开始第三张时，先指出当前进行中的任务并让用户决定暂停或继续。

### 开发、PR 与完成状态

- 一张正在执行的 Issue 对应一个主要 Codex 任务和一个主要 Worktree；不要为同一 Issue 的分析、实现、测试和修正反复开启新任务。
- 分支名称使用 `codex/mim-<编号>-<简短英文描述>`，例如 `codex/mim-12-fix-access-code-resume`。
- PR 标题或分支名称必须包含 `MIM-<编号>`，确保 GitHub 与 Linear 自动关联。
- 开始实现时状态为 `In Progress`；PR 创建、等待测试或等待合并时使用 `Verify`；PR 合并到受保护的 `main` 后才进入 `Done`。
- 完成前在 Issue 中回写 Branch / Worktree、Commit / PR、测试结果、运行态验证和发布结果。
- `Done` 的最低条件是：相关改动已进入并推送 `main`、必要验证或发布已完成、临时 Worktree 已清理。

## iOS 日常构建与模拟器标准

### 默认链路

- 日常 `build` / `run` 采用确定性自动选择：优先 available、paired、USB 连接且未占用的 iOS/iPadOS 真机，其次是 available、paired、本地网络可达且未占用的真机；只有完全没有可达真机时才使用未占用的 `iPad Pro 13-inch (M5)` Simulator。已经检测到真机但全部忙时明确失败，不静默跨设备类型回退。
- 同一连接类型下的多台真机先按名称 `iPad Pro`、再按设备名和 UDID 排序；不得依赖列表顺序或随机选择。
- `build-for-testing`、`test`、视觉快照和 CI 精确固定 `iPad Pro 13-inch (M5)` Simulator；目标缺失或忙时等待或明确失败，禁止回退 iPad mini、其他 iPad 或 iPhone。
- 所有入口固定使用 `MimiRemote` Scheme 和 `Debug` 配置。
- 命令行统一通过 `bash ./scripts/ios-dev.sh` 执行：
  - 查看本次目标：`bash ./scripts/ios-dev.sh target`
  - 查看设备占用：`bash ./scripts/ios-dev.sh leases`
  - 编译：`bash ./scripts/ios-dev.sh build`
  - 编译测试产物：`bash ./scripts/ios-dev.sh build-for-testing`
  - 运行单测：`bash ./scripts/ios-dev.sh test`
  - 构建、安装并启动：`bash ./scripts/ios-dev.sh run`
- 日常编译、部署和运行只允许通过 `scripts/ios-dev.sh` 进入。`scripts/deploy-ipad.sh` 是统一入口持有租约后的内部真机执行器，不得直接调用；需要刷新覆盖安装时使用 `REFRESH_INSTALL=1 bash ./scripts/ios-dev.sh run`。
- 所有 Simulator 和真机分别在各自 DerivedData 根目录下按 UDID 隔离；不同 Runtime 下的同名 Simulator 也不得共用构建目录。
- 显式设置 `IOS_TARGET_MODE=device|simulator`、`IOS_DEVICE_ID` 或 `IOS_SIMULATOR_ID` 时，显式选择优先于自动规则。
- 普通 `build` / `run` 必须先获取按 UDID 的跨 Worktree 原子租约；租约记录 PID、Codex Task、Worktree、命令、DerivedData 和开始时间，进程退出后释放，死 PID 租约在下次占用时清理。

### XcodeBuildMCP

- 第一次日常构建或运行前先执行 `bash ./scripts/ios-dev.sh target`、`bash ./scripts/ios-dev.sh leases` 并读取 session defaults；随后仍必须调用统一脚本的 `build` / `run`，不得根据 MCP 中已有的 `simulatorId` 直接调用 Simulator workflow。
- 仓库的 `.xcodebuildmcp/config.yaml` 只固定 project、scheme、Debug 和 bundle ID，不保存 `deviceId`、`simulatorId`、`simulatorName` 或静态 DerivedData，避免会话默认值抢先决定日常部署目标。
- XcodeBuildMCP 的 Simulator workflow 仅用于 `build-for-testing`、`test`、视觉快照、UI 调试和明确的兼容性验收。使用前必须用 `bash ./scripts/ios-dev.sh test-destination` 与 `bash ./scripts/ios-dev.sh test-derived-data-path` 解析同一固定 M5 目标，并通过 session defaults 同时设置 `simulatorId` 和对应的 `derivedDataPath`。
- 当前会话未启用 device workflow 时，选中真机后直接使用统一脚本，不得改用 Simulator workflow。即使 session 中残留旧 `simulatorId`，也不能把它视为日常目标决策。
- 不把本机真机或 Simulator UDID 写入仓库；每次从当前连接状态解析，显式覆盖只通过本机环境变量传入。
- 绕过统一脚本的 `xcodebuild` 若命令行包含 destination UDID、名称或 generic platform，视为外部占用；不得把对应设备误判为空闲。

### 设备用途

- available、paired、USB 连接的真机是日常 `build` / `run` 第一优先级；没有可用 wired 真机时，可使用 available、paired 且当前本地网络可达的真机。仅保留历史配对记录、当前不可达的设备不参与选择。
- 完全没有可达 USB 或本地网络真机时，`iPad Pro 13-inch (M5)` 是唯一 Simulator fallback；检测到真机但全部被租约或外部 `xcodebuild` 占用时明确失败。同一真机无论通过 wired 还是 localNetwork 连接，均按 UDID 共用租约和 DerivedData。
- `iPhone 17 Pro` 只用于明确的 iPhone 布局验收，`iPhone 17e` 只用于小屏兼容验收。切换时显式设置 `IOS_SIMULATOR_NAME`，完成后恢复默认 iPad。
- 相机、通知、Keychain、Tailscale/弱网、性能以及发布前验证仍必须使用真机；自动 fallback 到 Simulator 时不得把这些专项验证标记为完成。
- Simulator 通过不代表真机专项验收完成，真机结果也不替代日常 Simulator 回归。

### 运行约束

- 同一设备的 Xcode、Codex、XcodeBuildMCP 构建与测试必须串行；不同设备只有在各自持有租约并使用独立 DerivedData 时才允许并行。
- 日常仍建议只保留一台已启动 Simulator；统一脚本不会关闭其他任务正在使用的设备，也不会创建、擦除或删除设备。
- 只执行 `build` 或 `build-for-testing` 时不要求预先启动 Simulator；不要为了纯编译主动开机。
- 使用 Simulator 连续开发、调试 UI 或运行测试期间保持默认 iPad 开启，避免在同一开发时段反复启动和关闭。
- 使用 Simulator 且预计一小时内还会继续开发时可以保持开启；长时间不用、当天开发结束、准备让 Mac 合盖过夜前关闭。
- 切换到兼容性设备前先关闭当前 Simulator；iPhone 验收结束后关闭 iPhone，后续开发再恢复默认 iPad。
- 创建新设备前先检查现有设备并优先复用；不得为每次任务创建临时 Simulator。
- 固定快照设备忙时先查看租约；需要等待可设置 `IOS_DEVICE_LEASE_WAIT_SECONDS`，不得通过切换机型绕过。
- 遇到高 CPU、安装卡住、Mac 睡眠恢复后状态异常或 CoreSimulator 阻塞时，先停止构建，关闭并重新启动现有 Simulator；不擦除主力设备，也不通过继续创建设备绕过。
