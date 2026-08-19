namespace Quill;

public enum HudStateKind { Idle, Listening, Thinking, Delivered, Notice }

public sealed record HudState(HudStateKind Kind, string? Detail = null);

public enum StopReason { Hotkey, Click, Voice }

public enum InsertMethod { Accessibility, Clipboard, Blocked }

public sealed record InsertOutcome(InsertMethod Method, string? App);

public sealed record CapturedSelection(string Text, int Length);

public sealed record FrontApp(string? Name);

public interface IScheduler
{
    TimeSpan Now { get; }
    void Post(Action action);
    IDisposable Delay(TimeSpan due, Action action);
    IDisposable Interval(TimeSpan period, Action action);
}

public interface IRecorder
{
    bool IsRunning { get; }
    int FramesCaptured { get; }
    float PeakLevel { get; }
    string InputDescription { get; }
    Action<byte[]> OnPcm { get; set; }
    Action<float> OnLevel { get; set; }
    void Start();
    void Stop();
}

public interface IHud
{
    bool ShowsIdlePill { get; set; }
    void Apply(HudState state);
    void UpdateText(string text);
    void UpdateLevel(float level);
    void UpdateElapsed(TimeSpan elapsed);
    void UpdateTarget(string? name);
    void FlashTarget(string message, TimeSpan duration);
    void CollapseAfter(TimeSpan delay);
    bool ContainsPoint(double x, double y);
    void SetNeedsPermission(bool needed);
    void ResetPosition();
}

public interface IInserter
{
    bool IsTrusted { get; }
    void RequestTrust();
    void OpenMicrophoneSettings();
    void OpenAccessibilitySettings();
    FrontApp Frontmost();
    CapturedSelection? CaptureSelection();
    string? FocusedFieldValue();
    string DescribeFocus();
    void Insert(string text, bool atEnd, CapturedSelection? selection, Action<InsertOutcome> done);
}

public interface IGrokLauncher
{
    void Open(Action<GrokOutcome> done);
    void BringToFront();
}

public abstract record GrokOutcome
{
    public sealed record Opened(string Terminal) : GrokOutcome;
    public sealed record Failed(string Message) : GrokOutcome;
}

public interface IMic
{
    bool IsAuthorized { get; }
    void RequestAccess(Action<bool> done);
}

public interface IApiKeyStore
{
    bool HasKey { get; }
    string? Load();
    bool Save(string key);
    bool Remove();
    string? Redacted { get; }
}

public interface ILoginItem
{
    bool IsEnabled { get; }
    void SetEnabled(bool enabled);
}

/// <summary>A wall-clock scheduler that uses System.Threading.Timer and ThreadPool.</summary>
public sealed class ThreadScheduler : IScheduler
{
    public TimeSpan Now => TimeSpan.FromTicks(Environment.TickCount64 * TimeSpan.TicksPerMillisecond);

    public void Post(Action action) => ThreadPool.QueueUserWorkItem(_ => action());

    public IDisposable Delay(TimeSpan due, Action action)
    {
        var t = new Timer(_ => action(), null, due, Timeout.InfiniteTimeSpan);
        return t;
    }

    public IDisposable Interval(TimeSpan period, Action action)
    {
        var t = new Timer(_ => action(), null, period, period);
        return t;
    }
}
