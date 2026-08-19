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

        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace()
            .StartWithClassicDesktopLifetime(args);
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
