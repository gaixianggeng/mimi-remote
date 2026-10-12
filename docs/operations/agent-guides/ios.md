# iOS 日常构建与模拟器标准

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
- 固定快照设备忙时先查看租约；需要等待可设置 `IOS_DEVICE_LEASE_WAIT_SECONDS`，不得通过切换机型绕过。该预算同样适用于 `test`、`build-for-testing` 和显式 `IOS_TARGET_MODE=simulator` 的 `build` / `run`；排队时输出占用者的 Task、已占用时长和命令，并按 `IOS_DEVICE_LEASE_PROGRESS_SECONDS`（默认 30 秒）报告进度。租约独占语义不变。
- 遇到高 CPU、安装卡住、Mac 睡眠恢复后状态异常或 CoreSimulator 阻塞时，先停止构建，关闭并重新启动现有 Simulator；不擦除主力设备，也不通过继续创建设备绕过。

### 构建证据复用

- 目的：开发阶段定向 XCTest 已在固定 M5 上编译过与当前完全相同的输入时，quick 的 App 编译项不再重复编译和排队。只有 `verify-change.sh` quick 通过 `IOS_BUILD_EVIDENCE_REUSE=1` 使用证据；日常 `build` / `run`、full、PR Gate 和真机专项始终真实构建。
- 记录：统一入口在 Simulator 上成功的 `build`、`build-for-testing`、`test` 和 Simulator `run` 的构建步骤，在构建前后各计算一次指纹，只有 `xcodebuild` 返回 0 且两次一致才写入。失败、取消、构建中途改动输入，以及带有可能改变构建的参数（构建设置覆盖、`-enableCodeCoverage` 等）都不记录，也不覆盖此前的成功证据。测试筛选和报告参数（`-only-testing`、`-skip-testing`、`-quiet`、`-resultBundlePath`、`-testLanguage`、`-testRegion`、`-collect-test-diagnostics` 等）不影响记录。XcodeBuildMCP 或直接 `xcodebuild` 不记录证据。
- 指纹纳入：工程目录 `ios/MimiRemote` 下全部已跟踪和未忽略的未跟踪文件（含 Tests、`project.pbxproj`、Scheme、`Package.resolved`、xcconfig、entitlements）；解析到工程目录之外的工程输入（当前为 `docs/` 下的政策文档、`LICENSE`、`THIRD_PARTY_NOTICES.md` 与 `scripts/build-tailcat-mobile.sh`）：文件引用按 Xcode 分组层级和 `sourceTree` 计算实际路径，构建设置与脚本中的相对路径以 `SRCROOT` 为基准；`experiments/tailcat`；`scripts/ios-dev.sh` 与 `scripts/ios-build-evidence.sh`。文件按 Git blob 计算，已提交、暂存和未暂存的同一内容得到同一指纹，所以定向测试后提交不会使证据失效。另外核对 Xcode 版本与路径（含 `DEVELOPER_DIR`）、`TOOLCHAINS` 经 xcrun 解析出的 swiftc 路径与版本、iphonesimulator SDK、主机架构、Go 工具链与 `GOTOOLCHAIN`、Tailcat 框架指纹、目标 UDID 与名称、DerivedData、工程路径、Scheme、配置和 `CODE_SIGNING_ALLOWED=NO`。统一入口不清理环境，`xcodebuild`、工程脚本阶段和 Tailcat 构建脚本都继承调用方的环境变量，所以以下变量的取值也纳入指纹（只存哈希，不存原值）：`TOOLCHAINS`、`SDKROOT`、`CC`/`CXX`/`LD`/`LDPLUSPLUS`/`LIBTOOL`/`SWIFT_EXEC`、`CPATH` 等头文件与库搜索路径、`IPHONEOS_DEPLOYMENT_TARGET`/`MACOSX_DEPLOYMENT_TARGET`、`TAILCAT_MOBILE_*`（等待时长除外），以及工程文件、xcconfig、Info.plist、entitlements 和 Scheme 里以 `$(NAME)`、`${NAME}` 或 `$NAME` 引用的名字（`xcodebuild` 会把同名环境变量当作最低优先级的构建设置）。`PATH` 不纳入：脚本阶段固定前置工具目录，实际用到的工具已按路径、版本或指纹核对。设置了 `XCODE_XCCONFIG_FILE`、工程外引用无法唯一确定（解析器不可用、未知 `sourceTree`、路径含变量或通配符、经过符号链接或不存在的目录、指向仓库外或文件缺失）、存在合并冲突或子模块时一律不复用，并在原因中说明。Git 忽略的文件（Agent 状态、构建产物）不纳入；构建输入不得依赖被忽略的文件。
- 存放与隔离：证据写在本次 DerivedData（仓库外共享缓存，按配置和 UDID 隔离）下的 `MimiBuildEvidence/`，按当前 Worktree 物理路径的哈希分文件。每个 Worktree 只读写自己的记录，不继承其他 Worktree 的结果，即使输入完全相同也会自行构建一次。
- 语义与缓存清理：证据只证明“这组输入在这些条件下编译成功”，不指向也不消费 `.app`；quick 本身不安装、不运行 App，所以其他 Worktree 之后在共享 DerivedData 中覆盖产物不影响这个结论。删除对应 DerivedData 目录（例如按开发缓存规则清理 iOS 组件）会连同证据删除，下一次 quick 重新构建。
- 查看：`IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID= IOS_SIMULATOR_NAME='iPad Pro 13-inch (M5)' bash ./scripts/ios-dev.sh build-evidence` 只读输出“可复用：…”或“需要重新构建：…（变化项与文件）”，不占用租约、不构建。
