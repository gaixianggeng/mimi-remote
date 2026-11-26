using Microsoft.UI.Xaml;
using MimiRemote.App.ViewModels;

namespace MimiRemote.App.Pages;

public sealed partial class SetupPage : ClientPage
{
    private long qrRenderGeneration;

    public SetupViewModel ViewModel { get; } = new(App.Services);
    public override ClientPageViewModel Model => ViewModel;

    public SetupPage()
    {
        InitializeComponent();
        ViewModel.QrPayloadChanged += OnQrPayloadChanged;
    }

    private void RowPrimaryClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            ViewModel.RowPrimaryActionCommand.Execute(id);
        }
    }

    private void RowSecondaryClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            ViewModel.RowSecondaryActionCommand.Execute(id);
        }
    }

    private void ResetPinClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            ViewModel.ResetRuntimePinCommand.Execute(id);
        }
    }

    private void SelectTransportClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            ViewModel.SelectTransportCommand.Execute(id);
        }
    }

    private async void OnQrPayloadChanged(object? sender, string? payload)
    {
        var current = ++qrRenderGeneration;
        if (string.IsNullOrWhiteSpace(payload))
        {
            Step4QrImage.Source = null;
            return;
        }
        try
        {
            var bitmap = await QrCodeRenderer.RenderAsync(payload);
            if (current == qrRenderGeneration && ViewModel.Wizard.HasIssuedTicket)
            {
                Step4QrImage.Source = bitmap;
            }
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or System.Runtime.InteropServices.COMException)
        {
            if (current == qrRenderGeneration)
            {
                Step4QrImage.Source = null;
                ViewModel.Report("生成二维码图像失败，请刷新重试。", error: true);
            }
        }
    }
}
