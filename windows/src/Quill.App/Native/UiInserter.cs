using System.Runtime.InteropServices;
using System.Text;
using Quill;

namespace Quill.Win.Native;

sealed class UiInserter : IInserter
{
    public Action<string> Log { get; set; } = _ => { };
    public IntPtr ClipboardOwner { get; set; }

    IntPtr _lastForeignHwnd;

    public bool IsTrusted => true;

    public void RequestTrust() { }

    public void OpenMicrophoneSettings() =>
        Win32.ShellExecute(IntPtr.Zero, "open", "ms-settings:privacy-microphone", null, null, 1);

    public void OpenAccessibilitySettings() =>
        Win32.ShellExecute(IntPtr.Zero, "open", "ms-settings:easeofaccess-keyboard", null, null, 1);

    public FrontApp Frontmost()
    {
        RememberForeignForeground();
        return new(Win32.ForegroundTitle());
    }

    public void RememberForeignForeground()
    {
        var fg = Win32.GetForegroundWindow();
        if (fg == IntPtr.Zero) return;
        Win32.GetWindowThreadProcessId(fg, out var pid);
        if (pid != 0 && pid != Win32.GetCurrentProcessId())
            _lastForeignHwnd = fg;
    }

    public CapturedSelection? CaptureSelection() => null;

    public string? FocusedFieldValue()
    {
        if (Win32.UiaGetFocusedElement(out var node) != 0 || node == IntPtr.Zero) return null;
        try
        {
            if (Win32.UiaGetPropertyValue(node, Win32.UIA_ValueValuePropertyId, out var value) == 0)
                return value as string;
            return null;
        }
        catch
        {
            return null;
        }
        finally
        {
            Win32.UiaNodeRelease(node);
        }
    }

    public string DescribeFocus()
    {
        if (Win32.UiaGetFocusedElement(out var node) != 0 || node == IntPtr.Zero)
            return "focused element: <none>";
        try
        {
            Win32.UiaGetPropertyValue(node, Win32.UIA_NamePropertyId, out var name);
            Win32.UiaGetPropertyValue(node, Win32.UIA_ValueValuePropertyId, out var value);
            return $"name={name ?? "—"} valueReadable={value is string} sendInputSize={SendInputLayout.Size}";
        }
        catch
        {
            return "focused element: <error>";
        }
        finally
        {
            Win32.UiaNodeRelease(node);
        }
    }

    public void Insert(string text, bool atEnd, CapturedSelection? selection, Action<InsertOutcome> done)
    {
        RememberForeignForeground();
        RestoreTargetFocus();

        var app = Frontmost().Name;
        var payload = text;
        var existing = FocusedFieldValue();
        var offset = atEnd && existing is not null ? existing.Length : existing?.Length;
        payload = Spacing.Apply(payload, existing, offset);

        Log($"insert → {app ?? "?"} · {DescribeFocus()} · inputSize={SendInputLayout.Size}");

        if (TrySetValue(existing, payload, atEnd) && ConfirmLanded(payload))
        {
            Log("  → accessibility, confirmed");
            done(new InsertOutcome(InsertMethod.Accessibility, app));
            return;
        }

        if (InsertViaClipboard(payload))
        {
            Log("  → clipboard fallback (Ctrl+V posted)");
            done(new InsertOutcome(InsertMethod.Clipboard, app));
            return;
        }

        if (TypeText(payload))
        {
            Log("  → unicode fallback");
            done(new InsertOutcome(InsertMethod.Clipboard, app));
            return;
        }

        Log("  → blocked — SendInput failed");
        done(new InsertOutcome(InsertMethod.Blocked, app));
    }

    bool TrySetValue(string? existing, string payload, bool atEnd)
    {
        if (Win32.UiaGetFocusedElement(out var node) != 0 || node == IntPtr.Zero) return false;
        try
        {
            if (Win32.UiaGetPatternProvider(node, Win32.UIA_ValuePatternId, out var unk) != 0 || unk is null)
                return false;
            IValueProvider? provider = null;
            try { provider = unk as IValueProvider; } catch { /* QI failed */ }
            if (provider is null)
            {
                try
                {
                    var punk = Marshal.GetIUnknownForObject(unk);
                    provider = Marshal.GetTypedObjectForIUnknown(punk, typeof(IValueProvider)) as IValueProvider;
                    Marshal.Release(punk);
                }
                catch { return false; }
            }
            if (provider is null) return false;
            provider.get_IsReadOnly(out var readOnly);
            if (readOnly) return false;
            var next = atEnd && existing is not null ? existing + payload : payload;
            provider.SetValue(next);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            Win32.UiaNodeRelease(node);
        }
    }

