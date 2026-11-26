using CommunityToolkit.Mvvm.ComponentModel;

namespace MimiRemote.Core;

public interface IPairingSessionBackend
{
    Task<OnboardingPreflightReport> PreflightPairAsync(CancellationToken cancellationToken);
    Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken);
    Task EnableTransportAsync(string transport, CancellationToken cancellationToken);
    Task<bool> RunLanFirewallMaintenanceAsync(CancellationToken cancellationToken);
    Task<TailcatStatus> ReadTailcatStatusAsync(CancellationToken cancellationToken);
    Task SetTailcatRelayAsync(string[] arguments, CancellationToken cancellationToken);
    Task<bool> ConfirmAsync(string title, string message);
    void OpenSettings(string target);
    void OpenUrl(string url);
    bool CopyToClipboard(string text);
    DateTimeOffset Now();
}

public sealed class PairingSessionController : ObservableObject, IDisposable
{
    public const string DefaultPrompt = "选择连接方式后生成二维码。请勿把二维码发给他人。";

    private readonly IPairingSessionBackend backend;
    private readonly string? verifiedCapability;
    private readonly Dictionary<string, OnboardingResolvedDiagnostic> diagnostics = new(StringComparer.Ordinal);

    private OnboardingPreflightReport? report;
    private IReadOnlyList<OnboardingTransportItem> transports = [];
    private IReadOnlyList<OnboardingWizardRow> blockingRows = [];
    private string selectedTransport = "tailscale";
    private bool hasUserSelectedTransport;
    private bool isBusy;
    private bool isEnablingTransport;
    private bool isIssuing;
    private string note = DefaultPrompt;
    private string countdownText = "";
    private bool didCopyLink;
    private string? issuedPairUrl;
    private DateTimeOffset? issuedExpiresAt;
    private string? issuedNetwork;
    private ulong generation;
    private CancellationTokenSource? issueCts;

    private TailcatStatus? tailcatStatus;
    private int relayChoice;
    private string relayAddress = "";
    private bool relayEdited;
    private bool syncingRelay;
    private string relayNotice = "";
    private bool relayNoticeOpen;
    private bool relayFailed;
    private bool active;
    private bool disposed;

    public event EventHandler<string?>? TicketChanged;

    public PairingSessionController(IPairingSessionBackend backend, string? verifiedCapability = null)
    {
        this.backend = backend;
        this.verifiedCapability = verifiedCapability;
        transports = BuildTransports();
    }

    public OnboardingPreflightReport? Report { get => report; private set => SetProperty(ref report, value); }
    public IReadOnlyList<OnboardingTransportItem> Transports { get => transports; private set => SetProperty(ref transports, value); }
    public IReadOnlyList<OnboardingWizardRow> BlockingRows { get => blockingRows; private set => SetProperty(ref blockingRows, value); }
    public bool HasBlockingRows => BlockingRows.Count > 0;

    public string SelectedTransport
    {
        get => selectedTransport;
        private set
        {
            if (SetProperty(ref selectedTransport, value))
            {
                OnPropertyChanged(nameof(SelectedTransportItem));
                OnPropertyChanged(nameof(IsTailcatSelected));
                OnPropertyChanged(nameof(CanGenerate));
                OnPropertyChanged(nameof(CanEnableSelectedTransport));
                OnPropertyChanged(nameof(CanCopyLink));
            }
        }
    }

    public OnboardingTransportItem? SelectedTransportItem =>
        Transports.FirstOrDefault(t => string.Equals(t.Id, SelectedTransport, StringComparison.Ordinal));

    public bool IsTailcatSelected => string.Equals(SelectedTransport, "tailcat", StringComparison.Ordinal);

    public bool IsBusy
    {
        get => isBusy;
        private set
        {
            if (SetProperty(ref isBusy, value))
            {
                NotifyActionState();
            }
        }
    }

    public bool IsEnablingTransport
    {
        get => isEnablingTransport;
        private set
        {
            if (SetProperty(ref isEnablingTransport, value))
            {
                NotifyActionState();
            }
        }
    }

    public bool IsIssuing
    {
        get => isIssuing;
        private set
        {
            if (SetProperty(ref isIssuing, value))
            {
                NotifyActionState();
            }
        }
    }

