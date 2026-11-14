using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class ConnectionViewModel : ClientPageViewModel
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private TailcatStatus? current;
    private bool polling;
    private bool edited;
    private bool syncing;
    private bool networkEdited;
    private bool syncingNetwork;
    private int choice;
    private string address = "";
    private bool lan;
    private bool tailscale;
    private bool networkAvailable;
    public PageState Relay { get; } = new();
    public PageState Network { get; } = new();
    public string ConnectionState => current?.Running == true ? "内置连接运行中" : current?.Enabled == true ? "正在连接…" : "内置连接已关闭";
    public string ToggleTitle => current?.Enabled == true ? "关闭内置连接" : "开启内置连接";
    public bool NetworkAvailable { get => networkAvailable; private set => SetProperty(ref networkAvailable, value); }
    public bool Lan { get => lan; set { if (SetProperty(ref lan, value) && !syncingNetwork) { networkEdited = true; } } }
    public bool Tailscale { get => tailscale; set { if (SetProperty(ref tailscale, value) && !syncingNetwork) { networkEdited = true; } } }
    public int Choice { get => choice; set { if (SetProperty(ref choice, value)) { if (!syncing) { edited = true; } OnPropertyChanged(nameof(Custom)); } } }
    public bool Custom => Choice == 1;
    public string Address { get => address; set { if (SetProperty(ref address, value) && !syncing) { edited = true; } } }
    public IAsyncRelayCommand ApplyRelayCommand { get; }
    public IAsyncRelayCommand ToggleCommand { get; }
    public IAsyncRelayCommand ApplyNetworkCommand { get; }
    public ConnectionViewModel(ClientContext context) : base(context)
    {
        ApplyRelayCommand = new AsyncRelayCommand(() => Relay.RunAsync(ApplyRelayAsync));
        ToggleCommand = new AsyncRelayCommand(() => Relay.RunAsync(ToggleAsync));
        ApplyNetworkCommand = new AsyncRelayCommand(() => Network.RunAsync(ApplyNetworkAsync));
        timer.Tick += async (_, _) =>
        {
            if (!Active || polling || Relay.IsBusy || Context.Preview) { return; }
            polling = true;
            try { await ReadTailcatAsync(); }
            catch (Exception error) when (error is InvalidOperationException or IOException or TimeoutException or System.Text.Json.JsonException)
            { Report("暂时无法更新连接状态：" + error.Message, true); }
            finally { polling = false; }
        };
    }
    protected override void OnActiveChanged() { if (Active) { timer.Start(); } else { timer.Stop(); } }
    protected override async Task RefreshAsync(bool force)
    {
        var host = await Context.ReadStatusAsync(force: force, token: Lifetime.Token);
        NetworkAvailable = host.ModuleStatus is not null;
        if (!networkEdited)
        {
            syncingNetwork = true;
            Lan = host.ModuleStatus?.LanEnabled == true;
            Tailscale = host.ModuleStatus?.TailscaleEnabled == true;
            syncingNetwork = false;
        }
        if (host.ServiceOk) { await ReadTailcatAsync(); }
    }
    private async Task ReadTailcatAsync()
    {
#if DEBUG
        if (Context.Preview) { current = new TailcatStatus { Enabled = true, Running = true, Mode = "managed" }; }
        else
#endif
        { current = await Context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], Lifetime.Token); }
        OnPropertyChanged(nameof(ConnectionState)); OnPropertyChanged(nameof(ToggleTitle));
        if (edited) { return; }
        syncing = true;
        Choice = current.Choice switch { "custom" => 1, "mimi" => 2, _ => 0 };
        Address = current.Choice == "custom" ? current.DerpMapUrl : "";
        syncing = false;
    }
    private async Task ApplyRelayAsync()
    {
        var selected = Choice switch { 1 => "custom", 2 => "mimi", _ => "default" };
        var url = selected == "custom" ? Address.Trim() : "";
        var arguments = RelayPolicy.Arguments(selected, url);
        await Context.ChangeAsync(async () =>
        {
            var before = await Context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], Lifetime.Token);
            if (RelayPolicy.NeedsConfirmation(selected, url, before) && !await Context.Confirm("更换中转服务？", "内置连接会短暂重连，使用该线路的手机可能需要重新扫码。")) { return; }
            await Context.Agent.RunAsync(arguments, Lifetime.Token);
            edited = false;
            await ReadTailcatAsync();
            Relay.Report(current?.Enabled != true ? "中转配置已保存，开启内置连接后生效。" : selected == "mimi"
                ? "中转设置已更新，已开通的手机会自动跟随。" : "中转设置已更新，请重新生成二维码配对。");
        });
    }
    private async Task ToggleAsync()
    {
        var enabled = current?.Enabled != true;
        if (!await Context.Confirm(enabled ? "开启内置连接？" : "关闭内置连接？", enabled
            ? "使用端到端加密连接，无法直连时通过中转。" : "使用内置连接的手机会断开，其他连接方式不受影响。")) { return; }
        await Context.ChangeAsync(async () => await Context.Agent.RunAsync(["tailcat", enabled ? "enable" : "disable", "--json"], Lifetime.Token));
        await ReadTailcatAsync();
        Relay.Report(enabled ? "已开启内置连接。" : "已关闭内置连接。");
    }
    private async Task ApplyNetworkAsync()
    {
        var selectedLan = Lan; var selectedTailscale = Tailscale;
        if (!await Context.Confirm("更新连接方式？", selectedLan
            ? "仅在信任的专用网络允许局域网连接。服务会检查防火墙策略并短暂重启。"
            : "服务会短暂重启，手机连接可能断开。")) { return; }
        await Context.ChangeAsync(async () =>
        {
            var modules = new ModuleCommands(Context.Agent);
            var host = await Context.ReadStatusAsync(force: true, token: Lifetime.Token);
            if (host.ModuleStatus is null) { throw new InvalidOperationException("无法读取当前连接设置，请刷新后重试。"); }
            if (host.ModuleStatus.LanEnabled != selectedLan) { await modules.SetAsync("lan", selectedLan, Lifetime.Token); }
            if (host.ModuleStatus.TailscaleEnabled != selectedTailscale) { await modules.SetAsync("tailscale", selectedTailscale, Lifetime.Token); }
        });
        networkEdited = false;
        await RefreshAsync(true); Network.Report("连接设置已生效。");
    }
    public override void Dispose() { timer.Stop(); base.Dispose(); }
}
