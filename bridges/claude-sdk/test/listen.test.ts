// 监听参数与旧 bridge 一致：Unix socket 或回环 TCP 二选一，TCP 只接受回环 IP 字面量。
import { describe, expect, test } from "bun:test";
import { parseListenArgs, parseTcpAddress } from "../src/server/listen.ts";

describe("listen arguments", () => {
  test("no transport flag means stdio; each flag needs a value and only one may be given", () => {
    expect(parseListenArgs([])).toBeUndefined();
    expect(parseListenArgs(["--socket", "/tmp/a.sock"])).toEqual({ kind: "unix", path: "/tmp/a.sock" });
    expect(parseListenArgs(["--tcp-listen", "127.0.0.1:0"])).toEqual({ kind: "tcp", host: "127.0.0.1", port: 0 });
    expect(() => parseListenArgs(["--socket"])).toThrow("--socket 需要路径参数");
    expect(() => parseListenArgs(["--tcp-listen"])).toThrow("--tcp-listen 需要");
    expect(() => parseListenArgs(["--socket", "/tmp/a.sock", "--tcp-listen", "127.0.0.1:1"])).toThrow("只能选一个");
  });

  test("tcp addresses must be loopback IP literals with a valid port", () => {
    expect(parseTcpAddress("127.8.9.10:65535")).toEqual({ kind: "tcp", host: "127.8.9.10", port: 65_535 });
    expect(parseTcpAddress("[::1]:9")).toEqual({ kind: "tcp", host: "::1", port: 9 });
    expect(parseTcpAddress("[0:0:0:0:0:0:0:1]:9")).toMatchObject({ host: "0:0:0:0:0:0:0:1" });
    for (const outside of ["0.0.0.0:1", "192.168.1.2:1", "[::]:1", "[::ffff:127.0.0.1]:1"]) {
      expect(() => parseTcpAddress(outside)).toThrow("只能使用回环地址");
    }
    for (const invalid of ["localhost:1", "127.0.0.1", "127.0.0.1:70000", "::1:9", "[::1]", "127.0.0.1:-1"]) {
      expect(() => parseTcpAddress(invalid)).toThrow("地址无效");
    }
  });
});
