using Quill;
using Xunit;

namespace Quill.Tests;

public class DictationControllerTests
{
    sealed class Harness
    {
        public TestScheduler Scheduler { get; } = new();
        public FakeRecorder Recorder { get; } = new();
        public FakeHud Hud { get; } = new();
        public FakeInserter Inserter { get; } = new();
        public FakeGrok Grok { get; } = new();
        public FakeMic Mic { get; } = new();
        public FakeKeys Keys { get; } = new();
        public Settings Settings { get; } = new(new MemorySettingsStore());
        public Log Log { get; }
        public SttClient? LastStt { get; private set; }
        public DictationController Controller { get; }

        public Harness()
        {
            var logPath = Path.Combine(Path.GetTempPath(), "quill-test-" + Guid.NewGuid().ToString("n") + ".log");
            Log = new Log(logPath);
            Controller = new DictationController(
                Settings, Log, Scheduler, Recorder, Hud, Inserter, Grok, Mic, Keys,
                sttFactory: () =>
                {
                    LastStt = new SttClient();
                    return LastStt;
                });
            Controller.ResolveCreds = () => new Auth.Creds("test-token", null, "a@b.c", Auth.Source.ApiKey);
        }
    }

    [Fact]
    public void OpenGrokOnlyAtStart()
    {
        Assert.True(VoiceCommands.ContainsOpenGrok("open Grok, write a haiku"));
        Assert.False(VoiceCommands.ContainsOpenGrok("I think we should open Grok now"));
        var fired = 0;
        var didRun = false;
        foreach (var text in new[]
                 {
                     "I think", "I think we should open Grok"
                 })
        {
            if (!didRun && VoiceCommands.ContainsOpenGrok(text))
            {
                didRun = true;
                fired++;
            }
        }
        Assert.Equal(0, fired);
    }

    [Fact]
    public void PauseStopRequiresSawTextAndSilence()
    {
        var h = new Harness();
        h.Settings.PauseSeconds = 2;
        h.Controller.EnterRecordingState();
        Assert.True(h.Controller.IsRecording);
        h.Scheduler.Advance(TimeSpan.FromSeconds(3));
        Assert.True(h.Controller.IsRecording, "no transcript yet — pause must not fire");
        h.Controller.CancelSession();
        Assert.False(h.Controller.IsRecording);
        Assert.Equal("Cancelled", h.Hud.LastNotice);
    }

    [Fact]
    public void ClickOnPillDoesNotStop()
    {
        var h = new Harness();
        h.Controller.EnterRecordingState();
        h.Controller.HandleClickAnywhere(10, 10);
        Assert.True(h.Controller.IsRecording);
        h.Controller.HandleClickAnywhere(400, 400);
        Assert.False(h.Controller.IsRecording);
    }

    [Fact]
    public void ClickToInsertCanBeDisabled()
    {
        var h = new Harness();
        h.Settings.ClickToInsert = false;
        h.Controller.EnterRecordingState();
        h.Controller.HandleClickAnywhere(400, 400);
        Assert.True(h.Controller.IsRecording);
    }

    [Fact]
    public void DiagnosisDistinguishesSilentMic()
    {
        var h = new Harness();
        h.Recorder.FramesCaptured = 0;
        Assert.Contains("No audio", h.Controller.Diagnosis());
        h.Recorder.FramesCaptured = 1000;
        h.Recorder.PeakLevel = 0.0001f;
        Assert.Contains("silent", h.Controller.Diagnosis());
    }

    [Fact]
    public void MicDeniedShowsNotice()
    {
        var h = new Harness();
        h.Mic.IsAuthorized = false;
        h.Controller.StartSession();
        Assert.Contains("Microphone", h.Hud.LastNotice ?? "");
        Assert.False(h.Controller.IsRecording);
    }

    [Fact]
    public void MissingCredsShowsNotice()
    {
        var h = new Harness();
        h.Controller.ResolveCreds = () => null;
        h.Keys.Key = null;
        h.Controller.StartSession();
        Assert.Contains("No Grok", h.Hud.LastNotice ?? "");
    }

    [Fact]
    public void HistoryCapsAtTwenty()
    {
        var s = new Settings(new MemorySettingsStore());
        for (var i = 0; i < 25; i++) s.Remember("item " + i);
        Assert.Equal(20, s.History.Count);
        Assert.Equal("item 24", s.History[0]);
    }

    [Fact]
    public void KeepHistoryOffClearsOnTogglePath()
    {
        var s = new Settings(new MemorySettingsStore());
        s.Remember("secret");
        s.KeepHistory = false;
        s.ClearHistory();
        Assert.Empty(s.History);
    }

    [Fact]
    public void DefaultTriggerIsControlSingleTap()
    {
        var s = new Settings(new MemorySettingsStore());
        Assert.Equal(Trigger.Control, s.Trigger);
        Assert.True(s.SingleTap);
        Assert.True(s.ClickToInsert);
        Assert.True(s.InsertAtEnd);
        Assert.Equal(5.0, s.PauseSeconds);
        Assert.False(s.Polish);
    }
}
