using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MimiRemote.Core;
using QRCoder;
using Windows.Storage.Streams;

namespace MimiRemote.App;

public sealed partial class MainWindow
{
    private TextBlock? connectionState;
    private ComboBox? relayChoice;
    private TextBox? relayAddress;
    private bool relayEdited;
    private bool relaySyncing;

    private void RenderOverview()
    {
        var summary = new StackPanel { Spacing = 12 };
        summary.Children.Add(Text(host?.Title ?? "正在读取电脑状态", 26));
        summary.Children.Add(Text("在手机上继续电脑里的项目与会话。关闭这个窗口后，电脑服务仍然运行。"));
        if (host is not null)
        {
            summary.Children.Add(Text($"已发现 {host.Projects} 个项目 · agentd {host.Version}"));
            if (!string.IsNullOrEmpty(host.ServiceError)) { summary.Children.Add(Text(host.ServiceError)); }
            var controls = Row();
            controls.Children.Add(Action("启动服务", () => ServiceAsync("start")));
            controls.Children.Add(Action("重新启动", () => ServiceAsync("restart")));
            controls.Children.Add(Action("停止服务", () => ServiceAsync("stop")));
            summary.Children.Add(controls);
        }
        Body.Children.Add(Card(summary));

        var connection = new StackPanel { Spacing = 12 };
        connection.Children.Add(Text("连接手机", 20));
        connection.Children.Add(Text(tailcat?.Running == true
            ? $"内置连接运行中 · 已配对 {tailcat.PairedDeviceCount} 台设备"
            : "通过内置连接、Tailscale 或同一局域网连接。"));
        connection.Children.Add(Action("显示配对二维码", () =>
        {
            ShowPage("pair");
            return Task.CompletedTask;
        }));
        Body.Children.Add(Card(connection));
        foreach (var runtime in host?.RuntimeStatus?.Runtimes ?? [])
        {
            var content = new StackPanel { Spacing = 8 };
            content.Children.Add(Text(runtime.Title, 20));
            content.Children.Add(Text(runtime.Enabled ? $"{runtime.State}  {runtime.Version}" : "尚未启用"));
            if (!string.IsNullOrEmpty(runtime.Reason)) { content.Children.Add(Text(runtime.Reason)); }
            Body.Children.Add(Card(content));
        }
    }

    private async Task ServiceAsync(string action)
    {
        if (action != "start" && !await ConfirmAsync(action == "stop" ? "停止电脑服务？" : "重新启动电脑服务？",
            "手机上的连接会暂时断开。正在进行的会话可能受到影响。")) { return; }
        var arguments = action == "stop" ? new[] { action }
            : new[] { action, "--wait", "60s", "--no-pair" };
        await RequireClient().RunAsync(arguments, lifetime.Token);
        await RefreshAsync();
    }

    private void RenderPairing()
    {
        if (!preview && !File.Exists(DesktopPreferences.ConfigPath)) { RenderSetup(); return; }
        var content = new StackPanel { Spacing = 16 };
        content.Children.Add(Text("用手机扫一扫", 26));
        content.Children.Add(Text("打开 Mimi Remote 手机端，在添加电脑时扫描此处二维码。二维码仅用于短期配对。"));
        var network = new ComboBox { Header = "连接方式", HorizontalAlignment = HorizontalAlignment.Stretch };
        network.Items.Add("内置连接（Tailcat）");
        network.Items.Add("Tailscale");
        network.Items.Add("同一局域网");
        network.SelectedIndex = 0;
        content.Children.Add(network);
        pairImage = new Image { Width = 280, Height = 280, HorizontalAlignment = HorizontalAlignment.Left };
        pairNote = Text("点击生成二维码。请勿把二维码发给他人。");
        content.Children.Add(Action("生成二维码", () => GeneratePairAsync(network.SelectedIndex)));
        content.Children.Add(pairImage);
        content.Children.Add(pairNote);
        Body.Children.Add(Card(content));
    }

