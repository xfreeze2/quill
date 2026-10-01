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
        public List<FakeStt> Clients { get; } = [];
        public FakeStt LastStt => Clients[^1];
        public DictationController Controller { get; }

        public Harness()
        {
            var logPath = Path.Combine(Path.GetTempPath(), "quill-test-" + Guid.NewGuid().ToString("n") + ".log");
            Log = new Log(logPath);
            Controller = new DictationController(
                Settings, Log, Scheduler, Recorder, Hud, Inserter, Grok, Mic, Keys,
                sttFactory: () =>
                {
                    var client = new FakeStt();
                    Clients.Add(client);
                    return client;
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

    // MARK: Sessions — each dictation owns its state

    [Fact]
    public void OverlappingDictationsBothLand()
    {
        // Starting a new dictation while the previous one is still waiting for
        // its last words used to clear the shared client and strand both.
        var h = new Harness();
        h.Controller.StartSession();
        var first = h.LastStt;
        first.Open();
        first.OnText("the first words");
        h.Controller.StopSession(StopReason.Hotkey);
        Assert.Equal(1, first.FinishCalls);
        Assert.False(h.Controller.IsRecording);

        h.Controller.StartSession();                 // overlap: recording again while #1 finalises
        var second = h.LastStt;
        Assert.NotSame(first, second);
        Assert.True(h.Controller.IsRecording);

        first.OnComplete("the first words");         // the late tail arrives
        h.Scheduler.Advance(TimeSpan.FromSeconds(1));
        Assert.Contains(h.Inserter.Inserts, i => i.text == "the first words");
        Assert.True(h.Controller.IsRecording, "the first dictation landing must not kill the live recording");
        Assert.Contains("previous dictation inserted", h.Hud.Flashes);

        h.Controller.StopSession(StopReason.Hotkey);
        second.OnComplete("the second words");
        h.Scheduler.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(2, h.Inserter.Inserts.Count);
        Assert.Equal("the second words", h.Inserter.Inserts[1].text);
        Assert.True(h.Controller.IsIdle);
    }

    [Fact]
    public void AudioBufferedBeforeOpenIsFlushedInOrder()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.Recorder.OnPcm([1]);
        h.Recorder.OnPcm([2]);
        Assert.Empty(h.LastStt.Sent);                // socket not open yet — held
        h.LastStt.Open();
        Assert.Equal([[1], [2]], h.LastStt.Sent.ToArray());
        h.Recorder.OnPcm([3]);
        Assert.Equal(3, h.LastStt.Sent.Count);       // live from here on
    }

    [Fact]
    public void AudioIsCappedAtFiveMinutes()
    {
        var h = new Harness();
        h.Controller.StartSession();
        var tenSeconds = new byte[320_000];
        for (var i = 0; i < 40; i++) h.Recorder.OnPcm(tenSeconds);   // 400s offered
        h.LastStt.Open();
        Assert.Equal(DictationController.MaxAudioBytes / 320_000, h.LastStt.Sent.Count);
    }

    [Fact]
    public void StreamDeathMidRecordingReconnectsAndReplays()
    {
        var h = new Harness();
        h.Controller.StartSession();
        var first = h.LastStt;
        first.Open();
        h.Recorder.OnPcm(new byte[3200]);
        h.Recorder.OnPcm(new byte[3200]);
        Assert.Equal(2, first.Sent.Count);

        first.OnFailure(new SttFailure(SttFailureKind.Offline, "Lost the connection to speech-to-text"));
        Assert.True(h.Controller.IsRecording, "the first failure must not end the recording");
        Assert.Equal(2, h.Clients.Count);
        Assert.Equal(1, first.CancelCalls);
        Assert.Contains("reconnecting…", h.Hud.Flashes);

        var second = h.LastStt;
        Assert.NotNull(second.Connected);
        second.Open();
        Assert.Equal(2, second.Sent.Count);          // the whole dictation replayed
        Assert.Contains("reconnected", h.Hud.Flashes);

        h.Recorder.OnPcm(new byte[3200]);
        Assert.Equal(3, second.Sent.Count);          // and the live stream continues
    }

    [Fact]
    public void SecondFailureKeepsWhatWasHeard()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.LastStt.Open();
        h.LastStt.OnFailure(new SttFailure(SttFailureKind.Offline, "Lost the connection to speech-to-text"));
        var second = h.LastStt;
        second.Open();
        second.OnText("keep these words");
        second.Transcript = "keep these words";
        second.OnFailure(new SttFailure(SttFailureKind.Offline, "Lost the connection to speech-to-text"));

        Assert.False(h.Controller.IsRecording);
        h.Scheduler.Advance(TimeSpan.FromSeconds(1));
        Assert.Contains(h.Inserter.Inserts, i => i.text == "keep these words");
        Assert.True(h.Controller.IsIdle);
    }

    [Fact]
    public void SecondFailureWithNothingHeardExplainsItself()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.LastStt.Open();
        h.LastStt.OnFailure(new SttFailure(SttFailureKind.Offline, "Lost the connection to speech-to-text"));
        h.LastStt.OnFailure(new SttFailure(SttFailureKind.Offline, "Lost the connection to speech-to-text"));
        Assert.False(h.Controller.IsRecording);
        Assert.Equal("Lost the connection to speech-to-text", h.Hud.LastNotice);
        Assert.True(h.Controller.IsIdle);
    }

    [Fact]
    public void AnExpiredSessionNeverReconnects()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.LastStt.Open();
        h.LastStt.OnFailure(new SttFailure(SttFailureKind.Unauthorized,
            "Grok session expired — open Grok Build once to refresh"));
        Assert.False(h.Controller.IsRecording);
        Assert.Single(h.Clients);                    // no second socket for a bad token
        Assert.Contains("expired", h.Hud.LastNotice ?? "");
    }

    [Fact]
    public void FailureAfterStopStillDeliversTheWords()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.LastStt.Open();
        h.LastStt.OnText("half a sentence");
        h.Controller.StopSession(StopReason.Hotkey);
        h.LastStt.Transcript = "half a sentence";
        h.LastStt.OnFailure(new SttFailure(SttFailureKind.Server, "Speech-to-text closed the connection (code 1006)"));
        h.Scheduler.Advance(TimeSpan.FromSeconds(1));
        Assert.Contains(h.Inserter.Inserts, i => i.text == "half a sentence");
    }

    [Fact]
    public void ALateMessageFromAReplacedSocketIsIgnored()
    {
        var h = new Harness();
        h.Controller.StartSession();
        var first = h.LastStt;
        first.Open();
        first.OnFailure(new SttFailure(SttFailureKind.Offline, "Lost the connection to speech-to-text"));
        first.OnComplete("ghost words");             // late message from the dead socket
        Assert.True(h.Controller.IsRecording);
        Assert.Empty(h.Inserter.Inserts);
    }

    [Fact]
    public void TenSecondsOfNothingGetsOneFreshSocketThenGivesUp()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.LastStt.Open();
        h.Scheduler.Advance(TimeSpan.FromSeconds(10.5));
        Assert.Equal(2, h.Clients.Count);            // healthy mic, silent server → retry
        Assert.True(h.Controller.IsRecording);
        h.Scheduler.Advance(TimeSpan.FromSeconds(10.5));
        Assert.False(h.Controller.IsRecording);      // still nothing → give up, say why
        Assert.Contains("speech-to-text", h.Hud.LastNotice ?? "", StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ADeadMicrophoneIsNotWorthAReconnect()
    {
        var h = new Harness();
        h.Controller.StartSession();
        h.Recorder.FramesCaptured = 0;
        h.LastStt.Open();
        h.Scheduler.Advance(TimeSpan.FromSeconds(10.5));
        Assert.Single(h.Clients);
        Assert.False(h.Controller.IsRecording);
        Assert.Contains("No audio", h.Hud.LastNotice ?? "");
    }

    [Fact]
    public void EscapeCancelsOnlyTheLiveDictation()
    {
        var h = new Harness();
        h.Controller.StartSession();
        var first = h.LastStt;
        h.Controller.StopSession(StopReason.Hotkey);
        h.Controller.StartSession();
        var second = h.LastStt;
        h.Controller.CancelSession();
        Assert.Equal(1, second.CancelCalls);
        Assert.Equal(0, first.CancelCalls);

        first.OnComplete("still lands");
        h.Scheduler.Advance(TimeSpan.FromSeconds(1));
        Assert.Contains(h.Inserter.Inserts, i => i.text == "still lands");
        Assert.True(h.Controller.IsIdle);
    }

    [Fact]
    public void LanguageReachesTheSocketAndTheInserter()
    {
        var h = new Harness();
        h.Settings.Language = "de";
        h.Controller.StartSession();
        Assert.Equal("de", h.LastStt.Connected?.Language);
        h.Controller.StopSession(StopReason.Hotkey);
        h.LastStt.OnComplete("Guten Tag");
        h.Scheduler.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal("de", h.Inserter.Inserts[0].language);
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
