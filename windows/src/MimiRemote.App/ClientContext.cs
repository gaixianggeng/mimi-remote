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
    private OnboardingGateState gateState;
    private bool gateInitialized;

    public bool Preview { get; }
    private long gateRequest;
    internal DesktopPreferences Preferences { get; } = DesktopPreferences.Load();
    public Action Quit { get; set; } = () => { };
    public ClientBuild Build { get; } = ClientBuild.Parse(typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);
    public Func<string, string, Task<bool>> Confirm { get; set; } = (_, _) => Task.FromResult(false);
    public Action<Type> Navigate { get; set; } = _ => { };
    public Action<string> NavigateRoute { get; set; } = _ => { };
    public Func<Task<string?>> PickFolder { get; set; } = () => Task.FromResult<string?>(null);
    public Func<Task<string?>> PickFile { get; set; } = () => Task.FromResult<string?>(null);
    public Action<string> OpenUrl { get; set; } = _ => { };
    public Action<string> OpenSettings { get; set; } = _ => { };
    public Func<string, bool> CopyToClipboard { get; set; } = _ => false;
    public Func<MaintenancePurpose, CancellationToken, Task<MaintenanceRunResult>>? RunInstallerMaintenance { get; init; }
    public Action<string, string> Notify { get; set; } = (_, _) => { };
    public HostStatus? LastStatus => cached;
    public OnboardingPreflightReport? LastPreflight { get; private set; }
    public OnboardingResolvedDiagnostic? LastPreflightError { get; private set; }
    public string? VerifiedCapability { get; private set; }
    public OnboardingGateState GateState => gateState;
    public bool GateInitialized => gateInitialized;

    public event EventHandler? StatusChanged;
    public event EventHandler<OnboardingGateState>? GateStateChanged;

    public ClientContext(bool preview)
    {
        Preview = preview;
        gateState = preview ? OnboardingGateState.Confirmed : OnboardingGateState.Unconfigured;
        gateInitialized = preview;
        if (!preview)
        {
            RunInstallerMaintenance = RunTrustedInstallerMaintenanceAsync;
            try
            {
                agent = new AgentClient(AgentClient.FindExecutable());
            }
            catch (FileNotFoundException)
            {
            }
        }
    }

    private async Task<MaintenanceRunResult> RunTrustedInstallerMaintenanceAsync(MaintenancePurpose purpose, CancellationToken token)
    {
        var native = new WindowsMaintenanceNative(ct =>
            Agent.ReadAsync<HostStatus>(["status", "--json", "--runtime", "--network-policy"], ct));
        var client = new WindowsMaintenanceClient(
            WindowsMaintenanceNative.ResolveTrustedInstallDirectory,
            () => WindowsMaintenanceNative.ResolveExpectedVersion(Build),
            () => WindowsMaintenanceNative.ResolvePreTrustedPublisherSha256(Build, typeof(App).Assembly),
            native);
        var result = await Task.Run(() => client.RunModifyAsync(purpose, token), token);
        Invalidate();
        if (result.PostRunStatus is { } refreshed)
        {
            cached = refreshed;
            hasRuntime = true;
            statusAt = DateTimeOffset.UtcNow;
        }
        await RefreshGateAsync(token);
        StatusChanged?.Invoke(this, EventArgs.Empty);
        return result;
    }

    public AgentClient Agent => agent ?? throw new InvalidOperationException(Preview
        ? "界面预览不会更改电脑服务。" : "未找到电脑服务，请先安装 Mimi Remote。");

    public bool HasAgent => agent is not null;

    public void UpdateGateFromPreflight(OnboardingPreflightReport? report, OnboardingResolvedDiagnostic? error = null)
    {
        LastPreflight = report;
        LastPreflightError = error;
        gateInitialized = true;
        var next = OnboardingNavigationGate.Evaluate(report, error, Preview);
        if (next != gateState)
        {
            gateState = next;
            GateStateChanged?.Invoke(this, gateState);
        }
    }

    public void SetVerifiedCapability(string? capability)
    {
        VerifiedCapability = capability == OnboardingSchema.DoctorFixCapability ? capability : null;
    }

    public async Task<OnboardingPreflightReport> ReadPreflightAsync(OnboardingPreflightOptions options,
        Action<OnboardingCheck>? onProgress, CancellationToken cancellationToken)
    {
        var request = ++gateRequest;
        try
        {
            var report = await Agent.PreflightAsync(options, onProgress, "windows", cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            if (request != gateRequest)
            {
                throw new OperationCanceledException("已有更新的预检结果。", cancellationToken);
            }
            UpdateGateFromPreflight(report);
            return report;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException or IOException
            or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (request != gateRequest)
            {
                throw new OperationCanceledException("已有更新的预检结果。", error, cancellationToken);
            }
            UpdateGateFromPreflight(null, (error as OnboardingCliException)?.Diagnostic);
            throw;
        }
    }

    public async Task<OnboardingGateState> RefreshGateAsync(CancellationToken token = default)
    {
        if (Preview)
        {
            UpdateGateFromPreflight(null, null);
            return gateState;
        }
        if (agent is null)
        {
            UpdateGateFromPreflight(null, OnboardingCopyCatalog.SynthesizeLocal("embedded_binary_missing", "service_daemon"));
            return gateState;
        }
        try
        {
            await ReadPreflightAsync(new OnboardingPreflightOptions
            {
                Stage = "setup",
                ProgressJson = false,
                VerifiedCapability = VerifiedCapability,
            }, null, token);
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException or IOException
            or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or OperationCanceledException)
        {
            // ReadPreflightAsync publishes the current failure and ignores superseded reads.
        }
        return gateState;
    }

    public async Task<HostStatus> ReadStatusAsync(bool runtime = false, bool force = false, CancellationToken token = default)
    {
        if (cached is not null && !force && (!runtime || hasRuntime) && DateTimeOffset.UtcNow - statusAt < TimeSpan.FromSeconds(15))
        {
            return cached;
        }
        while (true)
        {
            if (statusRequest is null || statusRequest.IsCompleted || requestRevision != revision)
            {
                requestRevision = revision;
                statusRequest = ReadCoreAsync(runtime, requestRevision);
            }
            var expected = requestRevision;
            var pending = await statusRequest.WaitAsync(token);
            if (expected != revision)
            {
                continue;
            }
            if (!runtime || hasRuntime)
            {
                return pending;
            }
        }
    }

    private async Task<HostStatus> ReadCoreAsync(bool runtime, int expected)
    {
#if DEBUG
        if (Preview)
        {
            cached = PreviewData.Host;
            hasRuntime = true;
            statusAt = DateTimeOffset.UtcNow;
            return cached;
        }
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

    public void Invalidate()
    {
        revision++;
        statusAt = DateTimeOffset.MinValue;
    }

    public async Task ChangeAsync(Func<Task> action)
    {
        await changes.WaitAsync();
        try
        {
            await action();
        }
        finally
        {
            Invalidate();
            changes.Release();
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    // An operation can still unwind after the window closes. Its finally must be able to release the gate.
    public void Dispose()
    {
        StatusChanged = null;
        GateStateChanged = null;
    }
}
