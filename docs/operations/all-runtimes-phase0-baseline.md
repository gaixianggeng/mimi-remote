# 工作区会话列表支持「全部运行时」Phase 0：现网采样与性能基线报告

> **范围界定**：本报告与同 PR 交付物严格限定为脱敏现网实录、可复跑性能基准脚本与基线数据，**不修改任何产品代码行为**。未来契约夹具（如 `pageDisposition: "same_page_retry"`、4 状态 `listMeta` 等）按评审关闭清单在方案 P1 修订定稿后随后续阶段提交。

## 1. 基线提交与组件版本

| 维度 | 基线值 |
|---|---|
| 基线提交 | `2c6342fb`（`origin/main`） |
| 宿主机环境（脱敏） | Apple M5 Pro（18 核，48 GiB 内存），macOS 27.3（arm64），本机空闲态无并行构建 |
| Go 工具链 | `go1.25.14 darwin/arm64` |
| Bun 运行时 | `1.2.22` |
| Node 运行时 | `v24.22.3` |
| Rust / Cargo | `cargo 1.100.0` |
| Codex CLI | `codex-cli 0.171.0`（仓库协议快照 `0.162.0`） |
| Claude SDK 适配器 | `mimi-claude-adapter/0.3.0`（`@anthropic-ai/claude-agent-sdk@0.3.296`） |
| Claude Legacy Rust 桥接 | `alleycat-claude-bridge/0.2.15` |
| Antigravity ACP 适配器 | `mimi-agy-adapter/0.1.0` |
| DeepSeek Harness 快照 | `@deepseek-ai/dsh@0.1.5-rc.2`（`harness_native_v1`） |

## 2. 脱敏现网实录覆盖与观察结论

所有脱敏实录与畸形拒绝样本均存放在 `scripts/testdata/all-runtimes-phase0/`，路径统一脱敏为 `/Users/demo/...`，不含任何真实用户名、本机路径、Token、私钥、Tailscale 地址或真实用户会话内容。

| 分组 | 夹具文件 | 实测 / 现网核心观察（`2c6342fb`） |
|---|---|---|
| `accepted` | `accepted/gateway-global-unmarked-same-page-retry.json` | Go 网关 Controlled Global 在 browse-root Git 归属判定超过 300ms 时，裁剪未判定工作树行并返回无 `listMeta`、无 `pageDisposition` 的不透明 `mimi_*` 重试游标；次轮重试补出更晚条目（`1775815600 > 1775815200`）；且 `copyGatewayRawFields` 当前裁剪 `cliVersion` |
| `accepted` | `accepted/claude-sdk-empty-cwd.json` | `mimi-claude-adapter/0.3.0` 合法输出 `cwd: ""` 与正常行同页，时间戳为 Unix 秒（`< 1e10`），`recencyAt: null`，同秒按 `id DESC` 排序 |
| `accepted` | `accepted/claude-legacy-rust-ms.json` | `alleycat-claude-bridge/0.2.15` 输出真实 Unix 毫秒时间戳（`>= 1e10`），同毫秒降序按 `thread_id ASC` 跨页切分，游标为无填充 base64url `{"ts":<ms>,"id":<id>}`，响应省略 `recencyAt` |
| `accepted` | `accepted/codex-recency-at-null.json` | `codex-cli 0.171.0` 协议 Schema（`v2/ThreadListResponse.json`）声明 `recencyAt: int64 \| null`，`createdAt`/`updatedAt` 为 Unix 秒；`sortKey: "recency_at"` 下可出现 `recencyAt: null`（旧记录/缺值）与 StateDB 未回填 `recencyAt: 0` |
| `accepted` | `accepted/agy-acp-current-list.json` | `mimi-agy-adapter/0.1.0` 当前响应不含 `listMeta`，时间戳为 Unix 秒、`recencyAt: null`，通过 `source: "cli"` 与 `{"custom":"other"}` 区分来源，缺失目录标记 `cwdMissing: true`、`canAcceptDirectInput: false` |
| `accepted` | `accepted/deepseek-harness-session-list.json` | `harness_native_v1` `session/list` 返回全量毫秒快照（`items[]`），无服务端分页游标，由网关过滤 `blank: true` 与缺 `cwd` 行后按 `updatedAt` 稳定降序 |
| `malformed` | `malformed/*.json`（5 项） | 覆盖缺 `nextCursor` 键、非数组 `data`、空白线程 ID、非字符串 `cwd`、同页混用秒与毫秒时间戳，供校验脚本 100% 显式拒绝 |

