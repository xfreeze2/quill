using Quill;

namespace Quill.Win.Native;

/// <summary>
/// Start-at-login via the per-user Run registry key. Earlier builds dropped a
/// .lnk into the Startup folder through WScript.Shell COM, which fails silently
/// on machines without Windows Script Host and under OneDrive-redirected
/// Startup folders; the Run key needs neither, and no admin rights.
/// </summary>
sealed class WinLoginItem : ILoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Quill";

    static string LegacyShortcutPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Startup),
            "Quill.lnk");

    public bool IsEnabled =>
        Win32.ReadUserRegistryString(RunKey, ValueName) is not null
        || File.Exists(LegacyShortcutPath);

    public void SetEnabled(bool enabled)
    {
        // Clear the legacy shortcut either way, so flipping the toggle can
        // never leave two copies of Quill launching at login.
        try { File.Delete(LegacyShortcutPath); } catch { /* best effort */ }

        if (enabled)
        {
            var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Quill.exe");
            Win32.WriteUserRegistryString(RunKey, ValueName, $"\"{exe}\"");
        }
        else
        {
            Win32.DeleteUserRegistryValue(RunKey, ValueName);
        }
    }
}
