using MimiRemote.Core;

// Only platform/context boundaries are replaced. The view models themselves are linked unchanged.
namespace Microsoft.UI.Xaml
{
    public sealed class DispatcherTimer
    {
        public TimeSpan Interval { get; set; }
        public bool IsEnabled { get; private set; }
        public event EventHandler<object>? Tick;
        public void Start() => IsEnabled = true;
        public void Stop() => IsEnabled = false;
        public void RaiseTick()
        {
            if (IsEnabled)
            {
                Tick?.Invoke(this, EventArgs.Empty);
            }
        }
    }
}

namespace MimiRemote.App
{
    internal static class DesktopPreferences
    {
        internal static string ConfigPath { get; set; } = Path.Combine(
            Path.GetTempPath(),
            "mimi-test-missing-config-" + Guid.NewGuid().ToString("N"),
            "config.json");
    }

    public sealed class ClientContext
    {
        private OnboardingGateState gateState;

        public bool Preview { get; set; }
        public bool HasAgent { get; set; } = true;
        public PollingTestAgent Agent { get; } = new();
        public HostStatus Status { get; set; } = new() { ServiceOk = false };
        public OnboardingPreflightReport? LastPreflight { get; private set; }
        public OnboardingResolvedDiagnostic? LastPreflightError { get; private set; }
        public string? VerifiedCapability { get; private set; }
        public OnboardingGateState GateState => gateState;

        public event EventHandler? StatusChanged;
        public event EventHandler<OnboardingGateState>? GateStateChanged;

        public Func<string, string, Task<bool>> Confirm { get; set; } = (_, _) => Task.FromResult(false);
        public Action<Type> Navigate { get; set; } = _ => { };
        public Action<string> NavigateRoute { get; set; } = _ => { };
        public Func<Task<string?>> PickFolder { get; set; } = () => Task.FromResult<string?>(null);
        public Func<Task<string?>> PickFile { get; set; } = () => Task.FromResult<string?>(null);
        public Action<string> OpenUrl { get; set; } = _ => { };
        public Action<string> OpenSettings { get; set; } = _ => { };
        public Func<string, bool> CopyToClipboard { get; set; } = _ => true;
        public Func<CancellationToken, Task<bool>> RunLanFirewallMaintenance { get; set; } = _ => Task.FromResult(false);

        public void SetVerifiedCapability(string? capability)
        {
            VerifiedCapability = capability == OnboardingSchema.DoctorFixCapability ? capability : null;
        }

        public void UpdateGateFromPreflight(OnboardingPreflightReport? report, OnboardingResolvedDiagnostic? error = null)
        {
            LastPreflight = report;
            LastPreflightError = error;
            var next = OnboardingNavigationGate.Evaluate(report, error, Preview);
            if (next != gateState)
            {
                gateState = next;
                GateStateChanged?.Invoke(this, gateState);
            }
        }

        public async Task<OnboardingPreflightReport> ReadPreflightAsync(OnboardingPreflightOptions options,
            Action<OnboardingCheck>? onProgress, CancellationToken cancellationToken)
        {
            try
            {
                var report = await Agent.PreflightAsync(options, onProgress, "windows", cancellationToken);
                UpdateGateFromPreflight(report);
                return report;
            }
            catch (InvalidOperationException error)
            {
                UpdateGateFromPreflight(null, (error as OnboardingCliException)?.Diagnostic);
                throw;
            }
        }

        public Task<HostStatus> ReadStatusAsync(bool runtime = false, bool force = false, CancellationToken token = default) =>
            Task.FromResult(Status);

        public async Task ChangeAsync(Func<Task> action)
        {
            await action();
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public sealed class PollingTestAgent : IAgentCommand
    {
        public List<string[]> Calls { get; } = [];
        public Func<CancellationToken, Task<TailcatStatus>> ReadTailcat { get; set; } = _ => Task.FromResult(new TailcatStatus());
        public Func<string[], CancellationToken, Task<string>>? RunHandler { get; set; }
        public Func<OnboardingPreflightOptions, Action<OnboardingCheck>?, CancellationToken, Task<OnboardingPreflightReport>>? PreflightHandler { get; set; }

        public async Task<T> ReadAsync<T>(string[] arguments, CancellationToken token = default) =>
            (T)(object)await ReadTailcat(token);

        public async Task<OnboardingPreflightReport> PreflightAsync(
            OnboardingPreflightOptions options,
            Action<OnboardingCheck>? onProgress = null,
            string platform = "windows",
            CancellationToken cancellationToken = default)
        {
            Calls.Add(AgentClient.PreflightArguments(options));
            if (PreflightHandler is not null)
            {
                return await PreflightHandler(options, onProgress, cancellationToken).ConfigureAwait(false);
            }
            var stdout = RunHandler is not null
                ? await RunHandler(AgentClient.PreflightArguments(options), cancellationToken).ConfigureAwait(false)
                : "";
            if (!OnboardingCopyCatalog.TryDecodeAndValidateReport(
                stdout,
                platform,
                expectedStage: options.Stage,
                nativeOverlay: false,
                verifiedCapability: options.VerifiedCapability,
                out var report,
                out var error))
            {
                throw new InvalidDataException($"无法解析预检报告：{error}");
            }
            return report;
        }

        public async Task<SetupReceipt> SetupAsync(string scanRoot, OnboardingSetupOptions? options = null, CancellationToken cancellationToken = default)
        {
            var stdout = await RunAsync(AgentClient.SetupArguments(scanRoot, options), cancellationToken).ConfigureAwait(false);
            if (!OnboardingCopyCatalog.TryDecodeSetupReceipt(stdout, out var receipt, out var error))
            {
                throw new InvalidDataException($"无法解析首次设置结果：{error}");
            }
            return receipt;
        }

        public async Task<UpReadinessReceipt> UpAsync(int waitSeconds = 60, CancellationToken cancellationToken = default)
        {
            var stdout = await RunAsync(AgentClient.UpArguments(waitSeconds), cancellationToken).ConfigureAwait(false);
            if (!OnboardingCopyCatalog.TryDecodeUpReadinessReceipt(stdout, out var receipt, out var error))
            {
                throw new InvalidDataException($"后台服务尚未确认就绪：{error}");
            }
            return receipt;
        }

        public async Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken = default)
        {
            var stdout = await RunAsync(AgentClient.PairArguments(network), cancellationToken).ConfigureAwait(false);
            if (!OnboardingCopyCatalog.TryDecodePairingTicketReceipt(stdout, requireNetwork: false, out var receipt, out var error))
            {
                throw new InvalidDataException($"无法解析配对票据：{error}");
            }
            return receipt;
        }

        public Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken = default) =>
            RunAsync(arguments, allowFailure: false, cancellationToken);

        public Task<string> RunAsync(string[] arguments, bool allowFailure, CancellationToken cancellationToken = default)
        {
            Calls.Add(arguments);
            return RunHandler is not null ? RunHandler(arguments, cancellationToken) : Task.FromResult("{}");
        }

        public Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default)
        {
            Calls.Add(arguments);
            return RunHandler is not null ? RunHandler(arguments, cancellationToken) : Task.FromResult("{}");
        }
    }
}

namespace MimiRemote.App.Pages
{
    public sealed class PairingPage
    {
    }
}
