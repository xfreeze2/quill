using Quill;

namespace Quill.Win.Native;

sealed class WinLoginItem : ILoginItem
{
    static string ShortcutPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Startup),
            "Quill.lnk");

    public bool IsEnabled => File.Exists(ShortcutPath);

    public void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Quill.exe");
            if (!OperatingSystem.IsWindows()) return;
            try
            {
                var type = Type.GetTypeFromProgID("WScript.Shell");
                if (type is null) return;
                dynamic shell = Activator.CreateInstance(type)!;
                dynamic shortcut = shell.CreateShortcut(ShortcutPath);
                shortcut.TargetPath = exe;
                shortcut.WorkingDirectory = Path.GetDirectoryName(exe);
                shortcut.Description = "Quill";
                shortcut.Save();
            }
            catch
            {
                // Startup folder write can fail under redirected folders; leave disabled.
            }
        }
        else
        {
            try { File.Delete(ShortcutPath); } catch { /* ignore */ }
        }
    }
}
