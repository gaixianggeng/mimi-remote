using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public abstract class ClientPageViewModel : PageState, IDisposable
{
    private int maintenanceDepth;
    private int maintenanceFocusLossObserved;
    private long activationSequence;
    private long suppressedThroughActivation;

    protected ClientContext Context { get; }
    protected CancellationTokenSource Lifetime { get; } = new();
    public IAsyncRelayCommand RefreshCommand { get; }
    public bool Active { get; private set; }

    protected ClientPageViewModel(ClientContext context)
    {
        Context = context;
        RefreshCommand = new AsyncRelayCommand(() => RunAsync(() =>
        {
            if (Context.IsMaintenanceIdentityRejected)
            {
                Report(MaintenanceRunResult.DescribeFailure(Context.MaintenanceRejectionLatch.FailureKind).Message, error: true);
                return Task.CompletedTask;
            }
            return RefreshAsync(true);
        }));
        context.StatusChanged += ContextChanged;
    }

    protected async Task<MaintenanceRunResult> RunPageMaintenanceAsync(
        MaintenancePurpose purpose,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref maintenanceDepth);
        Interlocked.Exchange(ref maintenanceFocusLossObserved, Active ? 0 : 1);
        MaintenanceRunResult? result = null;
        try
        {
            result = await Context.RunMaintenanceAsync(purpose, cancellationToken);
            return result;
        }
        finally
        {
            var focusLost = Interlocked.Exchange(ref maintenanceFocusLossObserved, 0) != 0 || !Active;
            Interlocked.Decrement(ref maintenanceDepth);
            var missingVerifiedPreflight = result is null
                || !result.BrokerVerified
                || result.PostRunPreflight is null;
            if (focusLost || missingVerifiedPreflight || Context.IsMaintenanceIdentityRejected)
            {
                var suppressUpcoming = !Active || (!focusLost && missingVerifiedPreflight);
                SuppressWizardReturnActivationRefresh(suppressUpcoming);
            }
        }
    }

    private void SuppressWizardReturnActivationRefresh(bool suppressUpcoming)
    {
        var target = Volatile.Read(ref activationSequence) + (suppressUpcoming ? 1 : 0);
        while (true)
        {
            var current = Volatile.Read(ref suppressedThroughActivation);
            if (current >= target)
            {
                return;
            }
            if (Interlocked.CompareExchange(ref suppressedThroughActivation, target, current) == current)
            {
                return;
            }
        }
    }

    public async Task SetActiveAsync(bool active)
    {
        if (active == Active)
        {
            return;
        }
        Active = active;
        if (!active && Volatile.Read(ref maintenanceDepth) > 0)
        {
            Interlocked.Exchange(ref maintenanceFocusLossObserved, 1);
            SuppressWizardReturnActivationRefresh(suppressUpcoming: true);
        }
        OnActiveChanged();
        if (active)
        {
            var activation = Interlocked.Increment(ref activationSequence);
            await WhenIdle;
            if (!Active || Lifetime.IsCancellationRequested)
            {
                return;
            }
            if (activation != Volatile.Read(ref activationSequence)
                || activation <= Volatile.Read(ref suppressedThroughActivation)
                || Context.IsMaintenanceIdentityRejected)
            {
                return;
            }
            await RunAsync(() => RefreshAsync(false));
        }
    }

    protected virtual void OnActiveChanged() { }

    public virtual void OnNavigatedFrom()
    {
        Interlocked.Exchange(ref suppressedThroughActivation, 0);
    }

    private async void ContextChanged(object? sender, EventArgs args)
    {
        await WhenIdle;
        if (Active && !Lifetime.IsCancellationRequested && !Context.IsMaintenanceIdentityRejected)
        {
            await RunAsync(() => RefreshAsync(true));
        }
    }

    protected abstract Task RefreshAsync(bool force);

    public virtual void Dispose()
    {
        Active = false;
        Context.StatusChanged -= ContextChanged;
        Lifetime.Cancel();
        Lifetime.Dispose();
        GC.SuppressFinalize(this);
    }
}
