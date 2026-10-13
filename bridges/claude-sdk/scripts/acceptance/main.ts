#!/usr/bin/env bun
// Claude 通道实机验收（#655）：经本机 agentd 网关（与 iPhone 同一条路径），对接真实的 Claude CLI
// 与 ~/.claude，逐项检查验收清单并输出报告。会在 agentd 的扫描根目录下临时建一个沙盒仓库
// （mimi-acceptance-<时间>），结束后连同它产生的会话文件一起清理；--keep 保留现场。
//
//   bun scripts/acceptance/main.ts [--only channel,turn,…] [--keep]
//       [--parity-repo <仓库目录>] [--parity-limit <N>] [--report <文件>]
//
// --parity-repo：额外只读对照该仓库最近 N 个已有会话的历史（默认 5 个）。完整历史与 iPhone 共用
// 网关的下行预算，被限流时会等待重试，不要设得太大。
import { existsSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  approvalCase,
  askUserCase,
  autoTitleCase,
  basicTurnCase,
  channelCase,
  modelsCase,
  parityCase,
  quotaCase,
  steerInterruptCase,
  worktreeCase,
  yieldTakeoverCase,
  type CaseOutcome,
  type Context,
  type Status,
} from "./cases.ts";
import { GatewayClient, loadAgentdConfig } from "./gateway.ts";
import { cleanupSandbox, createSandbox, resolveClaudeBin, stopSandboxClaudeProcesses, Terminal } from "./sandbox.ts";

interface Args {
  only: Set<string> | undefined;
  keep: boolean;
  parityRepo: string | undefined;
  parityLimit: number;
  report: string | undefined;
}

function parseArgs(argv: string[]): Args {
  const value = (flag: string) => {
    const index = argv.indexOf(flag);
    return index >= 0 ? argv[index + 1] : undefined;
  };
  const only = value("--only");
  return {
    only: only ? new Set(only.split(",").map((name) => name.trim())) : undefined,
    keep: argv.includes("--keep"),
    parityRepo: value("--parity-repo") ? path.resolve(value("--parity-repo")!) : undefined,
    parityLimit: Number(value("--parity-limit") ?? 5),
    report: value("--report"),
  };
}

const MARK: Record<Status, string> = { pass: "通过", fail: "失败", skip: "跳过" };

async function main(): Promise<number> {
  const args = parseArgs(process.argv.slice(2));
  const config = loadAgentdConfig();
  // 本机网关不走代理；Claude CLI 子进程仍沿用原有代理设置。
  const host = config.listen.replace(/:\d+$/, "").replace(/^\[|\]$/g, "");
  const bypass = [host, "localhost", "127.0.0.1", process.env.NO_PROXY ?? process.env.no_proxy].filter(Boolean).join(",");
  process.env.NO_PROXY = bypass;
  process.env.no_proxy = bypass;

  const scanRoot = config.scanRoots.find((root) => existsSync(root));
  if (!scanRoot) throw new Error("agentd 配置里没有可用的扫描根目录，沙盒仓库必须建在它下面");
  const claudeBin = resolveClaudeBin();
  const sandbox = createSandbox(scanRoot);
  const stamp = path.basename(sandbox.root);
  console.log(`沙盒仓库：${sandbox.root.replace(os.homedir(), "~")}`);

  // 沙盒一建好就进入清理范围：连不上网关或初始化失败也不留下仓库和 worktree。
  const terminal = new Terminal(stamp, claudeBin);
  let client: GatewayClient | undefined;
  const results: Array<{ name: string; title: string; status: Status; detail: string; ms: number }> = [];
  try {
    client = await GatewayClient.connect(config, `acceptance-${process.pid}`);
    await client.initialize();
    const ctx: Context = {
      config,
      sandbox,
      claudeBin,
      client,
      terminal,
      created: [],
      cwdOf: new Map(),
      parityRepo: args.parityRepo,
      parityLimit: args.parityLimit,
    };

    let rootThread: string | undefined;
    const cases: Array<{ name: string; title: string; run: () => Promise<CaseOutcome> }> = [
      { name: "channel", title: "Claude 通道接的是新适配器且健康", run: () => channelCase(ctx) },
      { name: "models", title: "模型列表", run: () => modelsCase(ctx) },
      {
        name: "turn",
        title: "发消息与流式回复",
        run: async () => {
          const outcome = await basicTurnCase(ctx);
          rootThread = outcome.threadId;
          return outcome;
        },
      },
      { name: "quota", title: "额度（会话里上报）", run: () => quotaCase(ctx) },
      { name: "title", title: "新会话自动标题（Mimi 与 CLI 一致）", run: () => autoTitleCase(ctx, rootThread) },
      { name: "worktrees", title: "worktree 会话出现在所属仓库（含 CLI 建的）", run: () => worktreeCase(ctx, rootThread) },
      { name: "steer", title: "运行中补充与中断", run: () => steerInterruptCase(ctx) },
      { name: "approvals", title: "命令审批（允许与拒绝）", run: () => approvalCase(ctx) },
      { name: "ask", title: "Claude 提问", run: () => askUserCase(ctx) },
      { name: "ownership", title: "终端接手时让出、恢复与接管", run: () => yieldTakeoverCase(ctx) },
      { name: "parity", title: "历史与 CLI 视图一致", run: () => parityCase(ctx) },
    ];

    for (const item of cases) {
      if (args.only && !args.only.has(item.name)) continue;
      const started = Date.now();
      process.stdout.write(`▶ ${item.title} … `);
      let outcome: CaseOutcome;
      try {
        outcome = await item.run();
      } catch (error) {
        outcome = { status: "fail", detail: error instanceof Error ? error.message : String(error) };
      }
      const ms = Date.now() - started;
      results.push({ name: item.name, title: item.title, status: outcome.status, detail: outcome.detail, ms });
      console.log(`${MARK[outcome.status]}（${(ms / 1000).toFixed(1)} 秒）\n    ${outcome.detail}`);
    }
  } finally {
    terminal.kill();
    client?.close();
    if (args.keep) {
      console.log(`保留沙盒：${sandbox.root}`);
    } else {
      const stopped = await stopSandboxClaudeProcesses(sandbox);
      const removed = cleanupSandbox(sandbox, scanRoot);
      console.log(`已结束 ${stopped} 个沙盒里的 Claude 进程，清理沙盒与 ${removed.length} 个相关目录`);
    }
  }

  const counts = { pass: 0, fail: 0, skip: 0 } as Record<Status, number>;
  for (const result of results) counts[result.status] += 1;
  console.log(`\n结果：通过 ${counts.pass}，失败 ${counts.fail}，跳过 ${counts.skip}`);
  const reportPath = args.report ?? path.join(os.tmpdir(), `${stamp}.json`);
  writeFileSync(reportPath, `${JSON.stringify({ at: new Date().toISOString(), sandbox: stamp, results }, null, 2)}\n`);
  console.log(`报告：${reportPath}`);
  return counts.fail > 0 ? 1 : 0;
}

main()
  .then((code) => process.exit(code))
  .catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(2);
  });
