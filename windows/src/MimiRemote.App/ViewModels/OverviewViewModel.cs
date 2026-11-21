using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class OverviewViewModel : ClientPageViewModel
{
    private HostStatus? host;
    public string Heading => host?.Title ?? "正在读取电脑状态";
    public string Detail => host is null ? "" : $"已发现 {host.Projects} 个项目 · agentd {host.Version}\n{host.ServiceError}";
    public bool CanStart => !IsBusy && host is { ProcessOk: false };
    public bool CanStop => !IsBusy && host is { ProcessOk: true };
    public IAsyncRelayCommand StartCommand { get; }
    public IAsyncRelayCommand RestartCommand { get; }
    public IAsyncRelayCommand StopCommand { get; }
    public IRelayCommand PairCommand { get; }
    public OverviewViewModel(ClientContext context) : base(context)
    {
        StartCommand = new AsyncRelayCommand(() => ServiceAsync("start"), () => CanStart);
        RestartCommand = new AsyncRelayCommand(() => ServiceAsync("restart"), () => CanStop);
        StopCommand = new AsyncRelayCommand(() => ServiceAsync("stop"), () => CanStop);
        PairCommand = new RelayCommand(() => Context.Navigate(typeof(Pages.PairingPage)));
        PropertyChanged += (_, args) => { if (args.PropertyName == nameof(IsBusy)) { UpdateCommands(); } };
    }
    protected override async Task RefreshAsync(bool force)
    {
        host = await Context.ReadStatusAsync(runtime: true, force: force, token: Lifetime.Token);
        OnPropertyChanged(nameof(Heading)); OnPropertyChanged(nameof(Detail)); UpdateCommands();
    }
    private Task ServiceAsync(string action) => RunAsync(async () =>
    {
        if (action != "start" && !await Context.Confirm(action == "stop" ? "停止电脑服务？" : "重新启动电脑服务？", "手机连接会暂时断开，正在进行的会话可能受到影响。")) { return; }
        await Context.ChangeAsync(async () => await Context.Agent.RunAsync(action == "stop" ? [action] : [action, "--wait", "60s", "--no-pair"], Lifetime.Token));
        await RefreshAsync(true);
    });
    private void UpdateCommands()
    {
        OnPropertyChanged(nameof(CanStart)); OnPropertyChanged(nameof(CanStop));
        StartCommand.NotifyCanExecuteChanged(); RestartCommand.NotifyCanExecuteChanged(); StopCommand.NotifyCanExecuteChanged();
    }
}
