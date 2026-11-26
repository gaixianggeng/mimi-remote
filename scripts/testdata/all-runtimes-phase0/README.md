# 全部运行时 Phase 0：脱敏现网实录

本目录存放「工作区会话列表支持全部运行时」方案 Phase 0 的脱敏现网实录（基于 `origin/main` 基线提交 `2c6342fb`），不修改任何产品代码行为。

## 范围说明

- **仅包含现网实录与畸形拒绝样本**：按评审关闭清单（首个 PR 范围），未来契约夹具（如 `pageDisposition: "same_page_retry"`、4 状态 `listMeta`）待方案 P1 修订定稿后在后续阶段提交。
- **脱敏边界**：全部路径均使用 `/Users/demo/...`，不含任何真实用户名、本机路径、访问 Token、私钥、Tailscale IP、真实会话 ID 或用户对话内容。

## 覆盖矩阵

| 分组 | 文件 | 覆盖要点 |
|---|---|---|
| `accepted` | `gateway-global-unmarked-same-page-retry.json` | Go 网关 Controlled Global Git 超时返回无 `listMeta` / 无 `pageDisposition` 的 `mimi_*` 同页重试游标，次轮补出更晚条目，且 `cliVersion` 当前被白名单裁剪 |
| `accepted` | `claude-sdk-empty-cwd.json` | Claude SDK（`mimi-claude-adapter/0.3.0`）合法输出 `cwd: ""` 与正常行同页、Unix 秒时间戳、`recencyAt: null`、同秒 `id DESC` 实测排序 |
| `accepted` | `claude-legacy-rust-ms.json` | Rust Claude（`alleycat-claude-bridge/0.2.15`）Unix 毫秒时间戳、同毫秒 `thread_id ASC` 跨页游标、省略 `recencyAt` |
| `accepted` | `codex-recency-at-null.json` | Codex（`codex-cli 0.171.0`）`sortKey: "recency_at"` 下实测 StateDB 未回填 `recencyAt: 0` 与正常秒级值，以及基于协议 Schema（`v2/ThreadListResponse.json`）派生的 `recencyAt: null` 用例 |
| `accepted` | `agy-acp-current-list.json` | Antigravity（`mimi-agy-adapter/0.1.0`）当前无 `listMeta`、Unix 秒时间戳、`cli`/`other` 来源与 `cwdMissing` |
| `accepted` | `deepseek-harness-session-list.json` | DeepSeek（`harness_native_v1`）网关裁剪（过滤 `blank: true`、保留全部 3 条非空行）并按 `harnessclient.SessionSummary` 重编码的全量无分页毫秒快照 |
| `malformed` | `missing-next-cursor-key.json` 等 5 项 | 缺 `nextCursor` 键、非数组 `data`、空白 ID、非字符串 `cwd`、同页混用秒与毫秒时间戳 |

## 校验命令

```bash
bash ./scripts/test-all-runtimes-phase0-samples.sh
```
