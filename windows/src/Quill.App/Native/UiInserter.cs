using System.Runtime.InteropServices;
using System.Text;
using Quill;

namespace Quill.Win.Native;

sealed class UiInserter : IInserter
{
    public Action<string> Log { get; set; } = _ => { };
    public IntPtr ClipboardOwner { get; set; }

    IntPtr _targetHwnd;
    bool _pinned;

    public bool IsTrusted => true;

    public void RequestTrust() { }

    public void OpenMicrophoneSettings() =>
        Win32.ShellExecute(IntPtr.Zero, "open", "ms-settings:privacy-microphone", null, null, 1);

    public void OpenAccessibilitySettings() =>
        Win32.ShellExecute(IntPtr.Zero, "open", "ms-settings:easeofaccess-keyboard", null, null, 1);

    public FrontApp Frontmost()
    {
        RememberForeignForeground();
        return new(TitleOf(Win32.GetForegroundWindow()) ?? Win32.ForegroundTitle());
    }

    public CapturedSelection? CaptureSelection()
    {
        _pinned = false;
        _targetHwnd = IntPtr.Zero;
        RememberForeignForeground();
        return null;
    }

    public void NoteClick(double x, double y)
    {
        var hwnd = Win32.WindowFromPoint(new Win32.POINT { X = (int)x, Y = (int)y });
        hwnd = FocusedEditOf(hwnd);
        if (hwnd == IntPtr.Zero || IsOurs(hwnd)) return;
        _targetHwnd = hwnd;
        _pinned = true;
        Log($"click target 0x{hwnd.ToInt64():X} class={ClassName(hwnd)}");
    }

    public void RememberForeignForeground()
    {
        if (_pinned) return;
        var fg = Win32.GetForegroundWindow();
        if (fg == IntPtr.Zero || IsOurs(fg)) return;
        var edit = FocusedEditOf(fg);
        _targetHwnd = edit != IntPtr.Zero ? edit : fg;
    }

    public string? FocusedFieldValue()
    {
        var hwnd = ResolveTarget();
        if (hwnd != IntPtr.Zero)
        {
            var viaMsg = ReadWindowText(hwnd);
            if (!string.IsNullOrEmpty(viaMsg)) return viaMsg;
        }
        if (Win32.UiaGetFocusedElement(out var node) != 0 || node == IntPtr.Zero) return null;
        try
        {
            if (Win32.UiaGetPropertyValue(node, Win32.UIA_ValueValuePropertyId, out var value) == 0)
                return value as string;
            return null;
        }
        catch { return null; }
        finally { Win32.UiaNodeRelease(node); }
    }

    public string DescribeFocus()
    {
        var hwnd = ResolveTarget();
        return $"hwnd=0x{hwnd.ToInt64():X} class={ClassName(hwnd)} ours={IsOurs(hwnd)} inputSize={SendInputLayout.Size}";
    }

    public void Insert(string text, bool atEnd, CapturedSelection? selection, Action<InsertOutcome> done)
    {
        RememberForeignForeground();
        var hwnd = ResolveTarget();
        var app = TitleOf(RootOf(hwnd)) ?? Win32.ForegroundTitle();
        var payload = Spacing.Apply(text, FocusedFieldValue(), atEnd ? FocusedFieldValue()?.Length : null);

        Log($"insert → {app ?? "?"} · {DescribeFocus()} · {payload.Length} chars");

        if (hwnd == IntPtr.Zero || IsOurs(hwnd))
        {
            Log("  no foreign target window");
            done(new InsertOutcome(InsertMethod.Blocked, app));
            return;
        }

        ForceForeground(hwnd);
        hwnd = FocusedEditOf(hwnd);
        if (hwnd == IntPtr.Zero)
        {
            Log("  lost hwnd after focus");
            done(new InsertOutcome(InsertMethod.Blocked, app));
            return;
        }

        var cls = ClassName(hwnd);
        Log($"  focused class={cls} 0x{hwnd.ToInt64():X}");

        if (IsEditClass(cls))
        {
            if (ReplaceSel(hwnd, payload) && ContainsText(hwnd, payload))
            {
                Log("  → EM_REPLACESEL, confirmed");
                Finish(done, InsertMethod.Accessibility, app);
                return;
            }
            var savedEdit = SnapshotClipboard();
            if (SetClipboardText(payload))
            {
                Thread.Sleep(40);
                Win32.SendMessage(hwnd, Win32.WM_PASTE, IntPtr.Zero, IntPtr.Zero);
                Thread.Sleep(40);
                if (ContainsText(hwnd, payload))
                {
                    Log("  → WM_PASTE, confirmed");
                    RestoreClipboardLater(savedEdit);
                    Finish(done, InsertMethod.Clipboard, app);
                    return;
                }
            }
            TypeChars(hwnd, payload);
            Log("  → WM_CHAR to Edit");
            RestoreClipboardLater(savedEdit);
            Finish(done, InsertMethod.Clipboard, app);
            return;
        }

        // Browsers, Electron, terminals: messages often go nowhere. Focus the
        // window and type Unicode — not Ctrl+V, which is also our trigger key.
        var saved = SnapshotClipboard();
        ForceForeground(hwnd);
        if (TypeText(payload))
        {
            Log("  → unicode SendInput");
            RestoreClipboardLater(saved);
            Finish(done, InsertMethod.Clipboard, app);
            return;
        }
        TypeChars(hwnd, payload);
        Log("  → WM_CHAR fallback");
        RestoreClipboardLater(saved);
        Finish(done, InsertMethod.Clipboard, app);
    }

