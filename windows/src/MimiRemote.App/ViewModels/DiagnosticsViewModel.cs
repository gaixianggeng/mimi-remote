using CommunityToolkit.Mvvm.Input;

namespace MimiRemote.App.ViewModels;

public sealed class DiagnosticsViewModel : ClientPageViewModel
{
    private string output = "";
    public string Output { get => output; private set => SetProperty(ref output, value); }
    public IAsyncRelayCommand DoctorCommand { get; }
    public IAsyncRelayCommand LogsCommand { get; }
    public DiagnosticsViewModel(ClientContext context) : base(context)
    {
        DoctorCommand = new AsyncRelayCommand(() => RunAsync(async () => Output = await Context.Agent.RunAsync(["doctor"], allowFailure: true, cancellationToken: Lifetime.Token)));
        LogsCommand = new AsyncRelayCommand(() => RunAsync(async () =>
        {
            var log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mimi Remote", "logs", "agentd.log");
            using var stream = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, stream.Length - 65536), SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            Output = await reader.ReadToEndAsync(Lifetime.Token);
        }));
    }
    protected override Task RefreshAsync(bool force) => Task.CompletedTask;
}
