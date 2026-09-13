# 项目协作约定

## 按任务读取

以下文件保留完整约束。只在对应场景读取，不在每次修改前全量加载。

| 场景 | 必读规则 |
| --- | --- |
| 报告或处理问题、操作 Issue、分支、PR、完成交付 | [问题归档与执行](docs/operations/agent-guides/issues.md) |
| 编译、安装、运行测试、调整构建脚本或清理开发缓存 | [开发缓存](docs/operations/agent-guides/development-cache.md) |
| 新增、修改或提交源码 | [源码行数](docs/operations/agent-guides/source-size.md) |
| 选择或执行验证、等待 CI、交付或 push | [分层验证](docs/operations/agent-guides/verification.md) |
| iOS 构建、运行、测试、UI 调试或设备管理 | [iOS 设备与构建](docs/operations/agent-guides/ios.md) |

## 始终适用的边界

- GitHub Issues 唯一账本是 `gaixianggeng/mimi-remote`，不创建或同步 Linear 问题。迁移对照见 `docs/operations/github-issues-migration.md`。
- 用户报告可操作问题即授权查重归档，默认不改代码；明确要求处理后持续完成范围内实现与验证。收集模式结束前只按 B1、B2 编号记录。
- 一项独立用户结果对应一张 Issue、一个主要任务和一个主要 Worktree。最多 2 张独立 Issue 为 In Progress，启动更多前由用户决定。
- 仓库公开。写入前脱敏 Token、账号、用户数据、本机路径、真实 IP、设备和会话标识、私有链接。GitHub 写入后必须告知用户。
- 新分支使用 `codex/gh-<编号>-<英文描述>`；迁移问题复用旧分支。PR 用 `Refs #<编号>` 关联，不默认自动关闭 Issue。
- 开始实现用 In Progress；PR、测试或合并待完成用 Verify。只有改动进入并推送 main、必要验证或发布完成且临时 Worktree 清理后才关闭 Issue。
- 不在 Worktree 内建立 GB 级可再生缓存；使用 `bash ./scripts/development-cache-path.sh <组件>`。不删除源码、未提交改动、发布归档或模拟器数据，不删除锁文件抢占缓存。
- 源码行数以 `scripts/check-source-size.sh` 为唯一事实来源，不通过压缩代码或扩大豁免绕过限制。
- 开发中只做定向验证。最后一次改动后按分层验证规则选择一次 quick 或 full，先运行同模式 --plan。不得为了保险自动扩大测试，失败后只重跑受影响项。
- iOS 日常构建与运行统一使用 `bash ./scripts/ios-dev.sh`。测试与快照固定 `iPad Pro 13-inch (M5)`；设备忙时等待或报告阻塞，不绕过租约切换设备。
- 只报告最新受检版本实际成功的检查。quick 不等于完整回归，等待或超时不等于通过。
