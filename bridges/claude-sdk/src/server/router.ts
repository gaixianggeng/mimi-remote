import { ErrorCode, RpcError, errorFrame, resultFrame, type OutboundFrame, type RpcRequest } from "../rpc/frames.ts";
import type { Session } from "../session/session.ts";

export interface RequestContext {
  session: Session;
  generation: number;
}

export type Handler = (params: unknown, context: RequestContext) => Promise<unknown> | unknown;

export type Logger = (message: string) => void;

/** 方法表分发。未实现的方法明确返回 methodNotFound，便于客户端降级。 */
export class Router {
  constructor(
    private readonly handlers: ReadonlyMap<string, Handler>,
    private readonly log: Logger,
  ) {}

  has(method: string): boolean {
    return this.handlers.has(method);
  }

  methods(): string[] {
    return [...this.handlers.keys()].sort();
  }

  async dispatch(request: RpcRequest, context: RequestContext): Promise<OutboundFrame> {
    const handler = this.handlers.get(request.method);
    if (!handler) {
      return errorFrame(request.id, {
        code: ErrorCode.methodNotFound,
        message: `mimi-claude-adapter 尚不支持方法 ${request.method}`,
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
      return errorFrame(request.id, { code: ErrorCode.internalError, message });
    }
  }
}
