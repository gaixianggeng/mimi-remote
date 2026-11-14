using System.Text.Json;
using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class AssistantsViewModel : ClientPageViewModel
{
    public AssistantCard Codex { get; }
    public AssistantCard Claude { get; }
    public PageState Harness { get; } = new();
    private string harnessStatus = "连接你已启动的 Harness 服务。";
    public string HarnessStatus { get => harnessStatus; private set => SetProperty(ref harnessStatus, value); }
    public IAsyncRelayCommand<string> ConnectCommand { get; }
    public IAsyncRelayCommand ReconnectCommand { get; }
    public IAsyncRelayCommand DisableCommand { get; }
    public AssistantsViewModel(ClientContext context) : base(context)
    {
        Codex = new AssistantCard(context, "codex", "Codex");
        Claude = new AssistantCard(context, "claude", "Claude");
        ConnectCommand = new AsyncRelayCommand<string>(input => Harness.RunAsync(async () =>
        {
            var link = input?.Trim() ?? "";
            if (link.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(link) > 16384) { throw new ArgumentException("请输入有效的 Harness 启动链接（不超过 16 KiB）。"); }
            if (!await Context.Confirm("连接 DeepSeek？", "连接成功后服务会短暂重启，手机连接可能断开。")) { return; }
            await UpdateHarnessAsync(() => Context.Agent.RunWithInputAsync(["runtime", "--deepseek", "connect", "--deepseek-url-stdin", "--json"], link, Lifetime.Token));
        }));
        ReconnectCommand = new AsyncRelayCommand(() => Harness.RunAsync(async () =>
        {
            if (await Context.Confirm("重新连接 DeepSeek？", "凭据有变化时会重启服务，手机连接可能断开。"))
            { await UpdateHarnessAsync(() => Context.Agent.RunAsync(["runtime", "--deepseek", "refresh", "--json"], Lifetime.Token)); }
        }));
        DisableCommand = new AsyncRelayCommand(() => Harness.RunAsync(async () =>
        {
            if (await Context.Confirm("停用 DeepSeek？", "服务会短暂重启，手机连接可能断开。"))
            { await UpdateHarnessAsync(() => Context.Agent.RunAsync(["runtime", "--deepseek", "disabled", "--json"], Lifetime.Token)); }
        }));
    }
    protected override async Task RefreshAsync(bool force)
    {
        var host = await Context.ReadStatusAsync(runtime: true, force: force, token: Lifetime.Token);
        Codex.Update(host); Claude.Update(host);
        var entry = host.RuntimeStatus?.Runtimes.FirstOrDefault(item => item.Id == "deepseek");
        HarnessStatus = entry is null ? "尚未连接 Harness。" : $"{entry.State}\n{entry.Reason}\n{AssistantCard.Quota(entry.RateLimits)}";
    }
    private async Task UpdateHarnessAsync(Func<Task<string>> apply)
    {
        await Context.ChangeAsync(async () =>
        {
            using var document = JsonDocument.Parse(await apply());
            if (document.RootElement.GetProperty("restart_required").GetBoolean())
            {
                try { await Context.Agent.RunAsync(["restart", "--wait", "60s", "--no-pair"], Lifetime.Token); }
                catch (Exception error) when (error is InvalidOperationException or TimeoutException)
                { throw new InvalidOperationException("配置已保存，但服务重启未完成。请运行诊断并重新启动服务。", error); }
            }
        });
        await RefreshAsync(true); Harness.Report("DeepSeek 已更新，请以当前运行状态为准。");
    }
}
public sealed class AssistantCard : PageState
{
    private readonly ClientContext context;
    private readonly string id;
    private bool enabled;
    private bool available;
    private string detail = "";
    private string quota = "";
    public string Title { get; }
    public bool Enabled { get => enabled; set => SetProperty(ref enabled, value); }
    public bool Available { get => available; private set => SetProperty(ref available, value); }
    public string Detail { get => detail; private set => SetProperty(ref detail, value); }
    public string QuotaText { get => quota; private set => SetProperty(ref quota, value); }
    public IAsyncRelayCommand ApplyCommand { get; }
    internal AssistantCard(ClientContext context, string id, string title)
    {
        this.context = context; this.id = id; Title = title;
        ApplyCommand = new AsyncRelayCommand(() => RunAsync(async () =>
        {
            var target = Enabled;
            if (!await context.Confirm($"{(target ? "启用" : "停用")} {Title}？", "服务会短暂重启，手机连接可能断开。")) { return; }
            try
            {
                await context.ChangeAsync(async () =>
                {
                    var host = await new ModuleCommands(context.Agent).SetAsync(id, target);
                    Available = host.ModuleStatus is not null;
                    Enabled = id == "codex" ? host.ModuleStatus?.CodexEnabled == true : host.ModuleStatus?.ClaudeEnabled == true;
                });
                Report("设置已生效。");
            }
            catch { Available = false; throw; }
        }));
    }
    public void Update(HostStatus host)
    {
        if (IsBusy) { return; }
        Available = host.ModuleStatus is not null;
        Enabled = id == "codex" ? host.ModuleStatus?.CodexEnabled == true : host.ModuleStatus?.ClaudeEnabled == true;
        var entry = host.RuntimeStatus?.Runtimes.FirstOrDefault(item => item.Id == id);
        Detail = entry is null ? "尚未读取运行时状态。" : $"{entry.State}  {entry.Version}\n{entry.Reason}";
        QuotaText = Quota(entry?.RateLimits);
    }
    internal static string Quota(RuntimeRateLimits? limits)
    {
        if (limits is null) { return "当前运行时暂未提供额度信息。"; }
        var windows = new[] { limits.Primary, limits.Secondary }.OfType<RateLimitWindow>()
            .Where(window => window.RemainingPercent is not null).Select(window =>
                $"{window.Duration}：剩余 {window.RemainingPercent:0.#}%" + (window.ResetsAt is > 0 and < 253402300800
                    ? $" · {DateTimeOffset.FromUnixTimeSeconds(window.ResetsAt.Value).ToLocalTime():MM-dd HH:mm} 重置" : ""));
        return string.Join("\n", new[] { limits.PlanType ?? "" }.Concat(windows).Append(limits.CreditBalance ?? ""));
    }
}
