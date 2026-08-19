using System.Runtime.InteropServices;
using System.Text;
using Quill;

namespace Quill.Win.Native;

sealed class UiInserter : IInserter
{
    public bool IsTrusted => true;

    public void RequestTrust() { }

    public void OpenMicrophoneSettings() =>
        Win32.ShellExecute(IntPtr.Zero, "open", "ms-settings:privacy-microphone", null, null, 1);

    public void OpenAccessibilitySettings() =>
        Win32.ShellExecute(IntPtr.Zero, "open", "ms-settings:easeofaccess-keyboard", null, null, 1);

    public FrontApp Frontmost() => new(Win32.ForegroundTitle());

    public CapturedSelection? CaptureSelection()
    {
        // Best-effort: copy via Ctrl+C would steal the clipboard. We only treat
        // a non-empty UIA value-selection as a replacement target when we can
        // read it without side effects. Most Windows apps expose the whole
        // value, not the highlight, so this often returns null — same as Mac
        // when AXSelectedText is empty.
        return null;
    }

    public string? FocusedFieldValue()
    {
        if (Win32.UiaGetFocusedElement(out var node) != 0 || node == IntPtr.Zero) return null;
        try
        {
            if (Win32.UiaGetPropertyValue(node, Win32.UIA_ValueValuePropertyId, out var value) == 0)
                return value as string;
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
            return $"name={name ?? "—"} valueReadable={value is string}";
        }
        finally
        {
            Win32.UiaNodeRelease(node);
        }
    }

    public void Insert(string text, bool atEnd, CapturedSelection? selection, Action<InsertOutcome> done)
    {
        var app = Frontmost().Name;
        var payload = text;
        var existing = FocusedFieldValue();
        var offset = atEnd ? existing?.Length : existing?.Length;
        if (atEnd && existing is not null) offset = existing.Length;
        payload = Spacing.Apply(payload, existing, offset);

        if (TrySetValue(existing, payload, atEnd) && ConfirmLanded(payload))
        {
            done(new InsertOutcome(InsertMethod.Accessibility, app));
            return;
        }

        InsertViaClipboard(payload, atEnd, () => done(new InsertOutcome(InsertMethod.Clipboard, app)));
    }

    bool TrySetValue(string? existing, string payload, bool atEnd)
    {
        if (Win32.UiaGetFocusedElement(out var node) != 0 || node == IntPtr.Zero) return false;
        try
        {
            if (Win32.UiaGetPatternProvider(node, Win32.UIA_ValuePatternId, out var unk) != 0 || unk is null)
                return false;
            if (unk is not IValueProvider provider) return false;
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

    bool ConfirmLanded(string payload)
    {
        var readback = FocusedFieldValue();
        if (readback is null) return true;
        var needle = payload.Trim();
        if (needle.Length == 0) return true;
        var tail = needle.Length <= 24 ? needle : needle[^24..];
        return readback.Contains(tail, StringComparison.Ordinal);
    }

    void InsertViaClipboard(string text, bool atEnd, Action completion)
    {
        var saved = SnapshotClipboard();
        if (!SetClipboardText(text))
        {
            completion();
            return;
        }

        _ = Task.Run(async () =>
        {
            await Task.Delay(60).ConfigureAwait(false);
            if (atEnd) Chord(Win32.VK_CONTROL, Win32.VK_END);
            Chord(Win32.VK_CONTROL, Win32.VK_V);
            completion();
            await Task.Delay(450).ConfigureAwait(false);
            RestoreClipboard(saved);
        });
    }

    static string? SnapshotClipboard()
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

    static bool SetClipboardText(string text)
    {
        if (!RetryOpenClipboard()) return false;
        try
        {
            Win32.EmptyClipboard();
            var bytes = (text.Length + 1) * 2;
            var h = Win32.GlobalAlloc(Win32.GMEM_MOVEABLE, (UIntPtr)bytes);
            if (h == IntPtr.Zero) return false;
            var p = Win32.GlobalLock(h);
            Marshal.Copy(Encoding.Unicode.GetBytes(text + "\0"), 0, p, bytes);
            Win32.GlobalUnlock(h);
            return Win32.SetClipboardData(Win32.CF_UNICODETEXT, h) != IntPtr.Zero;
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    static void RestoreClipboard(string? saved)
    {
        if (saved is null) return;
        SetClipboardText(saved);
    }

    static bool RetryOpenClipboard()
    {
        for (var i = 0; i < 8; i++)
        {
            if (Win32.OpenClipboard(IntPtr.Zero)) return true;
            Thread.Sleep(15);
        }
        return false;
    }

    static void Chord(ushort modifier, ushort key)
    {
        var inputs = new Win32.INPUT[]
        {
            Key(modifier, false),
            Key(key, false),
            Key(key, true),
            Key(modifier, true),
        };
        Win32.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Win32.INPUT>());
    }

    static Win32.INPUT Key(ushort vk, bool up) => new()
    {
        type = Win32.INPUT_KEYBOARD,
        U = new Win32.InputUnion
        {
            ki = new Win32.KEYBDINPUT
            {
                wVk = vk,
                dwFlags = up ? Win32.KEYEVENTF_KEYUP : 0,
            },
        },
    };

    public static void TypeText(string text)
    {
        foreach (var ch in text)
        {
            var down = Unicode(ch, false);
            var up = Unicode(ch, true);
            Win32.SendInput(1, [down], Marshal.SizeOf<Win32.INPUT>());
            Win32.SendInput(1, [up], Marshal.SizeOf<Win32.INPUT>());
            Thread.Sleep(12);
        }
    }

    public static void PressReturn()
    {
        var inputs = new Win32.INPUT[] { Key(Win32.VK_RETURN, false), Key(Win32.VK_RETURN, true) };
        Win32.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Win32.INPUT>());
    }

    static Win32.INPUT Unicode(char ch, bool up) => new()
    {
        type = Win32.INPUT_KEYBOARD,
        U = new Win32.InputUnion
        {
            ki = new Win32.KEYBDINPUT
            {
                wVk = 0,
                wScan = ch,
                dwFlags = Win32.KEYEVENTF_UNICODE | (up ? Win32.KEYEVENTF_KEYUP : 0),
            },
        },
    };
}
