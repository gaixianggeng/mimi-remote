import {
  Router as BaseRouter,
  type Handler,
  type Logger,
  type RequestContext,
} from "@mimi/appserver-kit/server/router.ts";
import { structuredAdapterLogger } from "../util/logging.ts";
import { ADAPTER_NAME } from "../version.ts";

export type { Handler, Logger, RequestContext };

export class Router extends BaseRouter {
  constructor(handlers: ReadonlyMap<string, Handler>, log: Logger) {
    super(handlers, log, {
      adapterName: ADAPTER_NAME,
      structuredLogger: structuredAdapterLogger,
    });
  }
}