    private async Task GeneratePairAsync(int network)
    {
        if (page != "pair" || pairImage is null || pairNote is null) { return; }
        ClearPairing();
        var generation = pairGeneration;
        string[] arguments = network switch
        {
            1 => ["pair", "--network", "tailscale", "--qr-only", "--json"],
            2 => ["pair", "--network", "lan", "--qr-only", "--json"],
            _ => ["tailcat", "pair", "--qr-only", "--json"],
        };
        var pairing = await RequireClient().ReadAsync<PairingInfo>(arguments, lifetime.Token);
        if (generation != pairGeneration || disposed) { return; }
        if (string.IsNullOrWhiteSpace(pairing.PairUrl) ||
            !DateTimeOffset.TryParse(pairing.PairExpiresAt, out var expiry) || expiry <= DateTimeOffset.UtcNow)
        {
            throw new InvalidDataException("配对信息无效或已经过期，请重新生成。");
        }
        using var qr = QRCodeGenerator.GenerateQrCode(pairing.PairUrl, QRCodeGenerator.ECCLevel.M);
        using var png = new PngByteQRCode(qr);
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(png.GetGraphic(6));
            await writer.StoreAsync();
        }
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        if (generation != pairGeneration || disposed) { return; }
        pairImage.Source = bitmap;
        pairExpiry = expiry;
        pairNote.Text = $"有效期至 {expiry.ToLocalTime():HH:mm:ss}。\n" + string.Join("\n", pairing.Warnings);
    }

    private void RenderConnection()
    {
        relayEdited = false;
        RenderNetworkModules();
        var content = new StackPanel { Spacing = 16 };
        content.Children.Add(Text("内置连接", 24));
        connectionState = Text("");
        content.Children.Add(connectionState);
        content.Children.Add(Text("无需额外安装联网工具。优先使用端到端加密直连，无法直连时通过中转连接。"));
        content.Children.Add(Action(tailcat?.Enabled == true ? "关闭内置连接" : "开启内置连接", async () =>
        {
            var enabled = tailcat?.Enabled != true;
            if (!await ConfirmAsync(enabled ? "开启内置连接？" : "关闭内置连接？", enabled
                ? "连接会使用默认中继发现对端；网络允许时转为直连。不新增 Windows 防火墙规则。"
                : "使用内置连接的手机会断开。Tailscale 和局域网不受影响。")) { return; }
            await RequireClient().RunAsync(["tailcat", enabled ? "enable" : "disable", "--json"], lifetime.Token);
            await RefreshAsync();
        }));
        Body.Children.Add(Card(content));

        var relay = new StackPanel { Spacing = 12 };
        relay.Children.Add(Text("中转服务", 20));
        var choice = new ComboBox { Header = "选择中转", HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var label in new[] { "默认 Tailcat 自带", "自建中转", "Mimi 中转" }) { choice.Items.Add(label); }
        choice.SelectedIndex = tailcat?.Choice switch { "custom" => 1, "mimi" => 2, _ => 0 };
        var address = new TextBox
        {
            Header = "DERP Map HTTPS 地址",
            Text = tailcat?.Choice == "custom" ? tailcat.DerpMapUrl : "",
            PlaceholderText = "https://relay.example.com/derpmap.json",
            Visibility = choice.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed
        };
        relayChoice = choice;
        relayAddress = address;
        choice.SelectionChanged += (_, _) =>
        {
            address.Visibility = choice.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            if (!relaySyncing) { relayEdited = true; }
        };
        address.TextChanged += (_, _) => { if (!relaySyncing) { relayEdited = true; } };
        relay.Children.Add(choice);
        relay.Children.Add(address);
        relay.Children.Add(Text("Mimi 中转：已开通的手机会自动切换，没开通的手机继续走免费线路。"));
        relay.Children.Add(Action("应用中转设置", async () =>
        {
            var selected = choice.SelectedIndex switch { 1 => "custom", 2 => "mimi", _ => "default" };
            var url = selected == "custom" ? address.Text.Trim() : "";
            var arguments = RelayPolicy.Arguments(selected, url);
            var current = await RequireClient().ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], lifetime.Token);
            if (RelayPolicy.NeedsConfirmation(selected, url, current) &&
                !await ConfirmAsync("更换中转服务？", "本机的内置连接会短暂重连，使用该线路的手机可能需要重新扫码。Tailscale 和局域网连接不受影响。")) { return; }
            await RequireClient().RunAsync(arguments, lifetime.Token);
            await RefreshAsync();
            Notice.Title = "中转设置已更新";
            Notice.Message = selected == "mimi" ? "已开通的手机会自动跟随，无需重新扫码。" : "请在连接手机页面生成二维码，重新配对使用内置连接的手机。";
            Notice.Severity = InfoBarSeverity.Success;
            Notice.IsOpen = true;
        }));
        Body.Children.Add(Card(relay));
        UpdateConnectionControls();
    }

    private void UpdateConnectionControls()
    {
        if (connectionState is not null)
        {
            connectionState.Text = tailcat?.Running == true
                ? "运行中 · " + (tailcat.Choice == "mimi" ? "Mimi 中转" : tailcat.Choice == "custom" ? "自建中转" : "默认中转")
                : "尚未运行";
        }
        if (relayEdited || relayChoice is null || relayAddress is null) { return; }
        relaySyncing = true;
        relayChoice.SelectedIndex = tailcat?.Choice switch { "custom" => 1, "mimi" => 2, _ => 0 };
        relayAddress.Text = tailcat?.Choice == "custom" ? tailcat.DerpMapUrl : "";
        relaySyncing = false;
    }

    private void RenderDiagnostics()
    {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(Text("诊断与日志", 24));
        content.Children.Add(Text("检查服务、运行环境与连接。结果在这里显示，便于查找需要处理的问题。"));
        var output = new TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 300,
            MaxHeight = 700,
            Header = "诊断结果",
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono")
        };
        var buttons = Row();
        buttons.Children.Add(Action("运行诊断", async () =>
        {
            output.Header = "诊断结果";
            output.Text = await RequireClient().RunAsync(["doctor"], allowFailure: true, cancellationToken: lifetime.Token);
        }));
        buttons.Children.Add(Action("读取最近日志", async () =>
        {
            output.Header = "最近日志";
            var log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Mimi Remote", "logs", "agentd.log");
            using var stream = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, stream.Length - 65536), SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            output.Text = await reader.ReadToEndAsync(lifetime.Token);
        }));
        content.Children.Add(buttons);
        content.Children.Add(output);
        Body.Children.Add(Card(content));
    }
}
