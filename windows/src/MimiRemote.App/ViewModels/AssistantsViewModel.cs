using System.Text;
using System.Text.Json;
using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class AssistantsViewModel : ClientPageViewModel
{
    public AssistantCard Codex { get; }
    public AssistantCard Claude { get; }
    public AssistantCard Agy { get; }
    public PageState Harness { get; } = new();

    private string harnessBadge = "未连接";
    private string harnessStatus = "连接你已启动的 Harness 服务。";
    private string harnessQuota = "";

    public string HarnessBadge { get => harnessBadge; private set => SetProperty(ref harnessBadge, value); }
    public string HarnessStatus { get => harnessStatus; private set => SetProperty(ref harnessStatus, value); }
    public string HarnessQuota { get => harnessQuota; private set => SetProperty(ref harnessQuota, value); }
    public IAsyncRelayCommand<string> ConnectCommand { get; }
    public IAsyncRelayCommand ReconnectCommand { get; }
    public IAsyncRelayCommand DisableCommand { get; }

    public AssistantsViewModel(ClientContext context) : base(context)
    {
        Codex = new AssistantCard(context, "codex", "Codex");
        Claude = new AssistantCard(context, "claude", "Claude Code");
        Agy = new AssistantCard(context, "agy", "Antigravity");

        ConnectCommand = new AsyncRelayCommand<string>(input => Harness.RunAsync(async () =>
        {
            var link = input?.Trim() ?? "";
            if (link.Length == 0 || Encoding.UTF8.GetByteCount(link) > 16384)
            {
                throw new ArgumentException("请输入有效的 Harness 启动链接（不超过 16 KiB）。");
            }
            if (!await Context.Confirm("连接 DeepSeek？", "连接成功后服务会短暂重启。"))
            {
                return;
            }
            await UpdateHarnessAsync(() => Context.Agent.RunWithInputAsync(["runtime", "--deepseek", "connect", "--deepseek-url-stdin", "--json"], link, Lifetime.Token));
        }));
        ReconnectCommand = new AsyncRelayCommand(() => Harness.RunAsync(async () =>
        {
            if (await Context.Confirm("重新连接 DeepSeek？", "凭据有变化时会重启服务。"))
            {
                await UpdateHarnessAsync(() => Context.Agent.RunAsync(["runtime", "--deepseek", "refresh", "--json"], Lifetime.Token));
            }
        }));
        DisableCommand = new AsyncRelayCommand(() => Harness.RunAsync(async () =>
        {
            if (await Context.Confirm("停用 DeepSeek？", "服务会短暂重启。"))
            {
                await UpdateHarnessAsync(() => Context.Agent.RunAsync(["runtime", "--deepseek", "disabled", "--json"], Lifetime.Token));
            }
        }));
    }

    protected override async Task RefreshAsync(bool force)
    {
        var host = await Context.ReadStatusAsync(runtime: true, force: force, token: Lifetime.Token);
        OnboardingPreflightReport? preflight = Context.LastPreflight;
        if (!Context.Preview && Context.HasAgent)
        {
            try
            {
                preflight = await Context.Agent.PreflightAsync(
                    new OnboardingPreflightOptions
                    {
                        Stage = "pair",
                        ProgressJson = false,
                        VerifiedConfigured = true,
                        VerifiedCapability = Context.VerifiedCapability,
                    },
                    onProgress: null,
                    platform: "windows",
                    cancellationToken: Lifetime.Token);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error) when (error is InvalidOperationException or InvalidDataException
                or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            {
            }
        }

        Codex.Update(host, FindCheck(preflight, "assistant_codex"));
        Claude.Update(host, FindCheck(preflight, "assistant_claude"));
        Agy.Update(host, FindCheck(preflight, "assistant_agy"));

        var deepSeekEntry = host.RuntimeStatus?.Runtimes.FirstOrDefault(item => string.Equals(item.Id, "deepseek", StringComparison.Ordinal));
        var deepSeekCheck = FindCheck(preflight, "assistant_deepseek");
        var deepSeekEnabled = deepSeekEntry?.Enabled ?? (deepSeekCheck?.Enabled == true);
        var presentation = AssistantRuntimePresentation.Describe("deepseek", "DeepSeek", deepSeekEnabled, deepSeekEntry, deepSeekCheck);
        HarnessBadge = presentation.BadgeText;
        HarnessStatus = presentation.DetailText;
        HarnessQuota = presentation.QuotaText;
    }

    private static OnboardingCheck? FindCheck(OnboardingPreflightReport? report, string id) =>
        report?.Checks.FirstOrDefault(c => string.Equals(c.Id, id, StringComparison.Ordinal));

    private async Task UpdateHarnessAsync(Func<Task<string>> apply)
    {
        await Context.ChangeAsync(async () =>
        {
            using var document = JsonDocument.Parse(await apply());
            if (document.RootElement.TryGetProperty("restart_required", out var prop) && prop.GetBoolean())
            {
                try
                {
                    await Context.Agent.RunAsync(["restart", "--wait", "60s", "--no-pair"], Lifetime.Token);
                }
                catch (Exception error) when (error is InvalidOperationException or TimeoutException)
                {
                    throw new InvalidOperationException("配置已保存，但服务重启未完成。请运行诊断并重新启动服务。", error);
                }
            }
        });
        await RefreshAsync(true);
        Harness.Report("DeepSeek 已更新，请以当前运行状态为准。");
    }
}

public sealed class AssistantCard : PageState
{
    private readonly ClientContext context;
    private readonly string id;
    private bool enabled;
    private bool available;
    private bool supported = true;
    private string badge = "正在检查";
    private string detail = "";
    private string quota = "";

    public string Id => id;
    public string Title { get; }
    public bool Enabled { get => enabled; set => SetProperty(ref enabled, value); }
    public bool Available { get => available; private set => SetProperty(ref available, value); }
    public bool Supported
    {
        get => supported;
        private set
        {
            if (SetProperty(ref supported, value))
            {
                OnPropertyChanged(nameof(CanToggle));
            }
        }
    }

    public bool CanToggle => Available && Supported;
    public string Badge { get => badge; private set => SetProperty(ref badge, value); }
    public string Detail { get => detail; private set => SetProperty(ref detail, value); }
    public string QuotaText { get => quota; private set => SetProperty(ref quota, value); }
    public IAsyncRelayCommand ApplyCommand { get; }

    internal AssistantCard(ClientContext context, string id, string title)
    {
        this.context = context;
        this.id = id;
        Title = title;
        ApplyCommand = new AsyncRelayCommand(() => RunAsync(async () =>
        {
            if (!Supported)
            {
                throw new InvalidOperationException(OnboardingCopyCatalog.LocalizedMessage(
                    "runtime_unsupported_platform",
                    AssistantRuntimePresentation.CheckIdForRuntime(id),
                    Title));
            }
            var target = Enabled;
            if (!await context.Confirm($"{(target ? "启用" : "停用")} {Title}？", "服务会短暂重启以应用更改。"))
            {
                return;
            }
            try
            {
                await context.ChangeAsync(async () =>
                {
                    var host = await new ModuleCommands(context.Agent).SetAsync(id, target);
                    Available = host.ModuleStatus is not null;
                    Enabled = ReadEnabledFlag(host.ModuleStatus, id);
                });
                Report("设置已生效。");
            }
            catch (Exception error) when (error is InvalidOperationException or InvalidDataException or IOException or TimeoutException
                or ArgumentException or System.Text.Json.JsonException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            {
                Available = false;
                OnPropertyChanged(nameof(CanToggle));
                throw;
            }
        }));
    }

    public void Update(HostStatus host, OnboardingCheck? preflightCheck = null)
    {
        if (IsBusy)
        {
            return;
        }
        var moduleEnabled = ReadEnabledFlag(host.ModuleStatus, id);
        var entry = host.RuntimeStatus?.Runtimes.FirstOrDefault(item => string.Equals(item.Id, id, StringComparison.Ordinal));
        var presentation = AssistantRuntimePresentation.Describe(id, Title, moduleEnabled, entry, preflightCheck);

        Supported = presentation.Supported;
        Available = host.ModuleStatus is not null && presentation.Supported;
        Enabled = presentation.Enabled;
        Badge = presentation.BadgeText;
        Detail = presentation.DetailText;
        QuotaText = presentation.QuotaText;
        OnPropertyChanged(nameof(CanToggle));
    }

    private static bool ReadEnabledFlag(ModuleStatus? modules, string runtimeId) => runtimeId switch
    {
        "codex" => modules?.CodexEnabled == true,
        "claude" => modules?.ClaudeEnabled == true,
        "agy" => modules?.AgyEnabled == true,
        _ => false,
    };
}
