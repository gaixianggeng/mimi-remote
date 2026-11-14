using System.Net;
using System.Text;
using System.Text.Json;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class LocalSessionSourceTests
{
    [Fact]
    public async Task 仅本机获取凭据随后使用受控列表且不建立具名连接()
    {
        var claims = 0;
        var calls = new List<(string Method, JsonElement Parameters)>();
        var channels = new List<Channel>();
        using var http = new HttpClient(new Handler(async request =>
        {
            Assert.Equal("127.0.0.1", request.RequestUri!.Host);
            Assert.Equal(9999, request.RequestUri.Port);
            if (request.RequestUri.AbsolutePath == "/api/pair/local")
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Assert.Equal("1", Assert.Single(request.Headers.GetValues("X-Mimi-Local-Pairing")));
                Assert.False(request.Headers.Contains("Origin"));
                Assert.Null(request.Headers.Authorization);
                claims++;
                return Response("""{"token":"fixture-only"}""");
            }
            Assert.Equal("Bearer fixture-only", request.Headers.Authorization!.ToString());
            if (request.RequestUri.AbsolutePath == "/api/app-server/config")
            {
                return Response("""{"channels":[{"runtime_id":"codex","enabled":true},{"runtime_id":"claude","enabled":true},{"runtime_id":"deepseek","enabled":true,"protocol":"harness_native_v1"}]}""");
            }
            if (request.RequestUri.AbsolutePath == "/api/projects") { return Response("""{"projects":[{"name":"repo","path":"C:\\repo"}]}"""); }
            Assert.Equal("/api/harness/rpc", request.RequestUri.AbsolutePath);
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            Assert.Equal("session/list", body.RootElement.GetProperty("method").GetString());
            Assert.True(body.RootElement.GetProperty("args").TryGetProperty("_request", out _));
            Assert.Equal(@"C:\repo", body.RootElement.GetProperty("cwd").GetString());
            Assert.False(body.RootElement.GetProperty("args").TryGetProperty("cwd", out _));
            return Response("""{"result":{"ok":true,"value":{"items":[{"sessionId":"native","cwd":"C:\\repo","running":false,"projections":{"values":{"title":"原生标题"}}}]}}}""");
        }));
        using var source = new LocalSessionSource(9999, http, (uri, credential, _) =>
        {
            Assert.Equal("ws", uri.Scheme);
            Assert.Equal("127.0.0.1", uri.Host);
            Assert.Equal("/api/app-server/ws", uri.AbsolutePath);
            Assert.Equal("?runtime=codex", uri.Query);
            Assert.Equal("fixture-only", credential);
            var channel = new Channel(calls);
            channels.Add(channel);
            return Task.FromResult<IDesktopRpcChannel>(channel);
        });
        var catalog = await source.CatalogAsync(CancellationToken.None);
        Assert.Equal(["codex", "claude", "deepseek"], catalog.Runtimes);
        Assert.Equal(@"C:\repo", Assert.Single(catalog.Projects).Cwd);
        var first = await source.ListAsync("codex", null, 1, CancellationToken.None);
        Assert.True(first.HasMore);
        Assert.Single(first.Sessions);
        Assert.All(channels, channel => Assert.True(channel.Disposed));
        var parameters = calls.First(call => call.Method == "thread/list").Parameters;
        Assert.True(parameters.TryGetProperty("sourceKinds", out _));
        Assert.False(parameters.TryGetProperty("cwd", out _));
        Assert.Equal(50, parameters.GetProperty("limit").GetInt32());
        Assert.Equal(["initialize", "initialized", "thread/list"], calls.Select(call => call.Method));
        calls.Clear();
        _ = await source.ListAsync("codex", @"C:\repo", 2, CancellationToken.None);
        var lists = calls.Where(call => call.Method == "thread/list").ToArray();
        Assert.False(lists[0].Parameters.TryGetProperty("cursor", out _));
        Assert.False(lists[0].Parameters.TryGetProperty("sourceKinds", out _));
        Assert.Equal(@"C:\repo", lists[0].Parameters.GetProperty("cwd").GetString());
        Assert.Equal("cursor-one", lists[1].Parameters.GetProperty("cursor").GetString());
        var native = await source.ListAsync("deepseek", @"C:\repo", 4, CancellationToken.None);
        Assert.Equal("原生标题", Assert.Single(native.Sessions).Title);
        Assert.False(native.HasMore);
        Assert.Equal(1, claims);
    }

    [Fact]
    public async Task HTTP成功但原生业务失败不能显示为空列表()
    {
        using var http = new HttpClient(new Handler(request => Task.FromResult(Response(
            request.RequestUri!.AbsolutePath == "/api/pair/local" ? """{"token":"fixture-only"}""" : """{"result":{"ok":false,"error":{"message":"not ready"}}}"""))));
        using var source = new LocalSessionSource(8787, http);
        await Assert.ThrowsAsync<InvalidDataException>(() => source.ListAsync("deepseek", null, 4, CancellationToken.None));
    }

    [Fact]
    public async Task 认证失败清除内存凭据下次刷新重新取得()
    {
        var claims = 0;
        using var http = new HttpClient(new Handler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/pair/local")
            {
                claims++;
                return Task.FromResult(Response("""{"token":"fixture-only"}"""));
            }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized));
        }));
        using var source = new LocalSessionSource(8787, http);
        await Assert.ThrowsAsync<HttpRequestException>(() => source.CatalogAsync(CancellationToken.None));
        await Assert.ThrowsAsync<HttpRequestException>(() => source.CatalogAsync(CancellationToken.None));
        Assert.Equal(2, claims);
    }

    [Theory]
    [InlineData("http://100.64.0.1:9876", 9876)]
    [InlineData("http://host.invalid", 8787)]
    public void 服务地址只提取端口并且不会作为远程请求目标(string endpoint, int port) =>
        Assert.Equal(port, LocalSessionSource.Port(endpoint));

    private static HttpResponseMessage Response(string text) => new(HttpStatusCode.OK)
    { Content = new StringContent(text, Encoding.UTF8, "application/json") };

    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }

    private sealed class Channel(List<(string Method, JsonElement Parameters)> calls) : IDesktopRpcChannel
    {
        private int pages;
        public bool Disposed { get; private set; }
        public Task<JsonElement> CallAsync(string method, object parameters, CancellationToken token)
        {
            calls.Add((method, JsonSerializer.SerializeToElement(parameters)));
            var result = method == "initialize" ? "{}" : ++pages == 1
                ? """{"data":[{"id":"same","name":"one","status":"idle"}],"nextCursor":"cursor-one"}"""
                : """{"data":[{"id":"older","name":"two","status":"idle"}],"nextCursor":null}""";
            return Task.FromResult(JsonSerializer.Deserialize<JsonElement>(result));
        }
        public Task NotifyAsync(string method, object parameters, CancellationToken token)
        {
            calls.Add((method, JsonSerializer.SerializeToElement(parameters)));
            return Task.CompletedTask;
        }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
}
