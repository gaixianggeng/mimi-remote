// Claude Code 在 `<配置目录>/sessions/<pid>.json` 登记每个活进程持有的会话。这是唯一
// 没有公开接口的依赖：只读、只用于判断会话是否被终端或桌面端占用（#658 再补接管与让出）。
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { claudeConfigDir } from "../claude/transcripts.ts";

export interface SessionHolder {
  pid: number;
  entrypoint: string | null;
  kind: string | null;
  status: string | null;
  version: string | null;
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

const text = (value: unknown) => (typeof value === "string" && value ? value : null);

/** 会话 ID → 别处的活持有方。`ownPids` 是本适配器自己起的 Claude 进程，不算别处。 */
export async function readHolders(ownPids: ReadonlySet<number>): Promise<Map<string, SessionHolder>> {
  const dir = path.join(claudeConfigDir(), "sessions");
  const holders = new Map<string, SessionHolder>();
  const names = await readdir(dir).catch(() => [] as string[]);
  await Promise.all(
    names
      .filter((name) => name.endsWith(".json"))
      .map(async (name) => {
        const raw = await readFile(path.join(dir, name), "utf8").catch(() => undefined);
        if (!raw) return;
        let record: Record<string, unknown>;
        try {
          record = JSON.parse(raw) as Record<string, unknown>;
        } catch {
          return;
        }
        const pid = Number(record.pid);
        const sessionId = record.sessionId;
        if (!Number.isInteger(pid) || typeof sessionId !== "string" || ownPids.has(pid) || !pidAlive(pid)) return;
        holders.set(sessionId, {
          pid,
          entrypoint: text(record.entrypoint),
          kind: text(record.kind),
          status: text(record.status),
          version: text(record.version),
        });
      }),
  );
  return holders;
}
