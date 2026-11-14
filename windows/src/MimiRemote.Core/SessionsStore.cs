namespace MimiRemote.Core;

public interface IDesktopSessionSource
{
    Task<SessionCatalog> CatalogAsync(CancellationToken token);
    Task<DesktopSessionPage> ListAsync(string runtime, string? cwd, int pageBudget, CancellationToken token);
}

/// <summary>One in-memory directory per scope; failures never masquerade as an empty successful page.</summary>
public sealed class SessionsStore(IDesktopSessionSource source) : IDisposable
{
    private readonly Dictionary<string, DesktopSession> rows = new(StringComparer.Ordinal);
    private CancellationTokenSource? request;
    private Task? inflight;
    private int generation;
    private int pageBudget = 4;
    private bool disposed;
    public event EventHandler? Changed;
    public string? Cwd { get; private set; }
    public SessionCatalog? Catalog { get; private set; }
    public IReadOnlyList<DesktopSession> Sessions => rows.Values.OrderByDescending(row => row.UpdatedAt).ThenBy(row => row.Key, StringComparer.Ordinal).ToArray();
    public IReadOnlyList<string> Notices { get; private set; } = [];
    public bool Loading { get; private set; }
    public bool Loaded { get; private set; }
    public bool HasMore { get; private set; }
    public DateTimeOffset? LastUpdated { get; private set; }

    public Task SetScopeAsync(string? cwd, CancellationToken token = default)
    {
        if (Cwd == cwd) { return RefreshAsync(token: token); }
        Suspend();
        Cwd = cwd;
        pageBudget = 4;
        rows.Clear();
        Loaded = false;
        LastUpdated = null;
        HasMore = false;
        return RefreshAsync(token: token);
    }

    public Task RefreshAsync(bool more = false, CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (inflight is { IsCompleted: false }) { return inflight; }
        if (more && HasMore) { pageBudget += 4; }
        request?.Dispose();
        request = CancellationTokenSource.CreateLinkedTokenSource(token);
        var current = ++generation;
        inflight = LoadAsync(current, Cwd, pageBudget, request.Token);
        return inflight;
    }

    public void Suspend()
    {
        generation++;
        request?.Cancel();
        inflight = null;
        Loading = false;
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        Suspend();
        request?.Dispose();
    }

    private async Task LoadAsync(int current, string? cwd, int budget, CancellationToken token)
    {
        Loading = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var catalog = await source.CatalogAsync(token);
            if (current != generation) { return; }
            Catalog = catalog;
            var outcomes = await Task.WhenAll(catalog.Runtimes.Select(async runtime =>
            {
                try { return (Runtime: runtime, Page: await source.ListAsync(runtime, cwd, budget, token), Error: (string?)null); }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (Exception error) when (error is IOException or InvalidOperationException or TimeoutException
                    or System.Net.Http.HttpRequestException or System.Text.Json.JsonException or System.Net.WebSockets.WebSocketException)
                { return (Runtime: runtime, Page: (DesktopSessionPage?)null, Error: error.Message); }
            }));
            if (current != generation) { return; }
            var notices = new List<string>();
            var enabled = catalog.Runtimes.ToHashSet(StringComparer.Ordinal);
            foreach (var key in rows.Where(pair => !enabled.Contains(pair.Value.Runtime)).Select(pair => pair.Key).ToArray()) { rows.Remove(key); }
            var hasMore = false;
            var succeeded = catalog.Runtimes.Count == 0;
            foreach (var outcome in outcomes)
            {
                if (outcome.Page is not { } page)
                {
                    notices.Add($"{Title(outcome.Runtime)}：{outcome.Error} 已有记录可能过期。");
                    continue;
                }
                succeeded = true;
                hasMore |= page.HasMore;
                // A bounded discovery prefix is not evidence that older rows have been revoked.
                if (!page.HasMore)
                {
                    foreach (var key in rows.Where(pair => pair.Value.Runtime == outcome.Runtime).Select(pair => pair.Key).ToArray()) { rows.Remove(key); }
                }
                foreach (var row in page.Sessions) { rows[row.Key] = row; }
            }
            Notices = notices;
            // A failed runtime may still have earlier pages; preserve its load-more affordance.
            HasMore = hasMore || outcomes.Any(outcome => outcome.Page is null) && HasMore;
            Loaded = true;
            if (succeeded) { LastUpdated = DateTimeOffset.Now; }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or InvalidOperationException or TimeoutException
            or System.Net.Http.HttpRequestException or System.Text.Json.JsonException or System.Net.WebSockets.WebSocketException)
        {
            if (current == generation) { Notices = [error.Message + (rows.Count > 0 ? " 已显示上次记录，状态可能过期。" : "")]; }
        }
        finally
        {
            if (current == generation)
            {
                Loading = false;
                Changed?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    public static string Title(string runtime) => runtime switch { "codex" => "Codex", "claude" => "Claude", _ => "DeepSeek" };
}