校验命令：

```bash
bash ./scripts/test-all-runtimes-phase0-samples.sh
```

校验结果：`accepted=6/6`、`malformed_rejected=5/5`、`coverage=6/6`、`sanitization=clean`。

## 3. 可复跑性能基准与复现命令

### 3.1 统一复现命令

```bash
bash ./scripts/bench-all-runtimes-phase0.sh --seed 20260410 --batches 3 --cold 5 --warm 20
```

- 入口脚本：`scripts/bench-all-runtimes-phase0.sh`
- Antigravity 基准：`scripts/bench-agy-acp-list.ts`（通过临时 `PATH` 真实 `git` 包装器精确计数 OS 级 `git` spawn，零侵入产品源码）
- Claude SDK 基准：`scripts/bench-claude-sdk-list.ts`（在隔离临时 `CLAUDE_CONFIG_DIR` 运行真实 `@anthropic-ai/claude-agent-sdk` `listSessions`、`TranscriptIndex`、`ActivityClock`、`WorkingDirectories`、`Overlay`、`Catalog` 与 `createThreadHandlers`）

### 3.2 Antigravity（`bridges/agy-acp`）基线数据

**固定种子数据集（`seed=20260410`）**：500 条全局会话摘要（30 条目标仓会话分布于主仓、2 个 worktree、symlink 与 `file://` 百分号编码路径；360 条其他 12 个 Git 仓及 6 个 worktree 会话；50 条非 Git 目录会话含编码 URI；30 条缺失目录会话；30 条无 `.db` 孤儿会话）。非孤儿唯一原始 `cwd` 为 `33` 个，经 `normalizeNativeCwd` 规范化后参与 `git.inspect` 的唯一目录为 `32` 个（其中磁盘存在 `28` 个 + 缺失目录 `4` 个在 `matchesAnyRoot` 中仍触发 `git.inspect`）。

**执行方式**：连续 3 批，每批先跑 5 次并发冷查（每次清进程内缓存，4 路并发触发目标仓 `thread/list`），再预热 30s Git 缓存后顺序跑 20 次目标仓 `thread/list`。

