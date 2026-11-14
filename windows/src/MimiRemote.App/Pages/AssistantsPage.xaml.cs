using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class AssistantsPage : ClientPage
{
    public AssistantsViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public AssistantsPage() { InitializeComponent(); }
    private void ConnectHarness(object sender, Microsoft.UI.Xaml.RoutedEventArgs args)
    {
        var input = HarnessLink.Password;
        HarnessLink.Password = "";
        ViewModel.ConnectCommand.Execute(input);
    }
}
