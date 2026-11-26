using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class PairingViewModel : ClientPageViewModel
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly PairingSessionController session;
    private BitmapImage? image;
    private long renderGeneration;

    public PairingSessionController Session => session;

    public BitmapImage? Image
    {
        get => image;
        private set
        {
            if (SetProperty(ref image, value))
            {
                OnPropertyChanged(nameof(HasImage));
            }
        }
    }

    public bool HasImage => Image is not null;

    public IRelayCommand<string> SelectTransportCommand { get; }
    public IAsyncRelayCommand EnableTransportCommand { get; }
    public IAsyncRelayCommand GenerateCommand { get; }
    public IRelayCommand CopyLinkCommand { get; }
    public IAsyncRelayCommand ApplyRelayCommand { get; }
    public IRelayCommand OpenHelpCommand { get; }
    public IRelayCommand OpenFallbackDownloadCommand { get; }
    public IRelayCommand OpenConnectionCommand { get; }

    public PairingViewModel(ClientContext context) : base(context)
    {
        session = new PairingSessionController(new ClientContextPairingBackend(context), context.VerifiedCapability);
        session.TicketChanged += OnTicketChanged;
        timer.Tick += (_, _) => session.TickCountdown();

        SelectTransportCommand = new RelayCommand<string>(id =>
        {
            if (!string.IsNullOrWhiteSpace(id))
            {
                session.SelectTransport(id);
            }
        });
        EnableTransportCommand = new AsyncRelayCommand(() => RunAsync(() => session.EnableSelectedTransportAsync(Lifetime.Token)));
        GenerateCommand = new AsyncRelayCommand(() => RunAsync(() => session.GenerateAsync(Lifetime.Token)));
        CopyLinkCommand = new RelayCommand(() =>
        {
            if (session.CopyPairingLink())
            {
                Report("已复制短期配对链接。请勿发送给他人。");
            }
        });
        ApplyRelayCommand = new AsyncRelayCommand(() => RunAsync(() => session.ApplyRelayAsync(Lifetime.Token)));
        OpenHelpCommand = new RelayCommand(() => session.OpenTransportHelp());
        OpenFallbackDownloadCommand = new RelayCommand(() => session.OpenFallbackDownload());
        OpenConnectionCommand = new RelayCommand(() => Context.NavigateRoute(OnboardingNavigationGate.RouteConnection));
    }

    public override void OnNavigatedFrom() => session.InvalidateForNavigation();

    protected override void OnActiveChanged()
    {
        session.SetActive(Active);
        if (Active)
        {
            timer.Start();
        }
        else
        {
            timer.Stop();
            Image = null;
        }
    }

    protected override async Task RefreshAsync(bool force)
    {
        if (Context.Preview)
        {
            return;
        }
        await session.RefreshAsync(Lifetime.Token);
    }

    private async void OnTicketChanged(object? sender, string? pairUrl)
    {
        var current = ++renderGeneration;
        if (string.IsNullOrWhiteSpace(pairUrl))
        {
            Image = null;
            return;
        }
        try
        {
            var bitmap = await QrCodeRenderer.RenderAsync(pairUrl);
            if (current == renderGeneration && Active && session.HasActiveTicket)
            {
                Image = bitmap;
            }
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or System.Runtime.InteropServices.COMException)
        {
            if (current == renderGeneration)
            {
                Image = null;
                Report("生成二维码图像失败，请刷新重试。", error: true);
            }
        }
    }

    public override void Dispose()
    {
        timer.Stop();
        session.TicketChanged -= OnTicketChanged;
        session.Dispose();
        Image = null;
        base.Dispose();
    }

    private sealed class ClientContextPairingBackend(ClientContext context) : IPairingSessionBackend
    {
        public Task<OnboardingPreflightReport> PreflightPairAsync(CancellationToken cancellationToken) =>
            context.ReadPreflightAsync(
                new OnboardingPreflightOptions
                {
                    Stage = "pair",
                    ProgressJson = false,
                    VerifiedConfigured = true,
                    VerifiedCapability = context.VerifiedCapability,
                },
                onProgress: null,
                cancellationToken: cancellationToken);

        public Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken) =>
            context.Agent.PairAsync(network, cancellationToken);

        public Task EnableTransportAsync(string transport, CancellationToken cancellationToken) =>
            context.ChangeAsync(async () =>
            {
                if (string.Equals(transport, "tailcat", StringComparison.Ordinal))
                {
                    await context.Agent.RunAsync(["tailcat", "enable", "--json"], cancellationToken);
                }
                else
                {
                    await new ModuleCommands(context.Agent).SetAsync(transport, enabled: true, cancellationToken);
                }
            });

        public Func<CancellationToken, Task<MaintenanceRunResult>>? RunLanFirewallMaintenance =>
            context.RunInstallerMaintenance is { } run
                ? ct => run(MaintenancePurpose.LanFirewall, ct)
                : null;

        public Task<TailcatStatus> ReadTailcatStatusAsync(CancellationToken cancellationToken) =>
            context.Agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], cancellationToken);

        public Task SetTailcatRelayAsync(string[] arguments, CancellationToken cancellationToken) =>
            context.ChangeAsync(() => context.Agent.RunAsync(arguments, cancellationToken));

        public Task<bool> ConfirmAsync(string title, string message) => context.Confirm(title, message);
        public void OpenSettings(string target) => context.OpenSettings(target);
        public void OpenUrl(string url) => context.OpenUrl(url);
        public bool CopyToClipboard(string text) => context.CopyToClipboard(text);
        public DateTimeOffset Now() => DateTimeOffset.UtcNow;
    }
}
