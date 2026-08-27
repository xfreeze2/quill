using Avalonia;

namespace Quill.Win;

static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // The Windows binary is a PE file and cannot launch here. This guard is
        // for `dotnet run` from the SDK on macOS — never start a second overlay
        // next to the installed Mac Quill app.
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine(
                "This is the Windows build of Quill. On macOS the Swift app is already installed; leaving it alone.");
            return 2;
        }

        if (Environment.GetEnvironmentVariable("QUILL_TEST_UPDATE_CHECK") is { } check)
        {
            return HeadlessUpdateCheck.Run(force: check == "force").GetAwaiter().GetResult();
        }

        // One Quill only: a second copy would install a second keyboard hook
        // and insert everything twice.
        using var single = new Mutex(true, @"Local\com.freeze.quill.single-instance", out var isFirst);
        if (!isFirst) return 0;

        // Any crash leaves a trace in %LOCALAPPDATA%\Quill\Quill.log instead
        // of the app just vanishing.
        var crashLog = new Quill.Log(Quill.Log.DefaultPath);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            crashLog.Write("FATAL: " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            crashLog.Write("unobserved task exception: " + e.Exception);
            e.SetObserved();
        };

        try
        {
            AppBuilder.Configure<App>()
                .UsePlatformDetect()
                .LogToTrace()
                .StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            crashLog.Write("FATAL: " + ex);
            throw;
        }
        return 0;
    }
}

static class HeadlessUpdateCheck
{
    public static async Task<int> Run(bool force)
    {
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true })
        {
            Timeout = TimeSpan.FromSeconds(8),
        };
        var (update, error) = await Quill.Updater.CheckAsync(Quill.BuildInfo.Version, http);
        if (error is not null)
        {
            Console.Error.WriteLine($"UPDATE RESULT: failure raw=\"{error.Message}\" display=\"{error.DisplayMessage}\" isRateLimit={error.IsRateLimit}");
            return 1;
        }
        Console.Error.WriteLine(
            "UPDATE RESULT: success update="
            + (update is null ? "null" : $"({update.Version}, {update.Url})"));
        return 0;
    }
}
