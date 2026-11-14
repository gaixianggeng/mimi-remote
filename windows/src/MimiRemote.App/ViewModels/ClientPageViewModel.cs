using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public abstract class ClientPageViewModel : PageState, IDisposable
{
    protected ClientContext Context { get; }
    protected CancellationTokenSource Lifetime { get; } = new();
    public IAsyncRelayCommand RefreshCommand { get; }
    public bool Active { get; private set; }
    protected ClientPageViewModel(ClientContext context)
    {
        Context = context;
        RefreshCommand = new AsyncRelayCommand(() => RunAsync(() => RefreshAsync(true)));
        context.StatusChanged += ContextChanged;
    }
    public async Task SetActiveAsync(bool active)
    {
        if (active == Active) { return; }
        Active = active;
        OnActiveChanged();
        if (active)
        {
            await WhenIdle;
            if (Active && !Lifetime.IsCancellationRequested) { await RunAsync(() => RefreshAsync(false)); }
        }
    }
    protected virtual void OnActiveChanged() { }
    private async void ContextChanged(object? sender, EventArgs args)
    {
        await WhenIdle;
        if (Active && !Lifetime.IsCancellationRequested) { await RunAsync(() => RefreshAsync(true)); }
    }
    protected abstract Task RefreshAsync(bool force);
    public virtual void Dispose() { Active = false; Context.StatusChanged -= ContextChanged; Lifetime.Cancel(); Lifetime.Dispose(); GC.SuppressFinalize(this); }
}
