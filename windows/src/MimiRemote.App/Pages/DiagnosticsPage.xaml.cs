using Microsoft.UI.Xaml;
using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class DiagnosticsPage : ClientPage
{
    public DiagnosticsViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;

    public DiagnosticsPage()
    {
        InitializeComponent();
    }

    private void FixCheckClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            ViewModel.FixCheckCommand.Execute(id);
        }
    }
}
