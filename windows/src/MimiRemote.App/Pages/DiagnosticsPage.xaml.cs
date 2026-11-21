using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class DiagnosticsPage : ClientPage
{
    public DiagnosticsViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public DiagnosticsPage() { InitializeComponent(); }
}
