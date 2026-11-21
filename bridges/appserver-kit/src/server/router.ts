import { ErrorCode, RpcError, errorFrame, resultFrame, type OutboundFrame, type RpcRequest } from "../rpc/frames.ts";
import type { Session } from "../session/session.ts";
import { errorText, type AdapterLogger } from "../util/logging.ts";

export interface RequestContext {
  session: Session;
  generation: number;
}

export type Handler = (params: unknown, context: RequestContext) => Promise<unknown> | unknown;

export type Logger = (message: string) => void;

export interface RouterOptions {
  adapterName?: string;
  structuredLogger?: Pick<AdapterLogger, "logEnabled" | "debug" | "warn">;
}

/** 方法表分发。未实现的方法明确返回 methodNotFound，便于客户端降级。 */
export class Router {
  private readonly adapterName: string;
  private readonly structuredLogger: Pick<AdapterLogger, "logEnabled" | "debug" | "warn"> | undefined;

  constructor(
    private readonly handlers: ReadonlyMap<string, Handler>,
    private readonly log: Logger,
    options: RouterOptions = {},
  ) {
    this.adapterName = options.adapterName ?? "mimi-adapter";
    this.structuredLogger = options.structuredLogger;
  }

  has(method: string): boolean {
    return this.handlers.has(method);
  }

  methods(): string[] {
    return [...this.handlers.keys()].sort();
  }

  async dispatch(request: RpcRequest, context: RequestContext): Promise<OutboundFrame> {
    const started = performance.now();
    const response = await this.route(request, context);
    if (this.structuredLogger?.logEnabled("debug")) {
      const code = (response as { error?: { code?: number } }).error?.code;
      this.structuredLogger.debug("rpc", {
        method: request.method,
        id: String(request.id),
        session: context.session.key,
        ms: Math.round(performance.now() - started),
        ...(code === undefined ? {} : { error: code }),
      });
    }
    return response;
  }

  private async route(request: RpcRequest, context: RequestContext): Promise<OutboundFrame> {
    const handler = this.handlers.get(request.method);
    if (!handler) {
      return errorFrame(request.id, {
        code: ErrorCode.methodNotFound,
        message: `${this.adapterName} 尚不支持方法 ${request.method}`,
      });
    }
    try {
      return resultFrame(request.id, await handler(request.params ?? {}, context));
    } catch (error) {
      if (error instanceof RpcError) {
        return errorFrame(request.id, {
          code: error.code,
          message: error.message,
          ...(error.data === undefined ? {} : { data: error.data }),
        });
      }
      const message = error instanceof Error ? error.message : String(error);
      this.log(`method ${request.method} failed: ${message}`);
      this.structuredLogger?.warn("rpc.failed", { method: request.method, error: errorText(error) });
      return errorFrame(request.id, { code: ErrorCode.internalError, message });
    }
  }
}
