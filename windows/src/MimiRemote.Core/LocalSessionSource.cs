using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text.Json;

namespace MimiRemote.Core;

public interface IDesktopRpcChannel : IAsyncDisposable
{
    Task<JsonElement> CallAsync(string method, object parameters, CancellationToken token);
    Task NotifyAsync(string method, object parameters, CancellationToken token);
}

/// <summary>Read-only directory access through the existing local trust and authorization boundary.</summary>
public sealed class LocalSessionSource : IDesktopSessionSource, IDisposable
{
    private readonly Uri endpoint;
    private readonly HttpClient http;
    private readonly bool ownsHttp;
    private readonly SemaphoreSlim claimLock = new(1, 1);
    private readonly Func<Uri, string, CancellationToken, Task<IDesktopRpcChannel>> connect;
    private string? credential;

    public LocalSessionSource(int port, HttpClient? http = null,
        Func<Uri, string, CancellationToken, Task<IDesktopRpcChannel>>? connect = null)
    {
        if (port is < 1 or > 65535) { throw new ArgumentOutOfRangeException(nameof(port)); }
        endpoint = new Uri($"http://127.0.0.1:{port}");
        this.http = http ?? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false })
        { Timeout = TimeSpan.FromSeconds(20) };
        ownsHttp = http is null;
        this.connect = connect ?? DesktopRpcChannel.ConnectAsync;
    }

    public static int Port(string endpoint)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
        {
            throw new InvalidDataException("电脑服务尚未提供可用的本机地址。");
        }
        return uri.IsDefaultPort ? 8787 : uri.Port;
    }

    public async Task<SessionCatalog> CatalogAsync(CancellationToken token)
    {
        using var configuration = await RequestAsync(HttpMethod.Get, "/api/app-server/config", null, token).ConfigureAwait(false);
        var root = configuration.RootElement;
        if (!root.TryGetProperty("channels", out var channels) || channels.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("本机服务尚未提供会话渠道信息，请更新电脑服务。");
        }
        var runtimes = new List<string>();
        foreach (var channel in channels.EnumerateArray())
        {
            if (!channel.TryGetProperty("enabled", out var enabled) || enabled.ValueKind != JsonValueKind.True) { continue; }
            var runtime = DesktopSessionParsing.ReadText(channel, "runtime_id");
            if (runtime.Length == 0) { runtime = DesktopSessionParsing.ReadText(channel, "id"); }
            if (runtime is "codex" or "claude" || runtime == "deepseek" && DesktopSessionParsing.ReadText(channel, "protocol") == "harness_native_v1")
            {
                runtimes.Add(runtime);
            }
        }
        using var projects = await RequestAsync(HttpMethod.Get, "/api/projects", null, token).ConfigureAwait(false);
        if (!projects.RootElement.TryGetProperty("projects", out var list) || list.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("项目目录格式不正确。");
        }
        var entries = list.EnumerateArray().Select(project => new SessionProject(
            DesktopSessionParsing.ReadText(project, "name"), DesktopSessionParsing.ReadText(project, "path")))
            .Where(project => project.Cwd.Length > 0).DistinctBy(project => project.Cwd).ToArray();
        return new SessionCatalog(runtimes.Distinct(StringComparer.Ordinal).ToArray(), entries);
    }

    public async Task<DesktopSessionPage> ListAsync(string runtime, string? cwd, int pageBudget, CancellationToken token)
    {
        if (runtime == "deepseek")
        {
            var body = new Dictionary<string, object>
            {
                ["rpcId"] = Guid.NewGuid().ToString("N"),
                ["method"] = "session/list",
                ["args"] = new { _request = new { } },
            };
            if (cwd is not null) { body["cwd"] = cwd; }
            using var document = await RequestAsync(HttpMethod.Post, "/api/harness/rpc", body, token).ConfigureAwait(false);
            if (!document.RootElement.TryGetProperty("result", out var result)
                || !result.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
            {
                throw new InvalidDataException("DeepSeek 没有返回成功的会话目录，请检查 Harness 连接。");
            }
            if (!result.TryGetProperty("value", out var value)) { throw new InvalidDataException("DeepSeek 会话目录缺失。"); }
            return DesktopSessionParsing.HarnessPage(value);
        }
        if (runtime is not ("codex" or "claude")) { throw new ArgumentException("未知的会话渠道。", nameof(runtime)); }
        var credential = await ClaimAsync(token).ConfigureAwait(false);
        var address = new UriBuilder(endpoint) { Scheme = "ws", Path = "/api/app-server/ws", Query = "runtime=" + runtime }.Uri;
        await using var channel = await connect(address, credential, token).ConfigureAwait(false);
        _ = await channel.CallAsync("initialize", new
        {
            clientInfo = new { name = "mimi_remote", title = "Mimi Remote Windows", version = "0.1.0" },
            capabilities = new { experimentalApi = true, requestAttestation = false },
        }, token).ConfigureAwait(false);
        await channel.NotifyAsync("initialized", new { }, token).ConfigureAwait(false);
        var sessions = new Dictionary<string, DesktopSession>(StringComparer.Ordinal);
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null;
        for (var index = 0; index < Math.Max(1, pageBudget); index++)
        {
            var parameters = new Dictionary<string, object>
            {
                ["limit"] = 50,
                ["sortKey"] = "updated_at",
                ["sortDirection"] = "desc",
                ["archived"] = false,
                ["useStateDbOnly"] = false,
            };
            // This directory intentionally excludes subagents; use the same source scope for every project.
            parameters["sourceKinds"] = new[] { "cli", "vscode", "appServer" };
            if (cwd is not null) { parameters["cwd"] = cwd; }
            if (cursor is not null) { parameters["cursor"] = cursor; }
            var result = await channel.CallAsync("thread/list", parameters, token).ConfigureAwait(false);
            var page = DesktopSessionParsing.ThreadPage(result, runtime);
            foreach (var row in page.Sessions) { sessions.TryAdd(row.Key, row); }
            cursor = DesktopSessionParsing.ReadText(result, "nextCursor");
            if (cursor.Length == 0) { return new DesktopSessionPage(sessions.Values.ToArray(), false); }
            if (!cursors.Add(cursor)) { throw new InvalidDataException("会话目录返回重复游标，请稍后刷新。"); }
        }
        return new DesktopSessionPage(sessions.Values.ToArray(), true);
    }

    public void Dispose()
    {
        credential = null;
        if (ownsHttp) { http.Dispose(); }
        // In-flight reads are cancelled by the store before its source is retired.
    }

    private async Task<string> ClaimAsync(CancellationToken token)
    {
        await claimLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (credential is not null) { return credential; }
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(endpoint, "/api/pair/local"));
            request.Headers.Add("X-Mimi-Local-Pairing", "1");
            using var document = await FetchAsync(request, token).ConfigureAwait(false);
            credential = DesktopSessionParsing.ReadText(document.RootElement, "token");
            if (credential.Length == 0) { credential = null; throw new InvalidDataException("本机服务没有提供连接凭据。"); }
            return credential;
        }
        finally { claimLock.Release(); }
    }

    private async Task<JsonDocument> RequestAsync(HttpMethod method, string path, object? body, CancellationToken token)
    {
        var value = await ClaimAsync(token).ConfigureAwait(false);
        using var request = new HttpRequestMessage(method, new Uri(endpoint, path));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", value);
        if (body is not null) { request.Content = JsonContent.Create(body); }
        return await FetchAsync(request, token).ConfigureAwait(false);
    }

    private async Task<JsonDocument> FetchAsync(HttpRequestMessage request, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            using var response = await SendAsync(request, timeout.Token).ConfigureAwait(false);
            return await ReadDocumentAsync(response, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new TimeoutException("本机服务响应超时。"); }
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        HttpResponseMessage response;
        try { response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new TimeoutException("本机服务响应超时。"); }
        if (response.IsSuccessStatusCode) { return response; }
        var status = response.StatusCode;
        response.Dispose();
        if (status == HttpStatusCode.Unauthorized) { credential = null; }
        throw new HttpRequestException(status switch
        {
            HttpStatusCode.Unauthorized => "本机连接凭据已失效，请刷新重试。",
            HttpStatusCode.Forbidden => "服务未授权这个项目或会话目录。",
            HttpStatusCode.ServiceUnavailable => "这个助手当前不可用，请检查服务和登录状态。",
            HttpStatusCode.TooManyRequests => "本机连接繁忙，请稍后刷新。",
            _ => $"本机服务未能读取目录（{(int)status}）。",
        }, null, status);
    }

    private static async Task<JsonDocument> ReadDocumentAsync(HttpResponseMessage response, CancellationToken token)
    {
        const int limit = 8 * 1024 * 1024;
        await using var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int size;
        while ((size = await stream.ReadAsync(chunk, token).ConfigureAwait(false)) > 0)
        {
            if (buffer.Length + size > limit) { throw new InvalidDataException("会话目录过大，无法读取。"); }
            buffer.Write(chunk, 0, size);
        }
        return JsonDocument.Parse(buffer.ToArray());
    }
}

