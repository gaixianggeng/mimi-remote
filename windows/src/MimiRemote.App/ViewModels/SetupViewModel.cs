using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class SetupViewModel : ClientPageViewModel
{
    private string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "code");
    public string Root { get => root; set => SetProperty(ref root, value); }
    public IAsyncRelayCommand PickCommand { get; }
    public IAsyncRelayCommand FinishCommand { get; }
    public SetupViewModel(ClientContext context) : base(context)
    {
        PickCommand = new AsyncRelayCommand(() => RunAsync(async () => { if (await Context.PickFolder() is { } folder) { Root = folder; } }));
        FinishCommand = new AsyncRelayCommand(() => RunAsync(FinishAsync));
    }
    protected override Task RefreshAsync(bool force) => Task.CompletedTask;
    private async Task FinishAsync()
    {
        if (Context.Preview) { throw new InvalidOperationException("界面预览不会更改代码目录或电脑服务。"); }
        var selected = Root.Trim();
        if (!Path.IsPathFullyQualified(selected)) { throw new ArgumentException("请选择完整的代码目录路径。"); }
        if (!Directory.Exists(selected))
        {
            if (!await Context.Confirm("创建代码目录？", "所选文件夹不存在，是否创建后继续？")) { return; }
            Directory.CreateDirectory(selected);
        }
        if (!await Context.Confirm("使用这个代码目录？", "已配对的手机将能浏览此目录。服务会短暂重启，手机连接可能断开。")) { return; }
        await Context.ChangeAsync(async () =>
        {
            if (!File.Exists(DesktopPreferences.ConfigPath))
            {
                await Context.Agent.RunAsync(["setup", "--scan-root", selected, "--browse-root", selected, "--json", "--qr-only"], Lifetime.Token);
                await Context.Agent.RunAsync(["start", "--wait", "60s", "--no-pair"], Lifetime.Token);
            }
            await new ModuleCommands(Context.Agent).SetWorkspaceAsync(selected, Lifetime.Token);
            Context.Preferences.SetupCompleted = true;
            Context.Preferences.Save();
        });
        Context.PairAfterSetup = true;
        Context.Navigate(typeof(Pages.PairingPage));
    }
}
