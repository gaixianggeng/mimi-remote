// agentd 托管时的监听方式，与旧 bridge 相同：Unix 上 `--socket <路径>`，Windows 上
// `--tcp-listen <回环 IP>:<端口>`（agentd 先占一个回环端口再交给适配器）。两者只能选一个。
// TCP 只接受回环 IP 字面量，和旧 bridge 一样不另加鉴权，靠只在本机可达守住边界。
import net from "node:net";

export type ListenTarget = { kind: "unix"; path: string } | { kind: "tcp"; host: string; port: number };

/** 没有指定监听方式时返回 undefined（标准输入输出模式）。 */
export function parseListenArgs(argv: string[]): ListenTarget | undefined {
  let target: ListenTarget | undefined;
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag !== "--socket" && flag !== "--tcp-listen") continue;
    const value = argv[index + 1];
    if (!value) throw new Error(flag === "--socket" ? "--socket 需要路径参数" : "--tcp-listen 需要 IP:端口 参数");
    if (target) throw new Error("--socket 与 --tcp-listen 只能选一个");
    target = flag === "--socket" ? { kind: "unix", path: value } : parseTcpAddress(value);
    index += 1;
  }
  return target;
}

/** `127.0.0.1:1234` 或 `[::1]:1234`。主机必须是回环 IP 字面量，端口 0 表示由系统分配。 */
export function parseTcpAddress(raw: string): ListenTarget {
  const match = /^(?:\[([^\]]+)\]|([^:[\]]+)):(\d{1,5})$/.exec(raw.trim());
  const host = match?.[1] ?? match?.[2];
  const port = Number(match?.[3]);
  if (!host || !net.isIP(host) || port > 65_535) throw new Error(`--tcp-listen 地址无效：${raw}`);
  if (!isLoopback(host)) throw new Error(`--tcp-listen 只能使用回环地址，收到 ${raw}`);
  return { kind: "tcp", host, port };
}

function isLoopback(host: string): boolean {
  if (net.isIPv4(host)) return host.split(".")[0] === "127";
  // IPv6 只有 ::1 一个回环地址；URL 会把各种写法规范成同一形式。
  return new URL(`http://[${host}]/`).hostname === "[::1]";
}

/** 日志里的监听位置。 */
export function describeListen(target: ListenTarget, address: string | net.AddressInfo | null): string {
  if (target.kind === "unix") return target.path;
  if (address && typeof address === "object") return `${address.family === "IPv6" ? `[${address.address}]` : address.address}:${address.port}`;
  return `${target.host}:${target.port}`;
}