    void Finish(Action<InsertOutcome> done, InsertMethod method, string? app)
    {
        _pinned = false;
        done(new InsertOutcome(method, app));
    }

    IntPtr ResolveTarget()
    {
        if (_targetHwnd != IntPtr.Zero && Win32.IsWindow(_targetHwnd) && !IsOurs(_targetHwnd))
            return _targetHwnd;
        var fg = Win32.GetForegroundWindow();
        if (fg != IntPtr.Zero && !IsOurs(fg)) return FocusedEditOf(fg);
        return IntPtr.Zero;
    }

    static IntPtr RootOf(IntPtr hwnd) =>
        hwnd == IntPtr.Zero ? IntPtr.Zero : Win32.GetAncestor(hwnd, Win32.GA_ROOT);

    IntPtr FocusedEditOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        Win32.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Win32.GetCurrentProcessId()) return IntPtr.Zero;
        var tid = Win32.GetWindowThreadProcessId(hwnd, out _);
        var info = new Win32.GUITHREADINFO { cbSize = Marshal.SizeOf<Win32.GUITHREADINFO>() };
        if (Win32.GetGUIThreadInfo(tid, ref info))
        {
            if (info.hwndFocus != IntPtr.Zero && !IsOurs(info.hwndFocus)) return info.hwndFocus;
            if (info.hwndCaret != IntPtr.Zero && !IsOurs(info.hwndCaret)) return info.hwndCaret;
            if (info.hwndActive != IntPtr.Zero && !IsOurs(info.hwndActive)) return info.hwndActive;
        }
        return IsOurs(hwnd) ? IntPtr.Zero : hwnd;
    }

    void ForceForeground(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        var root = RootOf(hwnd);
        if (root == IntPtr.Zero) root = hwnd;
        var fg = Win32.GetForegroundWindow();
        var fgThread = Win32.GetWindowThreadProcessId(fg, out _);
        var targetThread = Win32.GetWindowThreadProcessId(root, out _);
        var ourThread = Win32.GetCurrentThreadId();
        Win32.AllowSetForegroundWindow(-1);
        var a1 = fgThread != 0 && fgThread != ourThread && Win32.AttachThreadInput(ourThread, fgThread, true);
        var a2 = targetThread != 0 && targetThread != ourThread && targetThread != fgThread
            && Win32.AttachThreadInput(ourThread, targetThread, true);
        try
        {
            Win32.ShowWindow(root, Win32.SW_RESTORE);
            Win32.BringWindowToTop(root);
            Win32.SetForegroundWindow(root);
        }
        finally
        {
            if (a2) Win32.AttachThreadInput(ourThread, targetThread, false);
            if (a1) Win32.AttachThreadInput(ourThread, fgThread, false);
        }
        Thread.Sleep(30);
    }

    static bool ReplaceSel(IntPtr hwnd, string text)
    {
        Win32.SendMessage(hwnd, Win32.EM_REPLACESEL, (IntPtr)1, text);
        return true;
    }

    static bool TypeChars(IntPtr hwnd, string text)
    {
        if (hwnd == IntPtr.Zero) return false;
        foreach (var ch in text)
            Win32.SendMessage(hwnd, Win32.WM_CHAR, (IntPtr)ch, IntPtr.Zero);
        return true;
    }

    static bool ContainsText(IntPtr hwnd, string payload)
    {
        var got = ReadWindowText(hwnd);
        if (string.IsNullOrEmpty(got)) return false;
        var needle = payload.Trim();
        if (needle.Length == 0) return true;
        var tail = needle.Length <= 24 ? needle : needle[^24..];
        return got.Contains(tail, StringComparison.Ordinal);
    }

    static string? ReadWindowText(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return null;
        var len = Win32.SendMessage(hwnd, Win32.WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero).ToInt32();
        if (len <= 0) return null;
        var sb = new StringBuilder(len + 1);
        Win32.SendMessage(hwnd, Win32.WM_GETTEXT, (IntPtr)sb.Capacity, sb);
        return sb.Length == 0 ? null : sb.ToString();
    }

    static bool IsEditClass(string cls)
    {
        cls = cls.ToLowerInvariant();
        return cls is "edit" || cls.Contains("richedit", StringComparison.Ordinal);
    }

    static bool IsOurs(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return false;
        Win32.GetWindowThreadProcessId(hwnd, out var pid);
        return pid == Win32.GetCurrentProcessId();
    }

    static string ClassName(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";
        var sb = new StringBuilder(256);
        Win32.GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    static string? TitleOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return null;
        var sb = new StringBuilder(512);
        Win32.GetWindowText(hwnd, sb, sb.Capacity);
        var t = sb.ToString();
        return string.IsNullOrWhiteSpace(t) ? null : t;
    }

    public static bool TypeText(string text)
    {
        var ok = true;
        foreach (var ch in text)
        {
            var down = SendInputLayout.Key(0, ch, up: false, unicode: true);
            var up = SendInputLayout.Key(0, ch, up: true, unicode: true);
            if (!Send([down, up])) ok = false;
            Thread.Sleep(6);
        }
        return ok;
    }

    public static void PressReturn() => Send([Vk(Win32.VK_RETURN, false), Vk(Win32.VK_RETURN, true)]);

    static SendInputLayout.INPUT Vk(ushort vk, bool up)
    {
        var scan = (ushort)Win32.MapVirtualKey(vk, Win32.MAPVK_VK_TO_VSC);
        return SendInputLayout.Key(vk, scan, up);
    }

    static bool Send(SendInputLayout.INPUT[] inputs)
    {
        var fg = Win32.GetForegroundWindow();
        var fgThread = Win32.GetWindowThreadProcessId(fg, out _);
        var ourThread = Win32.GetCurrentThreadId();
        var attached = fgThread != 0 && fgThread != ourThread && Win32.AttachThreadInput(ourThread, fgThread, true);
        try
        {
            var sent = Win32.SendInput((uint)inputs.Length, inputs, SendInputLayout.Size);
            return sent == (uint)inputs.Length;
        }
        finally
        {
            if (attached) Win32.AttachThreadInput(ourThread, fgThread, false);
        }
    }

    string? SnapshotClipboard()
    {
        if (!Win32.IsClipboardFormatAvailable(Win32.CF_UNICODETEXT)) return null;
        if (!RetryOpenClipboard()) return null;
        try
        {
            var h = Win32.GetClipboardData(Win32.CF_UNICODETEXT);
            if (h == IntPtr.Zero) return null;
            var p = Win32.GlobalLock(h);
            if (p == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(p); }
            finally { Win32.GlobalUnlock(h); }
        }
        finally { Win32.CloseClipboard(); }
    }

    bool SetClipboardText(string text)
    {
        if (!RetryOpenClipboard()) return false;
        try
        {
            Win32.EmptyClipboard();
            var bytes = Encoding.Unicode.GetBytes(text + "\0");
            var h = Win32.GlobalAlloc(Win32.GMEM_MOVEABLE, (UIntPtr)bytes.Length);
            if (h == IntPtr.Zero) return false;
            var p = Win32.GlobalLock(h);
            if (p == IntPtr.Zero) return false;
            Marshal.Copy(bytes, 0, p, bytes.Length);
            Win32.GlobalUnlock(h);
            return Win32.SetClipboardData(Win32.CF_UNICODETEXT, h) != IntPtr.Zero;
        }
        finally { Win32.CloseClipboard(); }
    }

    void RestoreClipboardLater(string? saved)
    {
        if (saved is null) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(900).ConfigureAwait(false);
            try { SetClipboardText(saved); } catch { /* ignore */ }
        });
    }

    bool RetryOpenClipboard()
    {
        var owner = ClipboardOwner;
        for (var i = 0; i < 12; i++)
        {
            if (Win32.OpenClipboard(owner)) return true;
            if (owner != IntPtr.Zero && Win32.OpenClipboard(IntPtr.Zero)) return true;
            Thread.Sleep(20);
        }
        return false;
    }
}
