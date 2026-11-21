using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MimiRemote.App.Controls;

public sealed partial class SessionStatusBadge : UserControl
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(string), typeof(SessionStatusBadge),
        new PropertyMetadata("Neutral", (sender, _) => ((SessionStatusBadge)sender).UpdateState()));
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(nameof(Label), typeof(string), typeof(SessionStatusBadge), new PropertyMetadata(""));
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(SessionStatusBadge), new PropertyMetadata(""));
    public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }
    public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
    public SessionStatusBadge() { InitializeComponent(); Loaded += (_, _) => UpdateState(); }
    private void UpdateState() => VisualStateManager.GoToState(this, Kind, false);
}
