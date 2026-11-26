using Microsoft.UI.Xaml;
using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class PairingPage : ClientPage
{
    public PairingViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;

    public PairingPage()
    {
        InitializeComponent();
    }

    private void SelectTransportClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            ViewModel.SelectTransportCommand.Execute(id);
        }
    }
}
