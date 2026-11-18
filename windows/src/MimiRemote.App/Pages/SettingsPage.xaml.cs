using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class SettingsPage : ClientPage
{
    public SettingsViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public SettingsPage() { InitializeComponent(); }
}