internal sealed class DesktopRpcChannel(ClientWebSocket socket) : IDesktopRpcChannel
{
    private int nextId;

    public static async Task<IDesktopRpcChannel> ConnectAsync(Uri address, string credential, CancellationToken token)
    {
        var socket = new ClientWebSocket();
        socket.Options.Proxy = null;
        socket.Options.SetRequestHeader("Authorization", "Bearer " + credential);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            await socket.ConnectAsync(address, timeout.Token).ConfigureAwait(false);
            return new DesktopRpcChannel(socket);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            socket.Dispose();
            throw new TimeoutException("会话通道连接超时。");
        }
        catch { socket.Dispose(); throw; }
    }

    public async Task<JsonElement> CallAsync(string method, object parameters, CancellationToken token)
    {
        var id = ++nextId;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            await SendAsync(new { jsonrpc = "2.0", id, method, @params = parameters }, timeout.Token).ConfigureAwait(false);
            while (true)
            {
                using var document = await ReceiveAsync(timeout.Token).ConfigureAwait(false);
                var frame = document.RootElement;
                var matching = frame.TryGetProperty("id", out var frameId) && frameId.ValueKind == JsonValueKind.Number
                    && frameId.TryGetInt32(out var receivedId) && receivedId == id;
                if (frame.TryGetProperty("error", out _)
                    && (matching || frameId.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined))
                {
                    throw new InvalidOperationException("会话通道拒绝了读取请求，请检查助手是否启用并刷新重试。");
                }
                if (!matching) { continue; }
                if (!frame.TryGetProperty("result", out var result)) { throw new InvalidDataException("会话通道响应缺少结果。"); }
                return result.Clone();
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            socket.Abort();
            throw new TimeoutException("会话目录读取超时。");
        }
    }

    public Task NotifyAsync(string method, object parameters, CancellationToken token) =>
        SendAsync(new { jsonrpc = "2.0", method, @params = parameters }, token);

    public ValueTask DisposeAsync()
    {
        socket.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task SendAsync(object message, CancellationToken token) =>
        await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(message).AsMemory(), WebSocketMessageType.Text, true, token).ConfigureAwait(false);

    private async Task<JsonDocument> ReceiveAsync(CancellationToken token)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        ValueWebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(chunk.AsMemory(), token).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) { throw new IOException("会话通道已断开。"); }
            if (buffer.Length + result.Count > 8 * 1024 * 1024) { throw new InvalidDataException("会话目录过大，无法读取。"); }
            buffer.Write(chunk, 0, result.Count);
        } while (!result.EndOfMessage);
        return JsonDocument.Parse(buffer.ToArray());
    }
}
