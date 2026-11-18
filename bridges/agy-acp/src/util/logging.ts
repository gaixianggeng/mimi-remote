import {
  createAdapterLogger,
  errorText,
  type LogFields,
  type LogLevel,
} from "@mimi/appserver-kit/util/logging.ts";
import { ADAPTER_NAME } from "../version.ts";

export { errorText, type LogFields, type LogLevel };

const adapterLogger = createAdapterLogger({
  adapterName: ADAPTER_NAME,
  logEnvVar: "MIMI_AGY_ADAPTER_LOG",
  traceEnvVar: "MIMI_AGY_ADAPTER_TRACE",
});

export const configureLogging = adapterLogger.configureLogging;
export const logEnabled = adapterLogger.logEnabled;
export const formatLogLine = adapterLogger.formatLogLine;
export const logText = adapterLogger.logText;
export const logger = {
  error: adapterLogger.error,
  warn: adapterLogger.warn,
  info: adapterLogger.info,
  debug: adapterLogger.debug,
  trace: adapterLogger.trace,
};
