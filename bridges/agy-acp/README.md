# mimi-agy-adapter

Mimi Remote 的 Antigravity CLI (`agy`) 通道适配器，基于标准 Agent Client Protocol (`agy acp`) v1 与 `@mimi/appserver-kit` 构建。

## 分层设计

- `src/acp/`：与具体 CLI 无关的标准 ACP v1 stdio JSON-RPC 客户端（`initialize` 固定传 `clientCapabilities: {}`，让 Agent 执行原生工具链与沙箱）。
- `src/agy/`：`agy` 专属的环境变量清洗（剥离 `ANTIGRAVITY_*` / `__CFBundleIdentifier`）、CLI 会话数据库过滤（`~/.gemini/antigravity-cli/conversations`）、Git Worktree 仓库归并、模型与思考档位映射、斜杠命令目录及历史回放投影。
- `src/runtime/` & `src/handlers/`：将会话、回合、流式输出、1M 上下文计量、模式切换（`default / accept-edits / auto / plan`）与工具审批映射为 Mimi `app-server` v2 JSON-RPC 协议。

## 本地开发与检查

```bash
bash ../../scripts/check-agy-acp-adapter.sh
```
