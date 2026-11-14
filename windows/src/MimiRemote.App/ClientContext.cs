using System.Reflection;
using MimiRemote.Core;

namespace MimiRemote.App;

/// <summary>Shared services and short-lived read cache; pages own their presentation state.</summary>
public sealed class ClientContext : IDisposable
{
    private readonly AgentClient? agent;
    private Task<HostStatus>? statusRequest;
    private int requestRevision;
    private HostStatus? cached;
    private DateTimeOffset statusAt;
    private bool hasRuntime;
    private int revision;
    private readonly SemaphoreSlim changes = new(1, 1);
    public bool Preview { get; }
    internal bool PairAfterSetup { get; set; }
    internal DesktopPreferences Preferences { get; } = DesktopPreferences.Load();
    public Action Quit { get; set; } = () => { };
    public ClientBuild Build { get; } = ClientBuild.Parse(typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);
    public Func<string, string, Task<bool>> Confirm { get; set; } = (_, _) => Task.FromResult(false);
    public Action<Type> Navigate { get; set; } = _ => { };
    public Func<Task<string?>> PickFolder { get; set; } = () => Task.FromResult<string?>(null);
    public Action<string, string> Notify { get; set; } = (_, _) => { };
    public HostStatus? LastStatus => cached;
    public event EventHandler? StatusChanged;
    public ClientContext(bool preview)
    {
        Preview = preview;
        if (!preview)
        {
            try { agent = new AgentClient(AgentClient.FindExecutable()); }
            catch (FileNotFoundException) { }
        }
    }
    public AgentClient Agent => agent ?? throw new InvalidOperationException(Preview
        ? "界面预览不会更改电脑服务。" : "未找到电脑服务，请先安装 Mimi Remote。");

    public async Task<HostStatus> ReadStatusAsync(bool runtime = false, bool force = false, CancellationToken token = default)
    {
        if (cached is not null && !force && (!runtime || hasRuntime) && DateTimeOffset.UtcNow - statusAt < TimeSpan.FromSeconds(15)) { return cached; }
        while (true)
        {
            if (statusRequest is null || statusRequest.IsCompleted || requestRevision != revision)
            {
                requestRevision = revision;
                statusRequest = ReadCoreAsync(runtime, requestRevision);
            }
            var expected = requestRevision;
            var pending = await statusRequest.WaitAsync(token);
            if (expected != revision) { continue; }
            if (!runtime || hasRuntime) { return pending; }
        }
    }
    private async Task<HostStatus> ReadCoreAsync(bool runtime, int expected)
    {
#if DEBUG
        if (Preview) { cached = PreviewData.Host; hasRuntime = true; statusAt = DateTimeOffset.UtcNow; return cached; }
#endif
        var status = await Agent.ReadAsync<HostStatus>(runtime ? ["status", "--json", "--runtime"] : ["status", "--json"]);
        if (expected == revision)
        {
            cached = status;
            hasRuntime = runtime;
            statusAt = DateTimeOffset.UtcNow;
        }
        return status;
    }
    public void Invalidate() { revision++; statusAt = DateTimeOffset.MinValue; }
    public async Task ChangeAsync(Func<Task> action)
    {
        await changes.WaitAsync();
        try { await action(); }
        finally { Invalidate(); changes.Release(); StatusChanged?.Invoke(this, EventArgs.Empty); }
    }
    // An operation can still unwind after the window closes. Its finally must be able to release the gate.
    public void Dispose() { StatusChanged = null; }
}
