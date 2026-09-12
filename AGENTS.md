# 项目协作约定

## GitHub 问题归档与执行

### 目标

- GitHub Issues 是本项目的问题账本，状态通过标签记录，Codex 是主要的问题输入与执行入口。
- 问题仓库固定为 `gaixianggeng/mimi-remote`。新问题使用 GitHub `#编号`；迁移问题保留标题中的 `[MIM-编号]` 和来源链接。
- Linear 仅保留历史，不再创建或同步问题。迁移对照见 `docs/operations/github-issues-migration.md`。
- 用户不需要先打开 GitHub；在 Codex 中报告 case、Bug、UI 问题、逻辑问题或发送问题截图即可。
- 一个可独立验收、独立合并的用户结果对应一张 Issue；不要按文件、代码修改点或聊天轮次拆分 Issue。

### 自动归档触发条件

- 当用户针对本仓库发送问题截图、复现步骤，或明确描述一个可操作的 case、Bug、UI 问题、逻辑问题、改进点时，视为已授权在 GitHub 仓库 `gaixianggeng/mimi-remote` 查重并创建或更新 Issue。
- 如果用户只是在询问概念、讨论方案、要求解释代码，或描述一个明显的假设例子，不自动创建 Issue。
- 如果用户明确说“进入问题收集模式”或说明还会连续发送多个问题，在用户说“收集结束”前只按 `B1`、`B2`、`B3` 编号确认，不创建 Issue、不修改代码、不创建分支；收到“收集结束”后再统一查重、合并或拆分并归档。
- 如果当前已经有关联的 GitHub Issue，新问题属于同一用户结果、同一根因或同一验收范围，优先更新原 Issue，不重复创建。

### 归档流程

1. 优先使用 GitHub MCP 或已登录的 `gh` CLI 查询和写入；缺少所需能力时才使用浏览器。所有查询和写入都显式指定仓库。
2. 创建前搜索标题、描述和相关关键词，检查是否存在重复或高度相关的未完成 Issue。
3. 有明确重复项时，更新原 Issue 的证据、复现信息或验收标准，并返回原 Issue ID 和链接。
4. 没有重复项时创建新 Issue，默认指派给当前用户。
5. 未完成 Issue 保持 Open，并且只设置一个 `status: <状态>` 标签；更新状态时替换旧状态标签。新 Issue 默认状态：
   - 问题明确、具备复现信息、可以执行：`Todo`
   - 只是想法、证据不足、暂不确定是否处理：`Backlog`
   - 用户在同一条消息中明确要求立即修复或开始处理：`In Progress`
6. 根据内容自动选择标签：
   - 缺陷：`bug`
   - 新能力：`Feature`
   - 体验或实现优化：`Improvement`
   - 按影响范围补充 `UI`、`iOS`、`Mac/agentd`、`Release`
7. 除非用户明确给出优先级、截止时间、Project 或 Cycle，不自行设置这些字段，也不为了完整性引入额外项目结构。
8. 禁止静默创建或更新 GitHub Issue。每次发生 GitHub 写入后，都必须在当前 Codex 回复中明确告知用户。
9. 完成归档后按实际结果返回：
   - 新建成功：`已创建`、Issue ID、标题、状态、标签、链接，以及“仅归档”或“已开始处理”的结论。
   - 命中已有问题：`未重复创建，已更新`、原 Issue ID、更新内容摘要和链接。
   - 创建或更新失败：明确说明`未写入 GitHub`、失败原因和建议的下一步；不得假装已经成功。
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
- 从截图中提取界面、状态和错误信息作为证据；如果当前工具不能把截图直接上传到 GitHub，就在描述中准确记录可见证据，不虚构附件。
- 仓库是公开的。写入前脱敏访问码、Token、账号、用户数据、本机用户路径、真实 IP、设备与会话标识和私有后台链接。公开保留必要的复现、技术约束、分支和 PR 关联；原始私有证据留在本机。
- 信息不足时仍可先创建 Backlog Issue，但必须标记未知项，不猜测根因、优先级或复现条件。

### 是否立即处理

- 默认行为是“先归档，不修改代码”。仅报告 case、发送截图或描述问题，不等于授权立即实现。
- 只有用户明确表达“处理”“修复”“开始做”“直接改”“现在解决”等执行意图时，才开始修改代码。
- 用户在当前或前文已明确要求处理时，先查重并创建或关联 Issue，按下述并行上限进入 `In Progress`。随后持续完成范围内的可逆实现和必要验证，常规技术选择不重复确认。
- 问题大小用于决定组织方式和给出处理建议，不单独构成开始修改代码的授权：
  - 当前 Issue 内的小修正：更新原 Issue 并在当前 Codex 任务中继续，不新建 Issue 或任务。
  - 可独立验收、需要独立分支或 PR：创建独立 Issue。
  - 范围较大、包含多个独立结果：先创建一个父 Issue 或提出拆分建议；创建多个子 Issue 前先让用户确认拆分方案。