    public string Note { get => note; private set => SetProperty(ref note, value); }
    public string CountdownText { get => countdownText; private set => SetProperty(ref countdownText, value); }
    public bool DidCopyLink { get => didCopyLink; private set => SetProperty(ref didCopyLink, value); }
    public DateTimeOffset? IssuedExpiresAt => issuedExpiresAt;
    public bool HasActiveTicket => !string.IsNullOrWhiteSpace(issuedPairUrl) && !IsExpired;
    public bool IsExpired => issuedExpiresAt is DateTimeOffset expiry && backend.Now() >= expiry;

    public bool CanGenerate =>
        !IsBusy
        && !IsEnablingTransport
        && !IsIssuing
        && Report is { Stage: "pair", Ok: true }
        && SelectedTransportItem is { Ready: true };

    public bool CanEnableSelectedTransport =>
        !IsBusy
        && !IsEnablingTransport
        && Report is { Stage: "pair", Configured: true }
        && SelectedTransportItem is { CanEnableInPlace: true };

    public bool CanCopyLink =>
        HasActiveTicket
        && active
        && string.Equals(issuedNetwork, SelectedTransport, StringComparison.Ordinal)
        && SelectedTransportItem is { Ready: true };

    public int RelayChoice
    {
        get => relayChoice;
        set
        {
            if (SetProperty(ref relayChoice, value))
            {
                if (!syncingRelay)
                {
                    relayEdited = true;
                }
                OnPropertyChanged(nameof(IsCustomRelay));
            }
        }
    }

    public bool IsCustomRelay => RelayChoice == 1;

    public string RelayAddress
    {
        get => relayAddress;
        set
        {
            if (SetProperty(ref relayAddress, value) && !syncingRelay)
            {
                relayEdited = true;
            }
        }
    }

    public string RelayNotice { get => relayNotice; private set => SetProperty(ref relayNotice, value); }
    public bool RelayNoticeOpen { get => relayNoticeOpen; set => SetProperty(ref relayNoticeOpen, value); }
    public bool RelayFailed { get => relayFailed; private set => SetProperty(ref relayFailed, value); }

    public void SetActive(bool isActive)
    {
        if (active == isActive)
        {
            return;
        }
        active = isActive;
        if (!isActive)
        {
            Clear();
        }
        NotifyActionState();
    }