| 批次 | 并发冷查（x4, n=5）`git` spawn / 轮 | 并发冷查 p50 (ms) | 并发冷查 p95 (ms) | 顺序热态（n=20）`git` spawn 绝对次数 | 顺序热态 ACP RPC 增量 | 顺序热态 p50 (ms) | 顺序热态 p95 (ms) | 顺序热态 max (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Batch 1 | `128`（5 轮共 `640`） | 462.372 | 831.025 | `0` | `0` | 16.804 | 18.922 | 19.642 |
| Batch 2 | `128`（5 轮共 `640`） | 468.518 | 469.076 | `0` | `0` | 16.106 | 17.022 | 17.643 |
| Batch 3 | `128`（5 轮共 `640`） | 458.680 | 473.546 | `0` | `0` | 17.227 | 18.326 | 19.261 |
| **3 批汇总** | **均值 `128` / 轮（总 `1920`）** | **均值 463.190** | **均值 591.216** | **绝对 `0`（60 次共 `0`）** | **绝对 `0`** | **均值 16.712** | **均值 18.090（批间波动 11.16%）** | **max 19.642** |

**基线洞察（对应 Phase 1 门禁）**：
1. **并发冷查放大效应明确**：`GitRepoIndex` 当前缺少在途合并（`inflight` Map），4 路并发冷查对 32 个唯一规范化目录产生了精确 `4 × 32 = 128` 次真实 `git` spawn；Phase 1 引入 `inflight` 合并与先筛选唯一 `cwd` 后，目标为单轮 `<=` 唯一候选 `cwd` 数且降幅 `>= 50%`。
2. **顺序热态缓存与残留瓶颈分离清晰**：在 30s Git TTL 与 1.5s `cachedList` 窗口内，顺序热态的 `git` spawn 绝对次数与 ACP RPC 增量均为 `0`；但热态 p95 仍达 `18.090ms`（批间波动 `11.16% <= 15%`），瓶颈来自每次 `AgyCatalog.list()` 逐条串行执行 `resolveSessionOrigin`（`access()`）与 `directoryExists`（`stat()`），Phase 1 批量来源索引与唯一 `cwd` 筛选将据此核验 `>= 30%` 改善。

### 3.3 Claude SDK（`bridges/claude-sdk`）200+ 会话分页基线数据

**固定种子数据集（`seed=20260410`）**：目标 Git 仓（含主仓 + 2 个 worktree）共 `240` 条真实合成 JSONL transcript 会话，另含 `40` 条其他项目会话（共 `280` 个 `.jsonl` 文件），每页 `limit = 20`，按 `updated_at DESC` 翻页。

**执行方式**：连续 3 批，每批跑 5 次冷态（新建 `TranscriptIndex`/`ActivityClock`/`WorkingDirectories`/`Overlay`/`Catalog` 后依次读第 1 页与第 2 页）与 20 次热态第 2 页连续读取。

| 批次 | 冷首屏 p95 (ms) | 冷次页 p95 (ms) | 热态次页 p50 (ms) | 热态次页 p95 (ms) | 热态次页 max (ms) | `prepare` 均值 (ms) | `sessions.list` 均值 (ms) | `toRecord` 均值 (ms) | `filter+sort+cursor` 均值 (ms) | `live+toThread` 均值 (ms) | 目录处理（`sessions.list+toRecord+sort`）均值与占比 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Batch 1 | 27.510 | 21.262 | 20.189 | 21.094 | 21.884 | 0.009 | 20.168 | 0.145 | 0.044 | 0.018 | 20.357ms（**99.81%**） |
| Batch 2 | 26.724 | 21.237 | 19.563 | 21.126 | 21.622 | 0.010 | 19.461 | 0.128 | 0.039 | 0.014 | 19.628ms（**99.83%**） |
| Batch 3 | 24.952 | 19.756 | 19.859 | 20.927 | 21.004 | 0.009 | 19.722 | 0.131 | 0.036 | 0.014 | 19.889ms（**99.82%**） |
| **3 批汇总** | **均值 26.395** | **均值 20.752** | **均值 19.870** | **均值 21.049（波动 0.95%）** | **max 21.884** | **0.009** | **19.784** | **0.135** | **0.040** | **0.015** | **19.958ms（99.82%）** |

### 3.4 Claude 有序快照缓存阈值结论

按方案 Phase 0 锁定阈值：**热态第 2 页 p95 `> 30ms` 且 `> 50%` 耗时来自 `sessions.list + toRecord + sort`**。

- **目录处理耗时占比**：`99.82%`（远超 `50%`，其中 `sessions.list` 自身占总耗时约 `99.0%`）；
- **热态第 2 页 p95**：3 批均值 `21.049ms`、批最大值 `21.126ms`（批间波动仅 `0.95%`），**未超过 `30ms` 阈值**；
- **结论**：`triggered = false`。Phase 2 独立交付 O(log N) 二分游标定位即可；条件有序快照缓存与 `ActivityClock` 完整窗口校验保持在独立跟进 Issue 中，不阻塞主链路 Phase 5 交付（若后续超大规模工作区或低速盘场景实测热态次页 p95 越过 `30ms`，再按同一基准脚本触发并走 `full` 验证）。
