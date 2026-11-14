using Microsoft.UI.Xaml;
using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class SessionsPage : ClientPage
{
    public SessionsViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;
    public SessionsPage()
    {
        InitializeComponent();
        ActualThemeChanged += (_, _) => ViewModel.ApplyRows();
    }
    private void FiltersResized(object sender, SizeChangedEventArgs args)
    {
        var narrow = args.NewSize.Width < 540;
        Microsoft.UI.Xaml.Controls.Grid.SetRow(ProjectFilter, narrow ? 1 : 0);
        Microsoft.UI.Xaml.Controls.Grid.SetColumn(ProjectFilter, narrow ? 0 : 1);
        Microsoft.UI.Xaml.Controls.Grid.SetColumnSpan(ProjectFilter, narrow ? 2 : 1);
    }
}
