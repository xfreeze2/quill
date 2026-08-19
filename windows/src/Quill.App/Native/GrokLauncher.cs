using System.Diagnostics;
using Quill;

namespace Quill.Win.Native;

/// <summary>
/// Opens Grok Build the way you would by hand: a new window in the terminal
/// you already use, then types `grok`. Never starts the command as the process
/// payload (`wt grok` / `cmd /c grok`) — that is the Windows equivalent of
/// `ghostty -e grok`, which produces a session that cannot select or copy.
/// </summary>
sealed class WinGrokLauncher : IGrokLauncher
{
    readonly Action<string> _log;

    public WinGrokLauncher(Action<string> log) => _log = log;

    public void Open(Action<GrokOutcome> done)
    {
        Task.Run(() =>
        {
            GrokOutcome outcome;
            try { outcome = OpenCore(); }
            catch (Exception ex) { outcome = new GrokOutcome.Failed(ex.Message); }
            _log("open Grok → " + outcome);
            done(outcome);
        });
    }

    public void BringToFront()
    {
        var hwnd = FindTerminal();
        if (hwnd != IntPtr.Zero)
        {
            Win32.AllowSetForegroundWindow(-1);
            Win32.ShowWindow(hwnd, 9); // SW_RESTORE
            Win32.SetForegroundWindow(hwnd);
        }
    }

    GrokOutcome OpenCore()
    {
        if (TryWindowsTerminal(out var wt)) return wt;
        if (TryGhostty(out var ghostty)) return ghostty;
        return ViaCmd();
    }

    bool TryWindowsTerminal(out GrokOutcome outcome)
    {
        outcome = new GrokOutcome.Failed("no wt");
        var wt = ResolveWt();
        if (wt is null) return false;
        var before = CountWindows("WindowsTerminal", "Windows Terminal");
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = wt,
                Arguments = "--window new",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            _log("  wt: open failed — " + ex.Message);
            return false;
        }

        if (!WaitForNewWindow(before, "WindowsTerminal", "Windows Terminal", TimeSpan.FromSeconds(8)))
        {
            _log("  wt: no new frontmost window within 8s");
            return false;
        }
        Thread.Sleep(900);
        BringToFront();
        Thread.Sleep(80);
        UiInserter.TypeText("grok");
        Thread.Sleep(80);
        UiInserter.PressReturn();
        outcome = new GrokOutcome.Opened("Windows Terminal");
        return true;
    }

    bool TryGhostty(out GrokOutcome outcome)
    {
        outcome = new GrokOutcome.Failed("no ghostty");
        var exe = ResolveGhostty();
        if (exe is null) return false;
        var before = CountWindows("ghostty", "Ghostty");
        try
        {
            Process.Start(new ProcessStartInfo { FileName = exe, UseShellExecute = true });
        }
        catch
        {
            return false;
        }
        if (!WaitForNewWindow(before, "ghostty", "Ghostty", TimeSpan.FromSeconds(8)))
            return false;
        Thread.Sleep(900);
        UiInserter.TypeText("grok");
        Thread.Sleep(80);
        UiInserter.PressReturn();
        outcome = new GrokOutcome.Opened("Ghostty");
        return true;
    }

    GrokOutcome ViaCmd()
    {
        var before = CountWindows("cmd", "Command Prompt");
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            return new GrokOutcome.Failed("Couldn't open Command Prompt: " + ex.Message);
        }
        if (!WaitForNewWindow(before, "cmd", "Command Prompt", TimeSpan.FromSeconds(8)))
            return new GrokOutcome.Failed("Command Prompt did not come forward");
        Thread.Sleep(400);
        UiInserter.TypeText("grok");
        Thread.Sleep(80);
        UiInserter.PressReturn();
        return new GrokOutcome.Opened("Command Prompt");
    }

    static string? ResolveWt()
    {
        var local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Microsoft", "WindowsApps", "wt.exe");
        if (File.Exists(local)) return local;
        return FindOnPath("wt.exe");
    }

    static string? ResolveGhostty()
    {
        foreach (var c in new[]
                 {
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ghostty", "ghostty.exe"),
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Ghostty", "ghostty.exe"),
                 })
        {
            if (File.Exists(c)) return c;
        }
        return FindOnPath("ghostty.exe");
    }

    static string? FindOnPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir, name);
                if (File.Exists(candidate)) return candidate;
            }
            catch { /* skip bad PATH entries */ }
        }
        return null;
    }

    static int CountWindows(string processName, string titleNeedle)
    {
        var n = 0;
        Win32.EnumWindows((h, _) =>
        {
            if (!Win32.IsWindowVisible(h)) return true;
            Win32.GetWindowThreadProcessId(h, out var pid);
            try
            {
                var p = Process.GetProcessById((int)pid);
                if (p.ProcessName.Contains(processName, StringComparison.OrdinalIgnoreCase)) n++;
            }
            catch { /* process exited */ }
            return true;
        }, IntPtr.Zero);
        return n;
    }

    bool WaitForNewWindow(int before, string processName, string title, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (CountWindows(processName, title) > before)
            {
                var hwnd = FindProcessWindow(processName);
                if (hwnd != IntPtr.Zero)
                {
                    Win32.SetForegroundWindow(hwnd);
                    return true;
                }
            }
            Thread.Sleep(80);
        }
        return false;
    }

    static IntPtr FindProcessWindow(string processName)
    {
        IntPtr found = IntPtr.Zero;
        Win32.EnumWindows((h, _) =>
        {
            if (!Win32.IsWindowVisible(h) || found != IntPtr.Zero) return true;
            Win32.GetWindowThreadProcessId(h, out var pid);
            try
            {
                if (Process.GetProcessById((int)pid).ProcessName
                    .Contains(processName, StringComparison.OrdinalIgnoreCase))
                    found = h;
            }
            catch { /* ignore */ }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    IntPtr FindTerminal()
    {
        foreach (var name in new[] { "WindowsTerminal", "ghostty", "Windows Terminal", "cmd" })
        {
            var h = FindProcessWindow(name);
            if (h != IntPtr.Zero) return h;
        }
        return IntPtr.Zero;
    }
}
