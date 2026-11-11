// thread/desktop/open：在电脑上的 Claude 桌面版里打开并继续这条会话（#726、#991）。
// 桌面版只列自己导入过的会话，SDK 建的会话又被它的批量导入排除；公开的 resume 深链逐条导入，
// 不受这个过滤影响。打开后桌面版会预起自己的进程并登记为持有方，手机端随之转为只读（#658）。
import type { Catalog } from "../claude/catalog.ts";
import { desktopVersionSupported, MINIMUM_DESKTOP_VERSION, resumeDeepLink, type DesktopSystem } from "../claude/desktop.ts";
import type { ClaudeSessions } from "../claude/sdk.ts";
import { RpcError } from "../rpc/frames.ts";
import { ownerSummary, type SessionHolder } from "../runtime/holders.ts";
import type { ThreadManager } from "../runtime/manager.ts";
import { errorText, logger } from "../util/logging.ts";

export type DesktopOpenReason = "unsupported_platform" | "turn_active" | "held_elsewhere" | "not_installed" | "outdated" | "open_failed";

export interface DesktopHandlerDeps {
  manager: Pick<ThreadManager, "get">;
  catalog: Pick<Catalog, "get">;
  sessions: Pick<ClaudeSessions, "rename">;
  holders(): Promise<Map<string, SessionHolder>>;
  desktop: DesktopSystem;
}

/**
 * 桌面版内置 Claude Code 在占用登记里的 entrypoint。配置了第三方模型网关时登记为
 * `claude-desktop-3p`（桌面版 5.12 实测，#991），所以按前缀判断。
 */
export function isDesktopEntrypoint(entrypoint: string | null | undefined): boolean {
  return typeof entrypoint === "string" && entrypoint.startsWith("claude-desktop");
}

function failure(threadId: string, reason: DesktopOpenReason, message: string, extra: Record<string, unknown> = {}): RpcError {
  const retryable = reason !== "unsupported_platform";
  return new RpcError(-32602, message, { accepted: false, reason, threadId, retryable, ...extra });
}

export function createDesktopHandlers(deps: DesktopHandlerDeps) {
  const { manager, catalog, sessions, desktop } = deps;

  /** 这一轮还在跑时不交出：桌面版一接手，适配器就会让出进程，进行中的回合会被中断。 */
  function ensureIdle(threadId: string): void {
    if (manager.get(threadId)?.isBusy()) {
      throw failure(threadId, "turn_active", `thread \`${threadId}\` still has an active turn`);
    }
  }

  return {
    async open(raw: unknown) {
      const params = raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
      const threadId = typeof params.threadId === "string" ? params.threadId.trim() : "";
      if (!threadId) throw RpcError.invalidParams("thread/desktop/open.threadId 不能为空");
      if (desktop.platform !== "darwin") {
        throw failure(threadId, "unsupported_platform", "Claude Desktop handoff is only available on macOS");
      }
      const record = await catalog.get(threadId);
      if (!record) throw RpcError.invalidParams(`找不到 Claude 会话 ${threadId}`);
      ensureIdle(threadId);

      // 终端里的 claude 正持有：桌面版再起一个进程就成了两个写入方。桌面版自己持有说明已经
      // 导入过，深链只会把窗口切到这条会话。
      const holder = (await deps.holders()).get(threadId);
      const alreadyInDesktop = isDesktopEntrypoint(holder?.entrypoint);
      if (holder && !alreadyInDesktop) {
        throw failure(threadId, "held_elsewhere", `thread \`${threadId}\` is held by another local claude process`, {
          claudeOwner: ownerSummary(holder),
        });
      }

      const app = await desktop.findApp();
      if (!app) throw failure(threadId, "not_installed", "Claude Desktop is not installed");
      if (app.version && desktopVersionSupported(app.version) === false) {
        throw failure(threadId, "outdated", `Claude Desktop ${app.version} is too old`, {
          version: app.version,
          minimumVersion: MINIMUM_DESKTOP_VERSION,
        });
      }

      // 与 CLI `/rename` 相同追加一条 custom-title，内容就是 Mimi 现在显示的标题，不改名字本身。
      // 写不成只是桌面版显示 Untitled，不挡打开。
      let titleWritten = false;
      if (!alreadyInDesktop && record.name && record.path && !(await desktop.tailHasCustomTitle(record.path).catch(() => true))) {
        try {
          await sessions.rename(threadId, record.name, record.cwd || undefined);
          titleWritten = true;
        } catch (error) {
          logger.warn("desktop.title_failed", { error: errorText(error) });
        }
      }

      // 先停掉自己的常驻进程，桌面版接手时就看不到另一个持有方。写标题期间可能开始了新一轮，再查一次。
      ensureIdle(threadId);
      const runtime = manager.get(threadId);
      if (runtime?.hasLiveProcess()) await runtime.close();

      const opened = await desktop.openURL(resumeDeepLink(threadId));
      if (!opened.ok) throw failure(threadId, "open_failed", `Couldn't open Claude Desktop: ${opened.detail}`, { detail: opened.detail });
      logger.debug("desktop.opened", { thread: threadId, titleWritten, alreadyInDesktop, version: app.version });
      return { opened: true, titleWritten, alreadyInDesktop, desktopVersion: app.version };
    },
  };
}