    /// <summary>
    /// Unlike Mac AX, Windows UIA often reports success and changes nothing.
    /// An unreadable field is NOT confirmation — fall through to paste.
    /// </summary>
    bool ConfirmLanded(string payload)
    {
        var readback = FocusedFieldValue();
        if (readback is null) return false;
        var needle = payload.Trim();
        if (needle.Length == 0) return true;
        var tail = needle.Length <= 24 ? needle : needle[^24..];
        return readback.Contains(tail, StringComparison.Ordinal);
    }

    bool InsertViaClipboard(string text)
    {
        var saved = SnapshotClipboard();
        if (!SetClipboardText(text))
        {
            Log("  clipboard write failed");
            return false;
        }

        // Give the clipboard a beat to publish. Stay on this thread so SendInput
        // runs with a message pump — a threadpool SendInput is dropped.
        Thread.Sleep(40);
        RestoreTargetFocus();

        var pasted = PasteChord() || PostPaste() || PasteViaKeybdEvent();
        _ = Task.Run(async () =>
        {
            await Task.Delay(800).ConfigureAwait(false);
            RestoreClipboard(saved);
        });
        return pasted;
    }

    void RestoreTargetFocus()
    {
        var fg = Win32.GetForegroundWindow();
        Win32.GetWindowThreadProcessId(fg, out var pid);
        if (pid == Win32.GetCurrentProcessId() && _lastForeignHwnd != IntPtr.Zero)
        {
            Win32.AllowSetForegroundWindow(-1);
            Win32.SetForegroundWindow(_lastForeignHwnd);
            Thread.Sleep(30);
        }
    }

    bool PasteChord()
    {
        var inputs = new[]
        {
            Vk(Win32.VK_LCONTROL, false),
            Vk(Win32.VK_V, false),
            Vk(Win32.VK_V, true),
            Vk(Win32.VK_LCONTROL, true),
        };
        return Send(inputs);
    }

    bool PostPaste()
    {
        var hwnd = Win32.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        return Win32.PostMessage(hwnd, Win32.WM_PASTE, IntPtr.Zero, IntPtr.Zero);
    }

    bool PasteViaKeybdEvent()
    {
        try
        {
            Win32.keybd_event((byte)Win32.VK_LCONTROL, 0, 0, UIntPtr.Zero);
            Win32.keybd_event((byte)Win32.VK_V, 0, 0, UIntPtr.Zero);
            Win32.keybd_event((byte)Win32.VK_V, 0, Win32.KEYEVENTF_KEYUP, UIntPtr.Zero);
            Win32.keybd_event((byte)Win32.VK_LCONTROL, 0, Win32.KEYEVENTF_KEYUP, UIntPtr.Zero);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static bool TypeText(string text)
    {
        var ok = true;
        foreach (var ch in text)
        {
            var down = SendInputLayout.Key(0, ch, up: false, unicode: true);
            var up = SendInputLayout.Key(0, ch, up: true, unicode: true);
            if (!Send([down, up])) ok = false;
            Thread.Sleep(8);
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
        finally
        {
            Win32.CloseClipboard();
        }
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
            if (Win32.SetClipboardData(Win32.CF_UNICODETEXT, h) == IntPtr.Zero)
                return false;
            return true;
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    static void RestoreClipboard(string? saved)
    {
        if (saved is null) return;
        // Best-effort restore; ignore failure.
        try
        {
            var tmp = new UiInserter();
            tmp.SetClipboardText(saved);
        }
        catch { /* ignore */ }
    }

    bool RetryOpenClipboard()
    {
        var owner = ClipboardOwner;
        for (var i = 0; i < 12; i++)
        {
            if (Win32.OpenClipboard(owner)) return true;
            Thread.Sleep(20);
        }
        return false;
    }
}
