import type { Readable, Writable } from "node:stream";
import {
  ATTACHED_METHOD,
  ATTACH_METHOD,
  serveConnection as serveBaseConnection,
  type ConnectionDeps as BaseConnectionDeps,
} from "@mimi/appserver-kit/server/connection.ts";
import { structuredAdapterLogger } from "../util/logging.ts";

export { ATTACHED_METHOD, ATTACH_METHOD };
export type ConnectionDeps = Omit<BaseConnectionDeps, "structuredLogger">;

export function serveConnection(input: Readable, output: Writable, deps: ConnectionDeps): Promise<void> {
  return serveBaseConnection(input, output, {
    ...deps,
    structuredLogger: structuredAdapterLogger,
  });
}
