using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class SetupPage : ClientPage
{
    public SetupViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public SetupPage() { InitializeComponent(); }
}
