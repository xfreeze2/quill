using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;
using Quill.Win.Native;

namespace Quill.Win;

public partial class App : Application
{
    QuillHost? _host;

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
        RequestedThemeVariant = ThemeVariant.Dark;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownMode = Avalonia.Controls.ShutdownMode.OnExplicitShutdown;
            ComSupport.TryInit();
            _host = new QuillHost(desktop);
            _host.Start();
            desktop.Exit += (_, _) => _host.Dispose();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
