using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using MimiRemote.Core;
using QRCoder;
using Windows.Storage.Streams;

namespace MimiRemote.App.ViewModels;

public sealed class PairingViewModel : ClientPageViewModel
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private PairingNetwork? network;
    private BitmapImage? image;
    private DateTimeOffset expires;
    private string note = "请选择连接方式，再生成二维码。请勿把二维码发给他人。";
    private long generation;
    public ObservableCollection<PairingNetwork> Networks { get; } = [];
    public PairingNetwork? Network { get => network; set { if (SetProperty(ref network, value)) { Clear(); GenerateCommand.NotifyCanExecuteChanged(); } } }
    public BitmapImage? Image { get => image; private set => SetProperty(ref image, value); }
    public string Note { get => note; private set => SetProperty(ref note, value); }
    public IAsyncRelayCommand GenerateCommand { get; }
    public PairingViewModel(ClientContext context) : base(context)
    {
        GenerateCommand = new AsyncRelayCommand(() => RunAsync(GenerateAsync), () => Network is not null && !Context.Preview);
        timer.Tick += (_, _) => { if (Image is not null && DateTimeOffset.UtcNow >= expires) { Clear(); Note = "二维码已过期，请重新生成。"; } };
    }
    protected override void OnActiveChanged() { if (Active) { timer.Start(); } else { timer.Stop(); Clear(); } }
    protected override async Task RefreshAsync(bool force)
    {
        var host = await Context.ReadStatusAsync(force: force, token: Lifetime.Token);
        var available = new List<PairingNetwork>();
        if (host.ServiceOk)
        {
#if DEBUG
            var tailcat = Context.Preview ? new TailcatStatus { Enabled = true } :
                await Context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], Lifetime.Token);
#else
            var tailcat = await Context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], Lifetime.Token);
#endif
            if (tailcat.Enabled) { available.Add(new("tailcat", "内置连接（Tailcat）")); }
            if (host.ModuleStatus?.TailscaleEnabled == true) { available.Add(new("tailscale", "Tailscale")); }
            if (host.ModuleStatus?.LanEnabled == true) { available.Add(new("lan", "同一局域网")); }
        }
        var selected = Network?.Id;
        if (!Networks.SequenceEqual(available))
        {
            Networks.Clear();
            foreach (var item in available) { Networks.Add(item); }
            Network = Networks.FirstOrDefault(item => item.Id == selected) ?? Networks.FirstOrDefault();
        }
        if (Networks.Count == 0) { Note = "暂无可用连接方式。请先启动服务，并在“连接”中启用需要的方式。"; }
        if (Context.PairAfterSetup && Active && Network is not null)
        {
            Context.PairAfterSetup = false;
            await GenerateAsync();
        }
    }
    private async Task GenerateAsync()
    {
        if (Network is null) { return; }
        Clear();
        var request = generation;
        var selected = Network.Id;
        var info = await Context.Agent.ReadAsync<PairingInfo>(selected == "tailcat" ? ["tailcat", "pair", "--qr-only", "--json"]
            : ["pair", "--network", selected, "--qr-only", "--json"], Lifetime.Token);
        if (request != generation || !Active) { return; }
        if (string.IsNullOrWhiteSpace(info.PairUrl) || !DateTimeOffset.TryParse(info.PairExpiresAt, out var expiry) || expiry <= DateTimeOffset.UtcNow)
        { throw new InvalidDataException("配对信息无效或已经过期，请重新生成。"); }
        using var qr = QRCodeGenerator.GenerateQrCode(info.PairUrl, QRCodeGenerator.ECCLevel.M);
        using var png = new PngByteQRCode(qr);
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(png.GetGraphic(6)); await writer.StoreAsync(); }
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        if (request != generation || !Active) { return; }
        Image = bitmap;
        expires = expiry;
        Note = $"有效期至 {expiry.ToLocalTime():HH:mm:ss}。" + string.Join("\n", info.Warnings);
    }
    private void Clear() { generation++; Image = null; }
    public override void Dispose() { timer.Stop(); Clear(); base.Dispose(); }
}
public sealed record PairingNetwork(string Id, string Title);
