using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using MimiRemote.App.ViewModels;

namespace MimiRemote.App;

public abstract class ClientPage : Page
{
    public static InfoBarSeverity NoticeSeverity(bool failed) => failed ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
    public abstract ClientPageViewModel Model { get; }
    protected ClientPage() { NavigationCacheMode = NavigationCacheMode.Required; }
    protected override void OnNavigatedFrom(NavigationEventArgs e) { _ = Model.SetActiveAsync(false); base.OnNavigatedFrom(e); }
}