    /// <summary>Selecting a transport clears any active ticket and NEVER writes or enables anything.</summary>
    public void SelectTransport(string transportId)
    {
        if (!OnboardingWizardStateMachine.OrderedTransportIds.Contains(transportId, StringComparer.Ordinal))
        {
            return;
        }
        hasUserSelectedTransport = true;
        if (string.Equals(SelectedTransport, transportId, StringComparison.Ordinal))
        {
            return;
        }
        SelectedTransport = transportId;
        Clear();
        UpdateIdleNote();
    }

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        if (disposed)
        {
            return;
        }
        IsBusy = true;
        try
        {
            var latest = await backend.PreflightPairAsync(cancellationToken).ConfigureAwait(false);
            if (disposed || cancellationToken.IsCancellationRequested)
            {
                return;
            }
            ApplyReport(latest);
            if (latest.Configured)
            {
                await RefreshTailcatRelayAsync(cancellationToken).ConfigureAwait(false);
            }
            if (!CanGenerate)
            {
                Clear();
            }
            UpdateIdleNote();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Clear();
            Note = error is OnboardingCliException { Diagnostic: { } diag }
                ? diag.Message
                : OnboardingCopyCatalog.SafeFallbackCopy;
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async Task EnableSelectedTransportAsync(CancellationToken cancellationToken = default)
    {
        if (disposed || IsEnablingTransport || Report is not { Stage: "pair", Configured: true })
        {
            return;
        }
        var target = SelectedTransport;
        var item = SelectedTransportItem;
        if (item is null || item.Ready)
        {
            return;
        }
        Clear();
        if (string.Equals(target, "lan", StringComparison.Ordinal))
        {
            if (item.BlockedByPublicNetwork)
            {
                Note = item.Detail;
                backend.OpenSettings("windows_network_profile");
                return;
            }
            if (item.NeedsFirewallMaintenance)
            {
                IsEnablingTransport = true;
                try
                {
                    var ok = await backend.RunLanFirewallMaintenanceAsync(cancellationToken).ConfigureAwait(false);
                    if (!ok)
                    {
                        Note = "未完成专用网络防火墙规则配置，同一局域网保持关闭。你仍可使用其他连接方式。";
                        return;
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception error) when (error is OnboardingCliException or InvalidOperationException or InvalidDataException
                    or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
                {
                    Note = error is OnboardingCliException { Diagnostic: { } diag }
                        ? diag.Message
                        : "防火墙规则配置未完成，同一局域网保持关闭。";
                    return;
                }
                finally
                {
                    IsEnablingTransport = false;
                }
                await RefreshAsync(cancellationToken).ConfigureAwait(false);
                if (CanGenerate)
                {
                    await GenerateAsync(cancellationToken).ConfigureAwait(false);
                }
                return;
            }
        }

        if (!item.CanEnableInPlace)
        {
            return;
        }

        IsEnablingTransport = true;
        try
        {
            await backend.EnableTransportAsync(target, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Note = error is OnboardingCliException { Diagnostic: { } diag }
                ? diag.Message
                : OnboardingCopyCatalog.SafeFallbackCopy;
            return;
        }
        finally
        {
            IsEnablingTransport = false;
        }

        await RefreshAsync(cancellationToken).ConfigureAwait(false);
        if (CanGenerate && string.Equals(SelectedTransport, target, StringComparison.Ordinal))
        {
            await GenerateAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task GenerateAsync(CancellationToken cancellationToken = default)
    {
        if (disposed || !CanGenerate)
        {
            return;
        }
        var target = SelectedTransport;
        Clear();
        var request = ++generation;
        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        issueCts = cts;
        IsIssuing = true;
        try
        {
            var receipt = await backend.PairAsync(target, cts.Token).ConfigureAwait(false);
            if (cts.Token.IsCancellationRequested || request != generation || !active || disposed
                || !string.Equals(SelectedTransport, target, StringComparison.Ordinal))
            {
                return;
            }
            if (!OnboardingCopyCatalog.IsValidPairUrl(receipt.PairUrl)
                || !OnboardingCopyCatalog.TryParseRfc3339Timestamp(receipt.PairExpiresAt, requireUtc: false, out var expiry)
                || expiry <= backend.Now())
            {
                Note = "配对信息无效或已经过期，请刷新二维码。";
                return;
            }
            issuedPairUrl = receipt.PairUrl;
            issuedExpiresAt = expiry;
            issuedNetwork = target;
            DidCopyLink = false;
            CountdownText = OnboardingWizardStateMachine.FormatCountdown(expiry - backend.Now(), expiry);
            Note = receipt.Warnings.Count > 0
                ? string.Join("\n", receipt.Warnings)
                : "请使用手机端 Mimi Remote 扫描二维码，或点击“复制配对链接”。";
            NotifyActionState();
            TicketChanged?.Invoke(this, issuedPairUrl);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            if (request == generation && !disposed)
            {
                Clear();
                Note = error is OnboardingCliException { Diagnostic: { } diag }
                    ? diag.Message
                    : OnboardingCopyCatalog.SafeFallbackCopy;
            }
        }
        finally
        {
            if (request == generation)
            {
                IsIssuing = false;
            }
        }
    }

    public bool CopyPairingLink()
    {
        TickCountdown();
        if (!CanCopyLink || string.IsNullOrWhiteSpace(issuedPairUrl))
        {
            return false;
        }
        var copied = backend.CopyToClipboard(issuedPairUrl);
        DidCopyLink = copied;
        return copied;
    }

    public void TickCountdown()
    {
        if (issuedPairUrl is null || issuedExpiresAt is not DateTimeOffset expiry)
        {
            return;
        }
        var remaining = expiry - backend.Now();
        if (remaining <= TimeSpan.Zero)
        {
            Clear();
            Note = "二维码已过期。请点击“刷新二维码”后重扫，已有配对不受影响。";
            return;
        }
        CountdownText = OnboardingWizardStateMachine.FormatCountdown(remaining, expiry);
    }

    public async Task ApplyRelayAsync(CancellationToken cancellationToken = default)
    {
        if (disposed || IsBusy)
        {
            return;
        }
        var choiceName = RelayChoice switch
        {
            1 => "custom",
            2 => "mimi",
            _ => "default",
        };
        var url = string.Equals(choiceName, "custom", StringComparison.Ordinal) ? RelayAddress.Trim() : "";
        string[] arguments;
        try
        {
            arguments = RelayPolicy.Arguments(choiceName, url);
        }
        catch (ArgumentException error)
        {
            ReportRelay(error.Message, failed: true);
            return;
        }

        IsBusy = true;
        try
        {
            var before = await backend.ReadTailcatStatusAsync(cancellationToken).ConfigureAwait(false);
            if (RelayPolicy.NeedsConfirmation(choiceName, url, before)
                && !await backend.ConfirmAsync("更换中转服务？", "内置连接会短暂重连，使用该线路的手机可能需要重新扫码。").ConfigureAwait(false))
            {
                return;
            }
            await backend.SetTailcatRelayAsync(arguments, cancellationToken).ConfigureAwait(false);
            relayEdited = false;
            Clear();
            await RefreshTailcatRelayAsync(cancellationToken).ConfigureAwait(false);
            ReportRelay(
                tailcatStatus?.Enabled != true
                    ? "中转配置已保存，开启内置连接后生效。"
                    : string.Equals(choiceName, "mimi", StringComparison.Ordinal)
                        ? "中转设置已更新，已开通的手机会自动跟随。"
                        : "中转设置已更新，请重新生成二维码配对。",
                failed: false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            ReportRelay(
                error is OnboardingCliException { Diagnostic: { } diag } ? diag.Message : OnboardingCopyCatalog.SafeFallbackCopy,
                failed: true);
        }
        finally
        {
            IsBusy = false;
        }
    }

    public void OpenTransportHelp()
    {
        var item = SelectedTransportItem;
        if (item?.Fix is null)
        {
            return;
        }
        if (string.Equals(item.Fix.Kind, "open_url", StringComparison.Ordinal)
            && item.Fix.Url is not null
            && OnboardingCopyCatalog.IsAllowedUrl(item.Fix.Url))
        {
            backend.OpenUrl(item.Fix.Url);
        }
        else if (string.Equals(item.Fix.Kind, "open_settings", StringComparison.Ordinal)
            && item.Fix.Target is not null
            && OnboardingCopyCatalog.IsAllowedSettingsTarget(item.Fix.Target))
        {
            backend.OpenSettings(item.Fix.Target);
        }
    }

    public void Clear()
    {
        generation++;
        issueCts?.Cancel();
        issueCts?.Dispose();
        issueCts = null;
        IsIssuing = false;
        var hadTicket = issuedPairUrl is not null;
        issuedPairUrl = null;
        issuedExpiresAt = null;
        issuedNetwork = null;
        DidCopyLink = false;
        CountdownText = "";
        NotifyActionState();
        if (hadTicket)
        {
            TicketChanged?.Invoke(this, null);
        }
    }

    private void ApplyReport(OnboardingPreflightReport latest)
    {
        Report = latest;
        diagnostics.Clear();
        var blockers = new List<OnboardingWizardRow>();
        foreach (var row in latest.Checks)
        {
            var ctx = new OnboardingValidationContext
            {
                Surface = "check",
                Platform = "windows",
                Stage = latest.Stage,
                Configured = latest.Configured,
                HasRecommendedTransport = true,
                RecommendedTransport = latest.RecommendedTransport,
                VerifiedCapability = verifiedCapability,
            };
            OnboardingResolvedDiagnostic? diag = null;
            if (OnboardingCopyCatalog.TryValidateCheck(row, ctx, out var resolved, out _))
            {
                diagnostics[row.Id] = resolved;
                diag = resolved;
            }
            if (row.Blocking)
            {
                blockers.Add(new OnboardingWizardRow(
                    row,
                    diag,
                    "需处理",
                    diag is { Trusted: true } ? diag.Message : row.Detail,
                    diag?.AllowedFix is not null ? OnboardingWizardStateMachine.FormatFixLabel(diag.AllowedFix) : null,
                    diag?.AllowedFix is not null,
                    diag?.SecondaryLabel,
                    diag?.SecondaryFix is not null,
                    CanResetPin: false,
                    Skipped: false,
                    CandidateSummary: ""));
            }
        }
        BlockingRows = blockers;
        OnPropertyChanged(nameof(HasBlockingRows));
        Transports = BuildTransports();

        if (!hasUserSelectedTransport
            && latest.RecommendedTransport is { Length: > 0 } recommended
            && OnboardingWizardStateMachine.OrderedTransportIds.Contains(recommended, StringComparer.Ordinal)
            && !string.Equals(SelectedTransport, recommended, StringComparison.Ordinal))
        {
            Clear();
            SelectedTransport = recommended;
        }
        NotifyActionState();
    }

    private async Task RefreshTailcatRelayAsync(CancellationToken cancellationToken)
    {
        try
        {
            tailcatStatus = await backend.ReadTailcatStatusAsync(cancellationToken).ConfigureAwait(false);
            if (!relayEdited)
            {
                syncingRelay = true;
                RelayChoice = tailcatStatus.Choice switch
                {
                    "custom" => 1,
                    "mimi" => 2,
                    _ => 0,
                };
                RelayAddress = string.Equals(tailcatStatus.Choice, "custom", StringComparison.Ordinal)
                    ? tailcatStatus.DerpMapUrl
                    : "";
                syncingRelay = false;
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException or IOException
            or TimeoutException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
        }
    }

    private List<OnboardingTransportItem> BuildTransports()
    {
        var list = new List<OnboardingTransportItem>(3);
        foreach (var id in OnboardingWizardStateMachine.OrderedTransportIds)
        {
            var checkId = $"network_{id}";
            var check = Report?.Checks.FirstOrDefault(c => string.Equals(c.Id, checkId, StringComparison.Ordinal));
            diagnostics.TryGetValue(checkId, out var diag);
            var title = id switch
            {
                "tailscale" => "Tailscale",
                "tailcat" => "内置连接（Tailcat）",
                _ => "同一局域网",
            };
            var enabled = check?.Enabled == true;
            var available = check?.Available == true;
            var ready = check is { State: "ok", Enabled: true, Available: true };
            var firewallBlocked = string.Equals(check?.Code, "lan_firewall_blocked", StringComparison.Ordinal);
            var publicBlocked = string.Equals(check?.Code, "lan_public_network_blocked", StringComparison.Ordinal);
            var canEnable = !ready && ((!enabled && available) || firewallBlocked);
            var badge = ready
                ? "已就绪"
                : check is null
                    ? "正在检查"
                    : firewallBlocked
                        ? "需要防火墙规则"
                        : publicBlocked
                            ? "公用网络已阻止"
                            : available
                                ? "可就地启用"
                                : "暂不可用";
            var detail = diag is { Trusted: true }
                ? diag.Message
                : check?.Detail ?? "等待检查连接状态。";
            list.Add(new OnboardingTransportItem(
                id,
                title,
                badge,
                detail,
                enabled,
                available,
                ready,
                canEnable,
                firewallBlocked,
                publicBlocked,
                check?.Code,
                diag?.AllowedFix));
        }
        return list;
    }

    private void UpdateIdleNote()
    {
        if (HasActiveTicket)
        {
            return;
        }
        var selected = SelectedTransportItem;
        if (Report is null)
        {
            Note = "正在检查电脑连接与服务状态…";
            return;
        }
        if (selected is { Ready: true } && Report.Ok)
        {
            Note = DefaultPrompt;
            return;
        }
        if (selected is { CanEnableInPlace: true })
        {
            Note = selected.NeedsFirewallMaintenance
                ? "同一局域网需要通过签名安装程序配置专用网络防火墙规则。点击“启用此连接方式”继续。"
                : $"{selected.Title} 可用但尚未启用。点击“启用此连接方式”即可就地开启并生成二维码。";
            return;
        }
        Note = selected?.Detail ?? DefaultPrompt;
    }

    private void ReportRelay(string message, bool failed)
    {
        RelayNotice = message;
        RelayFailed = failed;
        RelayNoticeOpen = true;
    }

    private void NotifyActionState()
    {
        OnPropertyChanged(nameof(SelectedTransportItem));
        OnPropertyChanged(nameof(HasActiveTicket));
        OnPropertyChanged(nameof(IsExpired));
        OnPropertyChanged(nameof(CanGenerate));
        OnPropertyChanged(nameof(CanEnableSelectedTransport));
        OnPropertyChanged(nameof(CanCopyLink));
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        Clear();
    }
}
