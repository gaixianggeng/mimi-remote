using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class PairingPage : ClientPage
{
    public PairingViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public PairingPage() { InitializeComponent(); }
}
