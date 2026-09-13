# Worktree 与开发缓存

- Worktree 只隔离源码、未提交改动和必须与分支绑定的状态。不得默认在每个 Worktree 内保存独立的 Xcode DerivedData、Rust `target`、Go 工具下载或其他 GB 级可再生缓存。
- 本地开发脚本统一通过 `bash ./scripts/development-cache-path.sh <组件>` 取得仓库外缓存路径。同一 Git common-dir 的所有 Worktree 必须复用同一命名空间；另一份 clone 必须使用不同命名空间。
- iOS DerivedData 按配置、设备类型和 UDID 隔离。同一 UDID 继续通过设备租约串行写入。Mac DerivedData 按架构和配置隔离，并通过开发缓存锁串行写入。
- Mac 安装每次先从当前 Worktree 增量构建，并在同一缓存锁内复制到独立暂存目录。不得仅凭共享目录中已有 App 就跳过构建；系统锁文件保留不代表缓存正在占用，不得删除锁文件来抢占缓存。
- Rust 验证默认设置共享 `CARGO_TARGET_DIR`。Go 默认复用 Go 自身的全局 build/module cache；不得改成 Worktree 内缓存。
- 新增本地构建或工具下载脚本时，默认复用上述共享缓存。只有产物确实依赖分支路径且工具不能可靠检测输入变化时，才允许放进 Worktree，并必须在脚本旁说明原因。
- 清理磁盘前先确认没有相关构建进程或设备租约。只删除 Git 忽略且可再生成的目录，例如旧的 `.build`、`target` 和 `ios/MimiRemote/build`；不得删除 Worktree、分支、未提交源码、发布归档或模拟器数据。
- 共享缓存异常时，只清理对应组件目录并重新构建。不得通过为同一设备、配置或 Issue 新建另一份缓存来绕过问题。
