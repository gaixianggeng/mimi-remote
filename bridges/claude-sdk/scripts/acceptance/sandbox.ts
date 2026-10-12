// 验收用的沙盒：扫描根目录下的临时 Git 仓库（含兄弟 worktree 与 .claude/worktrees 里的
// worktree）、tmux 里的交互式 claude（模拟用户在终端接手），以及收尾清理。只删除本脚本
// 创建的路径，删除前核对前缀。
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export const SANDBOX_PREFIX = "mimi-acceptance-";

export interface Sandbox {
  root: string;
  sibling: string;
  nested: string;
}

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-c", "user.name=mimi-acceptance", "-c", "user.email=acceptance@localhost", ...args], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function createSandbox(scanRoot: string): Sandbox {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "").replace("T", "-");
  const root = path.join(scanRoot, `${SANDBOX_PREFIX}${stamp}`);
  if (existsSync(root)) throw new Error(`沙盒目录已存在：${root}`);
  execFileSync("mkdir", ["-p", root]);
  git(root, "init", "-q", "-b", "main");
  git(root, "commit", "-q", "--allow-empty", "-m", "acceptance sandbox");
  const sibling = `${root}-wt`;
  const nested = path.join(root, ".claude", "worktrees", "acceptance-nested");
  git(root, "worktree", "add", "-q", "-b", "acceptance-sibling", sibling);
  git(root, "worktree", "add", "-q", "-b", "acceptance-nested", nested);
  return { root, sibling, nested };
}

export const claudeConfigDir = () => process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const encodeProjectDir = (dir: string) => dir.replace(/[^a-zA-Z0-9]/g, "-");

/** 找到会话的 transcript 文件（任意项目目录下）。 */
export function transcriptPath(sessionId: string): string | undefined {
  const projects = path.join(claudeConfigDir(), "projects");
  for (const dir of readdirSync(projects)) {
    const file = path.join(projects, dir, `${sessionId}.jsonl`);
    if (existsSync(file)) return file;
  }
  return undefined;
}

/** 分叉点：同一个父节点下出现多个对话子节点（排除侧链）。CLI 恢复中断回合时也会自己补一个。 */
export function forkPoints(sessionId: string): number {
  const file = transcriptPath(sessionId);
  if (!file) return -1;
  const children = new Map<string, number>();
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let record: any;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (!record.uuid || record.isSidechain || (record.type !== "user" && record.type !== "assistant")) continue;
    const parent = record.parentUuid ?? "<root>";
    children.set(parent, (children.get(parent) ?? 0) + 1);
  }
  return [...children.values()].filter((count) => count > 1).length;
}

export function resolveClaudeBin(): string {
  const configured = process.env.CLAUDE_BRIDGE_CLAUDE_BIN?.trim();
  if (configured) return configured;
  return Bun.which("claude") ?? path.join(os.homedir(), ".local", "bin", "claude");
}

/** 用 CLI 的打印模式在 cwd 里建一个会话（模拟用户直接在终端用 claude），返回会话 ID。 */
export function claudePrint(claudeBin: string, cwd: string, prompt: string): string {
  const result = spawnSync(claudeBin, ["-p", prompt, "--model", "haiku", "--output-format", "json"], {
    cwd,
    encoding: "utf8",
    timeout: 180_000,
  });
  if (result.status !== 0) throw new Error(`claude -p 失败（退出码 ${result.status}）`);
  const sessionId = JSON.parse(result.stdout).session_id;
  if (typeof sessionId !== "string") throw new Error("claude -p 没有返回 session_id");
  return sessionId;
}

const tmux = (...args: string[]) => spawnSync("tmux", args, { encoding: "utf8" });
const shellQuote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;

/** tmux 里的交互式 claude，模拟用户在 Mac 终端里接手会话。 */
export class Terminal {
  constructor(
    readonly name: string,
    private readonly claudeBin: string,
  ) {}

  start(cwd: string, args: string[]): void {
    this.kill();
    // claude 退出后保留屏幕和退出码，失败时能看到它打印了什么。
    const command = `${[this.claudeBin, ...args].map(shellQuote).join(" ")}; echo "[claude exited $?]"; sleep 120`;
    const result = tmux("new-session", "-d", "-s", this.name, "-x", "160", "-y", "40", "-c", cwd, command);
    if (result.status !== 0) throw new Error(`tmux 启动失败：${result.stderr.trim()}`);
  }

  pane(): string {
    return tmux("capture-pane", "-p", "-t", this.name).stdout ?? "";
  }

  /** 终端里的 claude 是否还在运行（tmux 会话在它退出后还保留着屏幕）。 */
  alive(): boolean {
    return tmux("has-session", "-t", this.name).status === 0 && !this.pane().includes("[claude exited");
  }