- 默认同时最多保持 2 张独立 Issue 为 `In Progress`。准备开始第三张时，先指出当前进行中的任务并让用户决定暂停或继续。

### 开发、PR 与完成状态

- 一张正在执行的 Issue 对应一个主要 Codex 任务和一个主要 Worktree；不要为同一 Issue 的分析、实现、测试和修正反复开启新任务。
- 新问题分支使用 `codex/gh-<GitHub编号>-<简短英文描述>`。迁移问题已有的 `codex/mim-...` 分支与 Worktree 继续复用，不因迁移重建。
- PR 描述必须用 `Refs #<GitHub编号>` 关联问题；迁移问题可保留原 `MIM-编号` 标题。默认不使用 `Fixes` / `Closes`，避免 PR 合并后在发布或清理完成前自动关闭 Issue。
- 开始实现时使用 `status: In Progress`；PR 创建、等待测试或等待合并时使用 `status: Verify`。达到下面的 Done 条件后，移除状态标签并以 completed 原因关闭 Issue；取消或重复以 not planned 原因关闭，并说明原因。
- 完成前在 Issue 中回写 Branch / Worktree、Commit / PR、测试结果、运行态验证和发布结果。
- `Done` 的最低条件是：相关改动已进入并推送 `main`、必要验证或发布已完成、临时 Worktree 已清理。

## Worktree 与开发缓存

- Worktree 只隔离源码、未提交改动和必须与分支绑定的状态。不得默认在每个 Worktree 内保存独立的 Xcode DerivedData、Rust `target`、Go 工具下载或其他 GB 级可再生缓存。
- 本地开发脚本统一通过 `bash ./scripts/development-cache-path.sh <组件>` 取得仓库外缓存路径。同一 Git common-dir 的所有 Worktree 必须复用同一命名空间；另一份 clone 必须使用不同命名空间。
- iOS DerivedData 按配置、设备类型和 UDID 隔离。同一 UDID 继续通过设备租约串行写入。Mac DerivedData 按架构和配置隔离，并通过开发缓存锁串行写入。
- Mac 安装每次先从当前 Worktree 增量构建，并在同一缓存锁内复制到独立暂存目录。不得仅凭共享目录中已有 App 就跳过构建；系统锁文件保留不代表缓存正在占用，不得删除锁文件来抢占缓存。
- Rust 验证默认设置共享 `CARGO_TARGET_DIR`。Go 默认复用 Go 自身的全局 build/module cache；不得改成 Worktree 内缓存。
- 新增本地构建或工具下载脚本时，默认复用上述共享缓存。只有产物确实依赖分支路径且工具不能可靠检测输入变化时，才允许放进 Worktree，并必须在脚本旁说明原因。
- 清理磁盘前先确认没有相关构建进程或设备租约。只删除 Git 忽略且可再生成的目录，例如旧的 `.build`、`target` 和 `ios/MimiRemote/build`；不得删除 Worktree、分支、未提交源码、发布归档或模拟器数据。
- 共享缓存异常时，只清理对应组件目录并重新构建。不得通过为同一设备、配置或 Issue 新建另一份缓存来绕过问题。

## 源码文件行数约束

- 开发时必须遵守 `scripts/check-source-size.sh` 定义的源码文件行数上限。该脚本是行数限制的唯一事实来源；规则变更时，以脚本中的当前配置为准。
- 当前普通 Go 和 Swift 生产文件不得超过 2000 行，测试文件不得超过 2500 行。生成文件、第三方依赖和脚本明确排除的路径不在此限制内。
- 新增或修改源码前先检查目标文件的当前行数。开发过程中持续关注行数；文件接近上限时，先按职责拆分，再继续增加逻辑或测试，不得等 CI 报错后再处理。
- 提交前必须运行 `bash ./scripts/check-source-size.sh`。文件超限时，默认按职责拆分，并保持原有行为和测试覆盖不变。
- 不得通过压缩代码、合并无关语句、删除必要测试或添加目录、通配符豁免来绕过门禁。
- 只有确实无法立即拆分且有明确原因时，才允许在 `scripts/check-source-size.sh` 中添加精确文件路径例外。例外必须写明原因和后续拆分方向，不能作为长期默认方案。

## 分层验证执行规范

