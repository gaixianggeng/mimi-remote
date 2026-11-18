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
    private readonly Dictionary<string, bool> moreByRuntime = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> runtimeFailures = new(StringComparer.Ordinal);
    private CancellationTokenSource? request;
    private Task? inflight;
    private int generation;
    private int pageBudget = 4;
    private bool disposed;
    public event EventHandler? Changed;
    public string? Cwd { get; private set; }
    public SessionCatalog? Catalog { get; private set; }
    public IReadOnlyList<DesktopSession> Sessions => rows.Values.OrderByDescending(row => row.UpdatedAt).ThenBy(row => row.Key, StringComparer.Ordinal).ToArray();
    public string? CatalogFailure { get; private set; }
    public IReadOnlyDictionary<string, string> RuntimeFailures => runtimeFailures;
    public bool Loading { get; private set; }
    public bool Loaded { get; private set; }
    public bool HasMore => moreByRuntime.ContainsValue(true);
    public DateTimeOffset? LastUpdated { get; private set; }

    public bool HasMoreFor(string? runtime) => runtime is null ? HasMore : moreByRuntime.GetValueOrDefault(runtime);

    public Task SetScopeAsync(string? cwd, CancellationToken token = default)
    {
        if (Cwd == cwd) { return RefreshAsync(token: token); }
        Suspend();
        Cwd = cwd;
        pageBudget = 4;
        rows.Clear();
        moreByRuntime.Clear();
        runtimeFailures.Clear();
        CatalogFailure = null;
        Loaded = false;
        LastUpdated = null;
        return RefreshAsync(token: token);
    }

    public Task RefreshAsync(bool more = false, bool firstPage = false, CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (inflight is { IsCompleted: false }) { return inflight; }
        if (more && HasMore) { pageBudget += 4; }
        request?.Dispose();
        request = CancellationTokenSource.CreateLinkedTokenSource(token);
        var current = ++generation;
        inflight = LoadAsync(current, Cwd, firstPage ? 1 : pageBudget, firstPage, request.Token);
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

    private async Task LoadAsync(int current, string? cwd, int budget, bool firstPage, CancellationToken token)
    {
        Loading = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var catalog = await source.CatalogAsync(token);
            if (current != generation) { return; }
            var outcomes = await Task.WhenAll(catalog.Runtimes.Select(async runtime =>
            {
                try { return (Runtime: runtime, Page: await source.ListAsync(runtime, cwd, budget, token), Error: (string?)null); }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or TimeoutException
                    or System.Net.Http.HttpRequestException or System.Text.Json.JsonException or System.Net.WebSockets.WebSocketException)
                { return (Runtime: runtime, Page: (DesktopSessionPage?)null, Error: error.Message); }
            }));
            if (current != generation) { return; }
            Catalog = catalog;
            CatalogFailure = null;
            runtimeFailures.Clear();
            var enabled = catalog.Runtimes.ToHashSet(StringComparer.Ordinal);
            foreach (var key in rows.Where(pair => !enabled.Contains(pair.Value.Runtime)).Select(pair => pair.Key).ToArray()) { rows.Remove(key); }
            foreach (var runtime in moreByRuntime.Keys.Where(runtime => !enabled.Contains(runtime)).ToArray()) { moreByRuntime.Remove(runtime); }
            var succeeded = catalog.Runtimes.Count == 0;
            foreach (var outcome in outcomes)
            {
                if (outcome.Page is not { } page)
                {
                    runtimeFailures[outcome.Runtime] = outcome.Error ?? "没有收到结果。";
                    continue;
                }
                succeeded = true;
                // A prior row at the same sort position bridges the new prefix to the cached rows.
                // A recently updated row may have moved ahead of unseen rows, so it cannot bridge the gap.
                if (!firstPage || !page.HasMore || !moreByRuntime.ContainsKey(outcome.Runtime)
                    || !page.Sessions.Any(row => row.UpdatedAt is not null && rows.TryGetValue(row.Key, out var prior)
                        && prior.UpdatedAt == row.UpdatedAt))
                {
                    moreByRuntime[outcome.Runtime] = page.HasMore;
                }
                // A bounded discovery prefix is not evidence that older rows have been revoked.
                if (!page.HasMore)
                {
                    foreach (var key in rows.Where(pair => pair.Value.Runtime == outcome.Runtime).Select(pair => pair.Key).ToArray()) { rows.Remove(key); }
                }
                foreach (var row in page.Sessions) { rows[row.Key] = row; }
            }
            Loaded = true;
            if (succeeded) { LastUpdated = DateTimeOffset.Now; }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or TimeoutException
            or System.Net.Http.HttpRequestException or System.Text.Json.JsonException or System.Net.WebSockets.WebSocketException)
        {
            if (current == generation) { CatalogFailure = error.Message; }
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
