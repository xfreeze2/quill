using Avalonia.Threading;
using Quill;

namespace Quill.Win;

sealed class UiScheduler : IScheduler
{
    public TimeSpan Now => TimeSpan.FromMilliseconds(Environment.TickCount64);

    public void Post(Action action) => Dispatcher.UIThread.Post(action);

    public IDisposable Delay(TimeSpan due, Action action)
    {
        var timer = new DispatcherTimer { Interval = due };
        EventHandler? handler = null;
        handler = (_, _) =>
        {
            timer.Stop();
            timer.Tick -= handler!;
            action();
        };
        timer.Tick += handler;
        timer.Start();
        return new ActionDisposable(() =>
        {
            timer.Stop();
            if (handler is not null) timer.Tick -= handler;
        });
    }

    public IDisposable Interval(TimeSpan period, Action action)
    {
        var timer = new DispatcherTimer { Interval = period };
        timer.Tick += (_, _) => action();
        timer.Start();
        return new ActionDisposable(() => timer.Stop());
    }

    sealed class ActionDisposable(Action action) : IDisposable
    {
        Action? _action = action;
        public void Dispose() { _action?.Invoke(); _action = null; }
    }
}

sealed class WindowsMic : IMic
{
    const string ConsentKey =
        @"SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public bool IsAuthorized => PrivacyAllows && DeviceExists;

    /// <summary>
    /// Windows Settings ▸ Privacy ▸ Microphone. A WinMM open "succeeds" even
    /// when access is denied there — it just records silence — so the consent
    /// store is the only honest signal. Absent keys count as allowed.
    /// </summary>
    static bool PrivacyAllows
    {
        get
        {
            var global = Native.Win32.ReadUserRegistryString(ConsentKey, "Value");
            if (string.Equals(global, "Deny", StringComparison.OrdinalIgnoreCase)) return false;
            var desktop = Native.Win32.ReadUserRegistryString(ConsentKey + @"\NonPackaged", "Value");
            if (string.Equals(desktop, "Deny", StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }
    }

    static bool DeviceExists
    {
        get
        {
            try
            {
                var fmt = new Native.Win32.WAVEFORMATEX
                {
                    wFormatTag = Native.Win32.WAVE_FORMAT_PCM,
                    nChannels = 1,
                    nSamplesPerSec = 16000,
                    wBitsPerSample = 16,
                    nBlockAlign = 2,
                    nAvgBytesPerSec = 32000,
                };
                // CALLBACK_NULL = 0, WAVE_FORMAT_QUERY = 1
                var r = Native.Win32.waveInOpenPtr(out var h, Native.Win32.WAVE_MAPPER, ref fmt, IntPtr.Zero, IntPtr.Zero, 1);
                if (r == 0 && h != IntPtr.Zero) Native.Win32.waveInClose(h);
                return r == 0;
            }
            catch
            {
                return false;
            }
        }
    }

    public void RequestAccess(Action<bool> done) => done(IsAuthorized);
}
