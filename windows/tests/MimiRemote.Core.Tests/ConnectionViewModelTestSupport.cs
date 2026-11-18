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
    public sealed class ClientContext
    {
        public bool Preview { get; set; }
        public PollingTestAgent Agent { get; } = new();
        public HostStatus Status { get; set; } = new() { ServiceOk = false };
        public event EventHandler? StatusChanged;
        public Func<string, string, Task<bool>> Confirm { get; } = (_, _) => Task.FromResult(false);
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
        public Func<CancellationToken, Task<TailcatStatus>> ReadTailcat { get; set; } = _ => Task.FromResult(new TailcatStatus());
        public async Task<T> ReadAsync<T>(string[] arguments, CancellationToken token = default) =>
            (T)(object)await ReadTailcat(token);
        public Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken = default) => Task.FromResult("{}");
        public Task<string> RunWithInputAsync(string[] arguments, string input, CancellationToken cancellationToken = default) =>
            Task.FromResult("{}");
    }
}
