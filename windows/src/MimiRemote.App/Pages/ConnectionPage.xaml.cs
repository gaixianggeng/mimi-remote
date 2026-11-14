using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class ConnectionPage : ClientPage
{
    public ConnectionViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public ConnectionPage() { InitializeComponent(); }
}
