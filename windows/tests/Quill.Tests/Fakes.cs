using Quill;

namespace Quill.Tests;

sealed class TestScheduler : IScheduler
{
    readonly List<Item> _items = [];
    public TimeSpan Now { get; private set; }
    public List<Action> Posted { get; } = [];

    public void Post(Action action)
    {
        Posted.Add(action);
        action();
    }

    public IDisposable Delay(TimeSpan due, Action action)
    {
        var item = new Item { When = Now + due, Action = action };
        _items.Add(item);
        return item;
    }

    public IDisposable Interval(TimeSpan period, Action action)
    {
        var item = new Item { When = Now + period, Action = action, Period = period };
        _items.Add(item);
        return item;
    }

    public void Advance(TimeSpan delta)
    {
        var target = Now + delta;
        while (true)
        {
            var next = _items.Where(i => !i.Cancelled && i.When <= target)
                .OrderBy(i => i.When)
                .FirstOrDefault();
            if (next is null) break;
            Now = next.When;
            next.Action();
            if (next.Period is { } p && !next.Cancelled)
                next.When = Now + p;
            else
                next.Cancelled = true;
        }
        Now = target;
    }

    sealed class Item : IDisposable
    {
        public TimeSpan When;
        public Action Action = () => { };
        public TimeSpan? Period;
        public bool Cancelled;
        public void Dispose() => Cancelled = true;
    }
}

sealed class FakeRecorder : IRecorder
{
    public bool IsRunning { get; private set; }
    public int FramesCaptured { get; set; }
    public float PeakLevel { get; set; } = 0.2f;
    public string InputDescription { get; set; } = "fake @ 16000Hz x1";
    public Action<byte[]> OnPcm { get; set; } = _ => { };
    public Action<float> OnLevel { get; set; } = _ => { };
    public Exception? StartThrows { get; set; }
    public void Start()
    {
        if (StartThrows is not null) throw StartThrows;
        IsRunning = true;
        FramesCaptured = 16000;
    }
    public void Stop() => IsRunning = false;
}

sealed class FakeHud : IHud
{
    public bool ShowsIdlePill { get; set; } = true;
    public List<HudState> States { get; } = [];
    public string? Text { get; private set; }
    public string? Target { get; private set; }
    public List<string> Flashes { get; } = [];
    public bool NeedsPermission { get; private set; }
    public void Apply(HudState state) => States.Add(state);
    public void UpdateText(string text) => Text = text;
    public void UpdateLevel(float level) { }
    public void UpdateElapsed(TimeSpan elapsed) { }
    public void UpdateTarget(string? name) => Target = name;
    public void FlashTarget(string message, TimeSpan duration) => Flashes.Add(message);
    public void CollapseAfter(TimeSpan delay) { }
    public bool ContainsPoint(double x, double y) => x < 40 && y < 40;
    public void SetNeedsPermission(bool needed) => NeedsPermission = needed;
    public void ResetPosition() { }
    public string? LastNotice => States.LastOrDefault(s => s.Kind == HudStateKind.Notice)?.Detail;
}

sealed class FakeInserter : IInserter
{
    public bool IsTrusted { get; set; } = true;
    public FrontApp Front { get; set; } = new("Notepad");
    public CapturedSelection? Selection { get; set; }
    public string? Field { get; set; } = "";
    public List<(string text, bool atEnd, CapturedSelection? sel)> Inserts { get; } = [];
    public void RequestTrust() { }
    public void OpenMicrophoneSettings() { }
    public void OpenAccessibilitySettings() { }
    public FrontApp Frontmost() => Front;
    public CapturedSelection? CaptureSelection() => Selection;
    public string? FocusedFieldValue() => Field;
    public string DescribeFocus() => "role=edit";
    public void NoteClick(double x, double y) { }
    public void Insert(string text, bool atEnd, CapturedSelection? selection, Action<InsertOutcome> done)
    {
        Inserts.Add((text, atEnd, selection));
        Field = (Field ?? "") + text;
        done(new InsertOutcome(InsertMethod.Accessibility, Front.Name));
    }
}

sealed class FakeGrok : IGrokLauncher
{
    public int OpenCount { get; private set; }
    public int FrontCount { get; private set; }
    public void Open(Action<GrokOutcome> done)
    {
        OpenCount++;
        done(new GrokOutcome.Opened("Windows Terminal"));
    }
    public void BringToFront() => FrontCount++;
}

sealed class FakeMic : IMic
{
    public bool IsAuthorized { get; set; } = true;
    public void RequestAccess(Action<bool> done) => done(IsAuthorized);
}

sealed class FakeKeys : IApiKeyStore
{
    public string? Key { get; set; }
    public bool HasKey => !string.IsNullOrEmpty(Key);
    public string? Load() => Key;
    public bool Save(string key) { Key = key; return true; }
    public bool Remove() { Key = null; return true; }
    public string? Redacted => Auth.Redact(Key);
}
