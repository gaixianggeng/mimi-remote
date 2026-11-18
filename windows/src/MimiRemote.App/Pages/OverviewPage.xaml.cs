using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class OverviewPage : ClientPage
{
    public OverviewViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public OverviewPage() { InitializeComponent(); }
}