  /**
   * 等交互式 claude 就绪。新目录第一次打开会问是否信任（验收沙盒是本脚本建的，选「信任」）；
   * 就绪的标志是底部状态栏（「? for shortcuts」或「⏵⏵ … shift+tab to cycle」），不能只看
   * 「❯」：信任对话框的选择箭头也是它。
   */
  async waitUntilReady(timeoutMs = 30_000): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline && this.alive()) {
      const pane = this.pane();
      if (/trust this folder|do you trust/i.test(pane) && /Enter to confirm/i.test(pane)) {
        // 对话框刚出现时可能还不接收按键：看着屏幕操作，箭头到了「信任」那一项才确认，
        // 否则回车会选中默认的「No, exit」，claude 直接退出。
        if (/❯\s*Yes, I trust this folder/.test(pane)) {
          tmux("send-keys", "-t", this.name, "Enter");
        } else {
          await Bun.sleep(500);
          tmux("send-keys", "-t", this.name, "Down");
        }
      } else if (/\? for shortcuts|shift\+tab to cycle/i.test(pane)) {
        return true;
      }
      await Bun.sleep(400);
    }
    return false;
  }

  async prompt(text: string): Promise<void> {
    tmux("send-keys", "-t", this.name, "-l", text);
    await Bun.sleep(1_000);
    tmux("send-keys", "-t", this.name, "Enter");
  }

  async exit(timeoutMs = 15_000): Promise<void> {
    await this.prompt("/exit");
    const deadline = Date.now() + timeoutMs;
    while (this.alive() && Date.now() < deadline) await Bun.sleep(200);
    this.kill();
  }

  kill(): void {
    if (tmux("has-session", "-t", this.name).status === 0) tmux("kill-session", "-t", this.name);
  }
}

/**
 * 结束工作目录在沙盒里的 Claude 进程（适配器给会话保留的空闲进程等）。CLI 退出时会往
 * transcript 补写几条记录，不先等它们退出，删掉的会话目录会被写回来。
 */
export async function stopSandboxClaudeProcesses(sandbox: Sandbox, timeoutMs = 15_000): Promise<number> {
  const sessions = path.join(claudeConfigDir(), "sessions");
  const pids: number[] = [];
  for (const name of existsSync(sessions) ? readdirSync(sessions) : []) {
    if (!name.endsWith(".json")) continue;
    try {
      const record = JSON.parse(readFileSync(path.join(sessions, name), "utf8"));
      const cwd = String(record.cwd ?? "");
      if (cwd === sandbox.root || cwd.startsWith(`${sandbox.root}${path.sep}`) || cwd === sandbox.sibling || cwd.startsWith(`${sandbox.sibling}${path.sep}`)) {
        pids.push(Number(record.pid));
      }
    } catch {
      // 损坏或正在写入的登记，跳过。
    }
  }
  const alive = (pid: number) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  for (const pid of pids) {
    if (Number.isInteger(pid) && pid > 1 && alive(pid)) process.kill(pid, "SIGTERM");
  }
  const deadline = Date.now() + timeoutMs;
  while (pids.some(alive) && Date.now() < deadline) await Bun.sleep(200);
  return pids.length;
}

/** 删除沙盒仓库、worktree 与它们产生的会话文件。只认本脚本创建的路径。 */
export function cleanupSandbox(sandbox: Sandbox, scanRoot: string): string[] {
  const removed: string[] = [];
  const guard = (target: string) => {
    if (!path.basename(target).startsWith(SANDBOX_PREFIX) && !target.startsWith(`${sandbox.root}${path.sep}`)) {
      throw new Error(`拒绝删除非沙盒路径：${target}`);
    }
    if (!target.startsWith(`${scanRoot}${path.sep}`)) throw new Error(`拒绝删除扫描根目录以外的路径：${target}`);
  };
  for (const worktree of [sandbox.nested, sandbox.sibling]) {
    try {
      git(sandbox.root, "worktree", "remove", "--force", worktree);
    } catch {
      // 已经不在了。
    }
  }
  for (const dir of [sandbox.sibling, sandbox.root]) {
    guard(dir);
    if (existsSync(dir)) {
      rmSync(dir, { recursive: true, force: true });
      removed.push(dir);
    }
  }
  const projects = path.join(claudeConfigDir(), "projects");
  for (const dir of [sandbox.root, sandbox.sibling, sandbox.nested]) {
    const projectDir = path.join(projects, encodeProjectDir(dir));
    if (existsSync(projectDir)) {
      rmSync(projectDir, { recursive: true, force: true });
      removed.push(projectDir);
    }
  }
  return removed;
}
