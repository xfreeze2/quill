using System.Runtime.InteropServices;
using Quill;

namespace Quill.Win.Native;

/// <summary>
/// Low-level keyboard and mouse hooks. Bare modifier taps never shadow a
/// shortcut: a tap only counts when the key goes down and up with nothing else
/// pressed, inside 350ms. Clicks and wheel ticks while held count as a chord.
/// </summary>
sealed class HotkeyHook : IDisposable
{
    const double DoubleWindow = 0.42;
    const double TapMaxHold = 0.35;

    readonly Win32.HookProc _kbProc;
    readonly Win32.HookProc _mouseProc;
    IntPtr _kbHook;
    IntPtr _mouseHook;

    double _lastTapAt;
    double _pressedAt;
    bool _sawOtherKey;
    bool _sawMouseWhileHeld;
    bool _escapeWasDown;
    CancellationTokenSource? _cancelCts;

    public Trigger Trigger { get; set; } = Trigger.Control;
    public bool SingleTap { get; set; } = true;
    public bool WatchClicks { get; set; }

    public Action OnTrigger { get; set; } = () => { };
    public Action OnCancel { get; set; } = () => { };
    public Action<double, double> OnClickAnywhere { get; set; } = (_, _) => { };
    public Action? OnFirstEvent { get; set; }
    bool _loggedFirst;

    public HotkeyHook()
    {
        _kbProc = KeyboardProc;
        _mouseProc = MouseProc;
    }

    public bool Start()
    {
        if (_kbHook != IntPtr.Zero) return true;
        var mod = Win32.GetModuleHandle(null);
        _kbHook = Win32.SetWindowsHookEx(Win32.WH_KEYBOARD_LL, _kbProc, mod, 0);
        _mouseHook = Win32.SetWindowsHookEx(Win32.WH_MOUSE_LL, _mouseProc, mod, 0);
        return _kbHook != IntPtr.Zero;
    }

    public void Stop()
    {
        if (_kbHook != IntPtr.Zero) { Win32.UnhookWindowsHookEx(_kbHook); _kbHook = IntPtr.Zero; }
        if (_mouseHook != IntPtr.Zero) { Win32.UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
        WatchForCancel(false);
    }

    public void WatchForCancel(bool on)
    {
        _cancelCts?.Cancel();
        _cancelCts = null;
        _escapeWasDown = false;
        if (!on) return;
        // If Escape is already down at the start of a recording, ignore it until
        // it is released and pressed again (Grok Esc:cancel can be stuck).
        _escapeWasDown = (Win32.GetAsyncKeyState(Win32.VK_ESCAPE) & 0x8000) != 0;
        var cts = new CancellationTokenSource();
        _cancelCts = cts;
        _ = PollEscape(cts.Token);
    }

    async Task PollEscape(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(40, ct).ConfigureAwait(false);
                var down = (Win32.GetAsyncKeyState(Win32.VK_ESCAPE) & 0x8000) != 0;
                if (down && !_escapeWasDown)
                {
                    _escapeWasDown = true;
                    OnCancel();
                }
                else if (!down)
                {
                    _escapeWasDown = false;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // stopped
        }
    }

    bool IsTriggerKey(uint vk)
    {
        return Trigger switch
        {
            Trigger.Control => vk is Win32.VK_CONTROL or Win32.VK_LCONTROL or Win32.VK_RCONTROL,
            Trigger.RightWin => vk == Win32.VK_RWIN,
            Trigger.RightAlt => vk == Win32.VK_RMENU,
            Trigger.F5 => vk == Win32.VK_F5,
            _ => false,
        };
    }

    static bool IsModifier(uint vk) =>
        vk is Win32.VK_SHIFT or Win32.VK_LSHIFT or Win32.VK_RSHIFT
            or Win32.VK_CONTROL or Win32.VK_LCONTROL or Win32.VK_RCONTROL
            or Win32.VK_MENU or Win32.VK_LMENU or Win32.VK_RMENU
            or Win32.VK_LWIN or Win32.VK_RWIN;

    IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            if (!_loggedFirst)
            {
                _loggedFirst = true;
                OnFirstEvent?.Invoke();
            }
            var msg = wParam.ToInt32();
            var info = Marshal.PtrToStructure<Win32.KBDLLHOOKSTRUCT>(lParam);
            var vk = info.vkCode;
            var isDown = msg is Win32.WM_KEYDOWN or Win32.WM_SYSKEYDOWN;
            var isUp = msg is Win32.WM_KEYUP or Win32.WM_SYSKEYUP;

            if (vk == Win32.VK_ESCAPE && isDown && _cancelCts is not null && !_escapeWasDown)
            {
                _escapeWasDown = true;
                OnCancel();
            }

            if (Trigger == Trigger.F5 && isDown && vk == Win32.VK_F5
                && (Win32.GetAsyncKeyState(Win32.VK_CONTROL) & 0x8000) == 0
                && (Win32.GetAsyncKeyState(Win32.VK_MENU) & 0x8000) == 0
                && (Win32.GetAsyncKeyState(Win32.VK_SHIFT) & 0x8000) == 0
                && (Win32.GetAsyncKeyState(Win32.VK_LWIN) & 0x8000) == 0
                && (Win32.GetAsyncKeyState(Win32.VK_RWIN) & 0x8000) == 0)
            {
                OnTrigger();
                return (IntPtr)1; // swallow so Windows Speech Recognition does not also fire
            }

            if (isDown && !IsTriggerKey(vk))
            {
                if (_pressedAt > 0) _sawOtherKey = true;
                _lastTapAt = 0;
            }

            if (IsTriggerKey(vk) && Trigger != Trigger.F5)
            {
                var now = Now();
                if (isDown)
                {
                    if (SingleTap)
                    {
                        _pressedAt = now;
                        _sawOtherKey = false;
                        _sawMouseWhileHeld = false;
                    }
                    else if (now - _lastTapAt < DoubleWindow && !_sawOtherKey)
                    {
                        _lastTapAt = 0;
                        _sawOtherKey = false;
                        OnTrigger();
                    }
                    else
                    {
                        _lastTapAt = now;
                        _sawOtherKey = false;
                        _sawMouseWhileHeld = false;
                    }
                }
                else if (isUp && SingleTap && _pressedAt > 0)
                {
                    var held = now - _pressedAt;
                    if (!_sawOtherKey && !_sawMouseWhileHeld && held < TapMaxHold)
                        OnTrigger();
                    _pressedAt = 0;
                }
            }
        }
        return Win32.CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var msg = wParam.ToInt32();
            if (_pressedAt > 0 && msg is Win32.WM_LBUTTONDOWN or Win32.WM_MOUSEWHEEL)
                _sawMouseWhileHeld = true;

            if (WatchClicks && msg == Win32.WM_LBUTTONDOWN)
            {
                var info = Marshal.PtrToStructure<Win32.MSLLHOOKSTRUCT>(lParam);
                OnClickAnywhere(info.pt.X, info.pt.Y);
            }
        }
        return Win32.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    static double Now() => Environment.TickCount64 / 1000.0;

    public void Dispose() => Stop();
}
