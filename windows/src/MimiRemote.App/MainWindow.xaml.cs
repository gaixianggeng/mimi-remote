using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace MimiRemote.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "Mimi Remote";
        SystemBackdrop = new MicaBackdrop();
    }
}