- 开发过程中只运行与当前行为直接相关的最小检查。Go 优先运行变更 package 的测试；iOS 优先运行精确 XCTest selector、相关快照或静态检查。不要在每次微调后运行 quick、完整 XCTest 或全仓测试。
- 完成最后一次代码修改后，交付或 push 前先根据下述条件选择模式。quick 先运行 `bash ./scripts/verify-change.sh --plan`，再运行一次 `bash ./scripts/verify-change.sh`；full 先运行 `bash ./scripts/verify-change.sh --plan --full`，再运行一次 `bash ./scripts/verify-change.sh --full`。计划与执行使用同一模式，选择 full 时不先执行 quick。
- quick 是普通 Issue 的默认收尾。iOS quick 只在固定 `iPad Pro 13-inch (M5)` Simulator 上编译 App，不编译或运行整个 XCTest 测试包；需要回归测试时，在开发阶段运行与问题直接相关的 selector。
- 修改共享协议、跨栈接口或同一用户链路的多个产品栈，本身不要求本地 full。必须对接口兼容、错误语义和降级链路运行定向检查；只有同时命中下述 full 条件时才升级。
- 只有以下任一条件成立时，才执行 `bash ./scripts/verify-change.sh --full`：
  - 修改鉴权、权限、持久化格式或迁移、消息 exactly-once、并发、重连等高风险语义；
  - 大范围重构导致直接影响范围无法可靠界定；
  - 必要回归缺少等价 CI 覆盖，且本地 full 能补齐该缺口；
  - 准备正式发布，或用户明确要求完整回归。
- 运行 full 前，检查 full 计划中的命令，并核对这些命令所调用脚本的实际目标、配置和 selector。full 计划已经覆盖 quick 项目时，不另跑 quick；full 没有覆盖当前风险所需的专项时，才额外补验。所选 full 计划中的每一项仍须在本轮执行，不能因开发阶段或以前轮次运行过等价测试而跳过。
- 普通本地 full 不默认扫描完整 Git 历史；它保留必要的 PR Gate 自检和 Codex 协议检查。修改公开仓库安全门自身时，仍执行完整安全检查。`Public Repository Safety` 在 `main` push 和 `workflow_dispatch` 使用 full-history，在 Pull Request 使用增量检查。
- `--plan` 保持详细输出。实际执行时，计划、结果汇总和每项完整输出分别写入脚本报告结果目录中的 `plan.txt`、`summary.txt` 和编号日志；该目录默认位于本机临时目录。控制台只显示状态、实际耗时和失败项的有限日志。不要另建统计系统。
- 前置静态检查失败时，不再启动依赖它的重型检查；其他独立检查仍继续并汇总。非零退出、阻塞退出码 75、取消和超时都不能算通过，也不能跨轮引用旧结果。检查执行中收到 INT 或 TERM 时，只终止当前检查的进程组，并保留取消结果。
- Issue 已完成、改动文件较多、准备提交和“为了保险”都不是 full 的触发条件。quick、本地 full 或 CI 失败时先定位，修复后只重跑失败项；修复引入新影响时补相应检查，不自动升级为全量流程。
- 真机验证仍只用于相机、通知、Keychain、Tailscale/弱网、性能、发布前专项或 Issue 明确要求。普通 UI、文案、局部状态和单 package 修复不得默认启动真机。
- 设备排队沿用现有租约等待预算。租约超时是阻塞，不能据此豁免检查或切换到其他设备。环境故障必须按日志和运行环境证据判断；`main` 有相同失败或重跑变绿都不能单独证明改动无关。
- 等待长时间本地命令或 CI 时，使用宿主已有的阻塞或挂起工具。没有状态变化时，不反复运行 `tail`、`ps` 或派另一个 Agent 监视。
- 必需检查必须对最新受检提交实际返回成功。使用不同 Xcode 或 SDK 的本地结果与 CI 结果分别记录，不能互相替代。
- 如果宿主没有完成事件可继续唤醒当前任务，把 Issue 保持在 `Verify`，并交接 Commit、PR、CI 链接、已执行检查、未验证范围和恢复原任务的入口。负责人在 CI 成功或失败后回到原任务继续处理。开发结束本身不满足 `Done`。
- 交付时只报告实际执行的检查，并明确列出延后到 PR Gate、真机或发布阶段的范围。不得把 quick 结果表述为完整回归通过。

## iOS 日常构建与模拟器标准

### 默认链路

- 日常 `build` / `run` 采用确定性自动选择：优先 available、paired、USB 连接且未占用的 iOS/iPadOS 真机，其次是 available、paired、本地网络可达且未占用的真机；只有完全没有可达真机时才使用未占用的 `iPad Pro 13-inch (M5)` Simulator。已经检测到真机但全部忙时明确失败，不静默跨设备类型回退。仅保留历史配对记录、当前不可达的设备不参与选择。
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
- 所有 Simulator 和真机分别在各自 DerivedData 根目录下按 UDID 隔离；不同 Runtime 下的同名 Simulator 不共用构建目录。同一真机的 wired 与 localNetwork 连接共用租约和 DerivedData。
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
