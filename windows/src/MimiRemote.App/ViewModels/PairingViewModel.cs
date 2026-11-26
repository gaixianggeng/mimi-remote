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
    private const string GeneratePrompt = "选择连接方式后生成二维码。请勿把二维码发给他人。";
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private PairingNetwork? network;
    private BitmapImage? image;
    private DateTimeOffset expires;
    private string note = GeneratePrompt;
    private long generation;
    public ObservableCollection<PairingNetwork> Networks { get; } = [];
    public PairingNetwork? Network { get => network; set { if (SetProperty(ref network, value)) { Clear(); GenerateCommand.NotifyCanExecuteChanged(); } } }
    public BitmapImage? Image
    {
        get => image;
        private set { if (SetProperty(ref image, value)) { OnPropertyChanged(nameof(HasImage)); } }
    }
    public bool HasImage => Image is not null;
    public string Note { get => note; private set => SetProperty(ref note, value); }
    public IAsyncRelayCommand GenerateCommand { get; }
    public IRelayCommand OpenConnectionCommand { get; }
    public PairingViewModel(ClientContext context) : base(context)
    {
        GenerateCommand = new AsyncRelayCommand(() => RunAsync(GenerateAsync), () => Network is not null && !Context.Preview);
        OpenConnectionCommand = new RelayCommand(() => Context.Navigate(typeof(Pages.ConnectionPage)));
        timer.Tick += (_, _) => { if (Image is not null && DateTimeOffset.UtcNow >= expires) { Clear(); Note = "二维码已过期，请重新生成。"; } };
    }
    protected override void OnActiveChanged() { if (Active) { timer.Start(); } else { timer.Stop(); Clear(); } }
    protected override async Task RefreshAsync(bool force)
    {
        var host = await Context.ReadStatusAsync(force: force, token: Lifetime.Token);
        var available = new List<PairingNetwork>();
        if (host.ServiceOk)
        {
            if (host.ModuleStatus is { TailscaleEnabled: true, TailscaleAvailable: true })
            { available.Add(new("tailscale", "Tailscale")); }
            if (host.ModuleStatus is { LanEnabled: true, LanAvailable: true })
            { available.Add(new("lan", "同一局域网")); }
            try
            {
#if DEBUG
                var tailcat = Context.Preview ? new TailcatStatus { Enabled = true, Running = true } :
                    await Context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], Lifetime.Token);
#else
                var tailcat = await Context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], Lifetime.Token);
#endif
                if (tailcat is { Enabled: true, Running: true }) { available.Insert(0, new("tailcat", "内置连接（Tailcat）")); }
                NoticeOpen = false;
            }
            catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or TimeoutException
                or System.Text.Json.JsonException or System.ComponentModel.Win32Exception or UnauthorizedAccessException
                or System.Security.SecurityException)
            { Report("暂时无法读取内置连接状态，可使用其他已就绪的连接方式。", true); }
        }
        var selected = Network?.Id;
        if (!Networks.SequenceEqual(available))
        {
            Networks.Clear();
            foreach (var item in available) { Networks.Add(item); }
            Network = Networks.FirstOrDefault(item => item.Id == selected) ?? Networks.FirstOrDefault();
        }
        if (Image is null)
        {
            Note = !host.ServiceOk ? "请在“概览”中启动服务，再刷新。"
                : Networks.Count == 0 ? "暂无可用连接方式。请在“连接”中检查网络设置。"
                : GeneratePrompt;
        }
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
        var receipt = await Context.Agent.PairAsync(selected, Lifetime.Token);
        if (request != generation || !Active) { return; }
        if (!OnboardingCopyCatalog.TryParseRfc3339Timestamp(receipt.PairExpiresAt, requireUtc: false, out var expiry) || expiry <= DateTimeOffset.UtcNow)
        { throw new InvalidOperationException("配对信息无效或已经过期，请重新生成。"); }
        using var qr = QRCodeGenerator.GenerateQrCode(receipt.PairUrl, QRCodeGenerator.ECCLevel.M);
        using var png = new PngByteQRCode(qr);
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(png.GetGraphic(6)); await writer.StoreAsync(); }
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        if (request != generation || !Active) { return; }
        Image = bitmap;
        expires = expiry;
        Note = $"有效期至 {expiry.ToLocalTime():HH:mm:ss}。" + string.Join("\n", receipt.Warnings);
    }
    private void Clear()
    {
        generation++;
        if (Image is null) { return; }
        Image = null;
        Note = GeneratePrompt;
    }
    public override void Dispose() { timer.Stop(); Clear(); base.Dispose(); }
}
public sealed record PairingNetwork(string Id, string Title);
