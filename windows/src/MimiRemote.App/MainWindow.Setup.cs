using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MimiRemote.Core;
using Windows.Storage.Pickers;

namespace MimiRemote.App;

public sealed partial class MainWindow
{
    private readonly DesktopPreferences preferences = DesktopPreferences.Load();
    private string workspaceRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "code");

    private void RenderSetup()
    {
        var content = new StackPanel { Spacing = 16 };
        content.Children.Add(Text("先选一个代码目录", 26));
        content.Children.Add(Text("Mimi 会在这里发现项目，并允许已配对的手机浏览此目录。请选择你希望从手机访问的文件夹。"));
        content.Children.Add(Text("使用 Codex 前，需要在这台电脑安装 Codex 并登录。Mimi 不会代你登录；也可以启用已登录的 Claude，或连接运行中的 DeepSeek Harness。"));
        var root = new TextBox { Header = "代码目录", Text = workspaceRoot };
        content.Children.Add(root);
        content.Children.Add(Action("选择文件夹…", async () =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is not null) { workspaceRoot = folder.Path; root.Text = folder.Path; }
        }));
        content.Children.Add(Text("已有电脑配置时只更新目录；现有配对和内置连接身份会保留。目录变更需要短暂重启服务。"));
        content.Children.Add(Action("完成设置并连接手机", async () =>
        {
            var selected = root.Text.Trim();
            if (!Path.IsPathFullyQualified(selected)) { throw new ArgumentException("请选择完整的代码目录路径。"); }
            if (!Directory.Exists(selected))
            {
                if (selected != workspaceRoot || !await ConfirmAsync("创建代码目录？", "所选文件夹不存在，是否创建后继续？")) { return; }
                Directory.CreateDirectory(selected);
            }
            if (!await ConfirmAsync("使用这个代码目录？", "已配对的手机将能浏览此目录。服务会短暂重启，手机连接可能断开。")) { return; }
            var agent = RequireClient();
            if (!File.Exists(DesktopPreferences.ConfigPath))
            {
                await agent.RunAsync(["setup", "--scan-root", selected, "--browse-root", selected, "--json", "--qr-only"], lifetime.Token);
                await agent.RunAsync(["start", "--wait", "60s", "--no-pair"], lifetime.Token);
            }
            host = await new ModuleCommands(agent).SetWorkspaceAsync(selected, lifetime.Token);
            workspaceRoot = selected;
            preferences.SetupCompleted = true;
            preferences.Save();
            // Navigate directly; ExecuteAsync is still running, so do not re-enter its gate.
            ShowPage("pair");
            Render();
            await GeneratePairAsync(0);
        }));
        Body.Children.Add(Card(content));
    }

    private void RenderAssistants()
    {
        var modules = host?.ModuleStatus;
        foreach (var id in new[] { "codex", "claude" })
        {
            var entry = host?.RuntimeStatus?.Runtimes.FirstOrDefault(item => item.Id == id);
            var content = new StackPanel { Spacing = 12 };
            var label = id == "codex" ? "Codex" : "Claude";
            content.Children.Add(Text(label, 22));
            content.Children.Add(Text(entry is null ? "尚未读取运行时状态。" : $"{entry.State}  {entry.Version}\n{entry.Reason}"));
            var enabled = id == "codex" ? modules?.CodexEnabled : modules?.ClaudeEnabled;
            var toggle = new ToggleSwitch { Header = $"启用 {label}", IsOn = enabled ?? false, IsEnabled = modules is not null };
            toggle.Toggled += async (_, _) =>
            {
                var target = toggle.IsOn;
                await ExecuteAsync(async () =>
                {
                    if (!await ConfirmAsync($"{(target ? "启用" : "停用")} {label}？", "服务会短暂重启，手机连接会断开。请先结束正在进行的任务。")) { Render(); return; }
                    await ApplyModuleAsync(id, target);
                    Render();
                    ShowSuccess("设置已生效", $"{label} 已{(target ? "启用" : "停用")}。");
                });
                if (!disposed) { Render(); }
            };
            content.Children.Add(toggle);
            if (modules is null) { content.Children.Add(Text("启动或更新电脑服务后才能调整开关。")); }
            AddRateLimits(content, entry?.RateLimits);
            Body.Children.Add(Card(content));
        }
        var deepseek = new StackPanel { Spacing = 12 };
        deepseek.Children.Add(Text("DeepSeek Harness", 22));
        var runtime = host?.RuntimeStatus?.Runtimes.FirstOrDefault(item => item.Id == "deepseek");
        deepseek.Children.Add(Text(runtime is null ? "连接你已启动的 Harness 服务。" : $"{runtime.State}\n{runtime.Reason}"));
        var link = new PasswordBox { Header = "Harness 启动链接", PlaceholderText = "粘贴包含短期凭据的启动链接" };
        deepseek.Children.Add(link);
        deepseek.Children.Add(Text("链接通过标准输入交给电脑服务，不放入命令行或客户端设置文件。"));
        deepseek.Children.Add(Action("连接 Harness", async () =>
        {
            var input = link.Password.Trim();
            link.Password = "";
            if (input.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(input) > 16384) { throw new ArgumentException("请输入有效的 Harness 启动链接（不超过 16 KiB）。"); }
            if (!await ConfirmAsync("连接 DeepSeek？", "连接成功后会重启电脑服务，手机连接会短暂断开。")) { return; }
            var result = await RequireClient().RunWithInputAsync(["runtime", "--deepseek", "connect", "--deepseek-url-stdin", "--json"], input, lifetime.Token);
            await FinishDeepSeekAsync(result);
        }));
        var controls = Row();
        controls.Children.Add(Action("检测并重新连接", async () =>
        {
            if (!await ConfirmAsync("重新连接 DeepSeek？", "凭据有变化时会重新加载服务，手机连接可能短暂断开。")) { return; }
            await FinishDeepSeekAsync(await RequireClient().RunAsync(["runtime", "--deepseek", "refresh", "--json"], lifetime.Token));
        }));
        controls.Children.Add(Action("停用 DeepSeek", async () =>
        {
            if (!await ConfirmAsync("停用 DeepSeek？", "服务会短暂重启，手机连接会断开。")) { return; }
            await FinishDeepSeekAsync(await RequireClient().RunAsync(["runtime", "--deepseek", "disabled", "--json"], lifetime.Token));
        }));
        deepseek.Children.Add(controls);
        AddRateLimits(deepseek, runtime?.RateLimits);
        Body.Children.Add(Card(deepseek));
    }

    private async Task FinishDeepSeekAsync(string result)
    {
        using var document = JsonDocument.Parse(result);
        if (document.RootElement.GetProperty("restart_required").GetBoolean())
        {
            try { await RequireClient().RunAsync(["restart", "--wait", "60s", "--no-pair"], lifetime.Token); }
            catch (Exception error) when (error is InvalidOperationException or TimeoutException)
            {
                throw new InvalidOperationException("DeepSeek 配置已保存，但服务重启未完成。请运行诊断并重新启动服务。", error);
            }
        }
        await RefreshAsync();
        ShowSuccess("DeepSeek 已更新", document.RootElement.GetProperty("message").GetString() ?? "请以当前运行时状态为准。");
    }

    private static void AddRateLimits(StackPanel content, RuntimeRateLimits? limits)
    {
        content.Children.Add(Text("使用额度", 16));
        if (limits is null) { content.Children.Add(Text("当前运行时暂未提供额度信息。")); return; }
        if (!string.IsNullOrWhiteSpace(limits.PlanType)) { content.Children.Add(Text($"方案：{limits.PlanType}")); }
        foreach (var window in new[] { limits.Primary, limits.Secondary }.OfType<RateLimitWindow>())
        {
            if (window.RemainingPercent is not double percent) { continue; }
            var reset = window.ResetsAt is > 0 and < 253402300800 ? $" · {DateTimeOffset.FromUnixTimeSeconds(window.ResetsAt.Value).ToLocalTime():MM-dd HH:mm} 重置" : "";
            content.Children.Add(Text($"{window.Duration}：剩余 {percent:0.#}%{reset}"));
            content.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = percent });
        }
        if (!string.IsNullOrWhiteSpace(limits.CreditBalance)) { content.Children.Add(Text($"余额：{limits.CreditBalance}")); }
        if (limits.Primary is null && limits.Secondary is null) { content.Children.Add(Text(limits.UnavailableReason ?? "额度暂不可用。")); }
    }

    private void ShowSuccess(string title, string message)
    {
        Notice.Title = title;
        Notice.Message = message;
        Notice.Severity = InfoBarSeverity.Success;
        Notice.IsOpen = true;
    }

    private void RenderNetworkModules()
    {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(Text("其他连接方式", 22));
        foreach (var id in new[] { "tailscale", "lan" })
        {
            var label = id == "lan" ? "局域网" : "Tailscale";
            var enabled = id == "lan" ? host?.ModuleStatus?.LanEnabled : host?.ModuleStatus?.TailscaleEnabled;
            var toggle = new ToggleSwitch { Header = $"允许 {label} 连接", IsOn = enabled ?? false, IsEnabled = host?.ModuleStatus is not null };
            toggle.Toggled += async (_, _) =>
            {
                var target = toggle.IsOn;
                await ExecuteAsync(async () =>
                {
                    if (!await ConfirmAsync($"{(target ? "允许" : "关闭")} {label} 连接？", id == "lan" && target
                        ? "同一局域网内的设备将能连接 Mimi。仅在信任的专用网络启用；服务会检查防火墙策略并短暂重启。"
                        : "服务会短暂重启，手机连接会断开。Tailscale 需要在电脑和手机上安装并登录。")) { return; }
                    await ApplyModuleAsync(id, target);
                    ShowSuccess("连接设置已生效", $"{label} 已{(target ? "允许" : "关闭")}。");
                });
                if (!disposed) { Render(); }
            };
            content.Children.Add(toggle);
        }
        if (host?.ModuleStatus is null) { content.Children.Add(Text("启动或更新电脑服务后才能调整连接设置。")); }
        Body.Children.Add(Card(content));
    }

    private async Task ApplyModuleAsync(string id, bool enabled)
    {
        try { host = await new ModuleCommands(RequireClient()).SetAsync(id, enabled, lifetime.Token); }
        catch
        {
            if (host is not null) { host = host with { ModuleStatus = null }; }
            throw;
        }
    }
}
