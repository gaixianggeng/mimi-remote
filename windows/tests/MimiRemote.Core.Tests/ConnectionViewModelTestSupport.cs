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
        public void RaiseTick() { if (IsEnabled) { Tick?.Invoke(this, EventArgs.Empty); } }
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
        public bool Preview { get; set; }
        internal bool PairAfterSetup { get; set; }
        public PollingTestAgent Agent { get; } = new();
        public HostStatus Status { get; set; } = new() { ServiceOk = false };
        public event EventHandler? StatusChanged;
        public Func<string, string, Task<bool>> Confirm { get; set; } = (_, _) => Task.FromResult(false);
        public Action<Type> Navigate { get; set; } = _ => { };
        public Func<Task<string?>> PickFolder { get; set; } = () => Task.FromResult<string?>(null);
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
        public async Task<T> ReadAsync<T>(string[] arguments, CancellationToken token = default) =>
            (T)(object)await ReadTailcat(token);
        public async Task<SetupReceipt> SetupAsync(string scanRoot, OnboardingSetupOptions? options = null, CancellationToken cancellationToken = default)
        {
            var stdout = await RunAsync(AgentClient.SetupArguments(scanRoot, options), cancellationToken).ConfigureAwait(false);
            if (!OnboardingCopyCatalog.TryDecodeSetupReceipt(stdout, out var receipt, out var error))
            {
                throw new InvalidDataException($"无法解析首次设置结果：{error}");
            }
            return receipt;
        }
        public Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken = default)
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
