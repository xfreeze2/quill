namespace Quill;

/// <summary>
/// One dictation, from the trigger to the words landing.
///
/// Everything that belongs to a single recording lives here, so a new dictation
/// can begin while the previous one is still waiting for its last words without
/// the two trampling each other. That used to happen through shared fields on
/// the controller: the older session's completion cleared the client the newer
/// one was recording into, so the newer one could never be told to finish — it
/// sat on "Transcribing" until the socket timed out, and the words were lost.
/// </summary>
sealed class DictationSession
{
    public enum SessionPhase
    {
        Recording,      // microphone open, audio streaming
        Finalising,     // stopped; waiting for the transcript tail
        Delivering,     // transcript final; writing it into the target
    }

    public SessionPhase Phase = SessionPhase.Recording;
    public ISttClient Client;
    public StopReason StopReason = StopReason.Hotkey;
    public readonly CapturedSelection? Selection;
    public readonly DateTime StartedAt = DateTime.UtcNow;
    public DateTime FinaliseStartedAt;

    /// <summary>
    /// The corner panel belongs to the newest session. An older one that is
    /// still finishing inserts its words quietly rather than flashing
    /// "Inserted" over the top of a recording in progress.
    /// </summary>
    public bool OwnsHud = true;

    // Audio. Everything captured is kept for the life of the session, so the
    // socket can be handed the backlog when it opens — however long that takes —
    // and so a reconnect can replay the whole dictation from the start.
    public bool SocketReady;
    public readonly List<byte[]> Audio = [];
    public int AudioBytes;
    public int SentChunks;
    public bool DidReconnect;

    // Transcript.
    public bool SawAnyText;
    public string? LastActivityText;
    public DateTime LastVoiceAt = DateTime.UtcNow;
    public float NoiseFloor = 0.02f;
    public string? LastStopCandidate;
    public IDisposable? PendingVoiceStop;

    // Voice commands.
    public bool DidRunVoiceCommand;
    /// <summary>Once "open Grok" has launched a session, clicks are for using
    /// that session (select, copy), not for picking a Quill destination.</summary>
    public bool DeliverToOpenedGrok;

    public DictationSession(ISttClient client, CapturedSelection? selection)
    {
        Client = client;
        Selection = selection;
    }

    public bool IsRecording => Phase == SessionPhase.Recording;
}

/// <summary>
/// Session state machine, ported from the Mac app's QuillApp.
/// Platform hosts supply recorder, HUD, inserter, hotkey, and Grok launcher.
/// </summary>
public sealed class DictationController : IDisposable
{
    readonly Settings _settings;
    readonly Log _log;
    readonly IScheduler _scheduler;
    readonly IRecorder _recorder;
    readonly IHud _hud;
    readonly IInserter _inserter;
    readonly IGrokLauncher _grok;
    readonly IMic _mic;
    readonly IApiKeyStore _keys;
    readonly Func<ISttClient> _sttFactory;
    readonly string _selfTestPath;
    readonly bool _selfTestInsert;
    bool _selfTestOverlapPending;

    /// <summary>The newest dictation — recording, or finishing and still owning the panel.</summary>
    DictationSession? _session;
    /// <summary>Older dictations displaced by a newer one, kept alive until their words have landed.</summary>
    readonly List<DictationSession> _superseded = [];

    /// <summary>Five minutes of 16 kHz PCM16 — the most a recording is allowed to run.</summary>
    internal const int MaxAudioBytes = 16_000 * 2 * 320;

    IDisposable? _pauseTimer;
    IDisposable? _silenceTimer;
    IDisposable? _maxDurationTimer;
    IDisposable? _tickTimer;
    IDisposable? _selfTestTimer;

    public DictationController(
        Settings settings,
        Log log,
        IScheduler scheduler,
        IRecorder recorder,
        IHud hud,
        IInserter inserter,
        IGrokLauncher grok,
        IMic mic,
        IApiKeyStore keys,
        Func<ISttClient>? sttFactory = null,
        string? selfTestPath = null,
        bool selfTestInsert = false,
        bool selfTestOverlap = false)
    {
        _settings = settings;
        _log = log;
        _scheduler = scheduler;
        _recorder = recorder;
        _hud = hud;
        _inserter = inserter;
        _grok = grok;
        _mic = mic;
        _keys = keys;
        _sttFactory = sttFactory ?? (() => new SttClient());
        _selfTestPath = selfTestPath ?? "";
        _selfTestInsert = selfTestInsert;
        _selfTestOverlapPending = selfTestOverlap;
    }

    public bool IsRecording => _session?.IsRecording ?? false;
    /// <summary>Nothing recording, finishing, or delivering.</summary>
    public bool IsIdle => _session is null && _superseded.Count == 0;
    public bool DeliverToOpenedGrok => _session?.DeliverToOpenedGrok ?? false;
    public event Action? RecordingChanged;
    /// <summary>Fires when the last in-flight dictation has landed. Lets the self-test quit once idle.</summary>
    public event Action? BecameIdle;
    public event Action<string>? SelfTestResult;
    public event Action<string>? SelfTestMethod;
    public Func<Auth.Creds?> ResolveCreds { get; set; } = () => null;

    public void Toggle()
    {
        if (IsRecording) StopSession(StopReason.Hotkey);
        else StartSession();
    }

    public void HandleClickAnywhere(double x, double y)
    {
        var onPill = _hud.ContainsPoint(x, y);
        _log.Write($"click seen at {(int)x},{(int)y} — recording={IsRecording} onPill={onPill}");
        if (!IsRecording || !_settings.ClickToInsert) return;
        if (onPill) return;
        StopSession(StopReason.Click);
    }

    /// <summary>Escape during a recording — throw it away, insert nothing.</summary>
    public void CancelSession()
    {
        if (_session is not { IsRecording: true } session) return;
        _log.Write("cancelled by Escape");
        LeaveRecordingState(session, StopReason.Hotkey);
        session.Client.Cancel();
        Release(session);
        _hud.Apply(new HudState(HudStateKind.Notice, "Cancelled"));
        _hud.CollapseAfter(TimeSpan.FromSeconds(0.9));
    }

    public void StartSession()
    {
        if (IsRecording) return;

        // Grab the highlighted text now — clicking a destination later would
        // destroy it, and this is the only moment it is reliably present.
        var selection = _inserter.CaptureSelection();

        if (!string.IsNullOrEmpty(_selfTestPath))
        {
            BeginCapture(selection);
            return;
        }
        _mic.RequestAccess(granted =>
        {
            if (!granted)
            {
                _hud.Apply(new HudState(HudStateKind.Notice,
                    "Microphone access denied — enable Quill in Privacy ▸ Microphone"));
                _hud.CollapseAfter(TimeSpan.FromSeconds(4));
                _inserter.OpenMicrophoneSettings();
                return;
            }
            BeginCapture(selection);
        });
    }

    void BeginCapture(CapturedSelection? selection)
    {
        var creds = ResolveCreds();
        if (creds is null)
        {
            _hud.Apply(new HudState(HudStateKind.Notice,
                "No Grok Build session found — run grok once to sign in"));
            _hud.CollapseAfter(TimeSpan.FromSeconds(4));
            return;
        }

        var session = CreateSession(selection);

        // Open the connection while they are still talking: a cold request is
        // the whole difference between this feeling instant and feeling like a wait.
        if (_settings.Polish)
            _ = Polisher.WarmAsync(creds.Token);

        session.Client.Connect(creds.Token, _settings.Language);

        // Audio arrives on the capture thread. Everything that touches the
        // session happens on the scheduler thread, so the flush-on-open and the
        // live stream can never race each other over the same buffer.
        _recorder.OnPcm = data => _scheduler.Post(() =>
        {
            if (session != _session || !session.IsRecording) return;
            Capture(session, data);
        });
        _recorder.OnLevel = level => _scheduler.Post(() =>
        {
            if (session != _session || !session.IsRecording) return;
            Observe(session, level);
            _hud.UpdateLevel(level);
        });

        if (!string.IsNullOrEmpty(_selfTestPath))
        {
            StartSelfTest(session);
            return;
        }

        try
        {
            _recorder.Start();
        }
        catch (Exception ex)
        {
            session.Client.Cancel();
            Release(session);
            _hud.Apply(new HudState(HudStateKind.Notice, ex.Message));
            _hud.CollapseAfter(TimeSpan.FromSeconds(3.5));
            return;
        }

        EnterRecording(session);
    }

    /// <summary>
    /// A new session displaces the current one. The previous dictation may still
    /// be waiting for its last words: it keeps them and inserts them on its own;
    /// only the panel changes hands.
    /// </summary>
    DictationSession CreateSession(CapturedSelection? selection)
    {
        var client = _sttFactory();
        client.Log = _log.Write;
        var session = new DictationSession(client, selection);
        if (_session is { } previous)
        {
            previous.OwnsHud = false;
            previous.PendingVoiceStop?.Dispose();
            previous.PendingVoiceStop = null;
            _superseded.Add(previous);
            _log.Write("previous dictation still "
                + (previous.Phase == DictationSession.SessionPhase.Finalising ? "finalising" : "inserting")
                + " — it will land on its own");
        }
        _session = session;
        Attach(client, session);
        return session;
    }

    /// <summary>
    /// Wires a socket to its session. Every callback checks that the socket is
    /// still the one the session is using — after a reconnect the old one may
    /// still have a message in flight — before touching anything shared.
    /// </summary>
    void Attach(ISttClient client, DictationSession session)
    {
        client.OnReady = () => _scheduler.Post(() =>
        {
            if (!ReferenceEquals(session.Client, client)) return;
            session.SocketReady = true;
            // Hand over everything this socket has not seen: the backlog that
            // piled up while it was connecting, or the whole dictation after a
            // reconnect.
            var backlog = session.Audio.Count - session.SentChunks;
            var backlogBytes = 0;
            for (var i = session.SentChunks; i < session.Audio.Count; i++)
            {
                backlogBytes += session.Audio[i].Length;
                client.SendPcm(session.Audio[i]);
            }
            session.SentChunks = session.Audio.Count;
            if (backlog > 0)
                _log.Write($"  flushed {backlog} buffered chunks ({backlogBytes / 32000}s)");
            if (session.DidReconnect && session.OwnsHud && session.IsRecording)
                _hud.FlashTarget("reconnected", TimeSpan.FromSeconds(1.5));
        });
        client.OnText = text => _scheduler.Post(() =>
        {
            if (!ReferenceEquals(session.Client, client) || string.IsNullOrEmpty(text)) return;
            session.SawAnyText = true;

            if (session.IsRecording)
            {
                if (!session.DidRunVoiceCommand && VoiceCommands.ContainsOpenGrok(text))
                {
                    session.DidRunVoiceCommand = true;
                    RunOpenGrok(session);
                }
                ConsiderVoiceStop(session, text);
            }
            // Only NEW words count as activity. The server re-sends an unchanged
            // partial every couple of hundred milliseconds, so treating every
            // callback as speech kept the session alive forever.
            if (text != session.LastActivityText)
            {
                session.LastActivityText = text;
                session.LastVoiceAt = DateTime.UtcNow;
            }

            // Show what will actually be inserted, command phrases already removed.
            if (session.OwnsHud) _hud.UpdateText(VoiceCommands.StripAll(text));
        });
        client.OnComplete = text => _scheduler.Post(() =>
        {
            if (!ReferenceEquals(session.Client, client)) return;
            FinishSession(session, text);
        });
        client.OnFailure = failure => _scheduler.Post(() =>
        {
            if (!ReferenceEquals(session.Client, client)) return;
            HandleFailure(session, failure);
        });
    }

    /// <summary>One chunk of 16 kHz PCM16 from the microphone (or the self-test file).</summary>
    void Capture(DictationSession session, byte[] data)
    {
        if (session.AudioBytes >= MaxAudioBytes) return;
        session.Audio.Add(data);
        session.AudioBytes += data.Length;
        if (session.SocketReady)
        {
            session.Client.SendPcm(data);
            session.SentChunks = session.Audio.Count;
        }
    }

    /// <summary>Test seam: begin a recording session without touching mic or network.</summary>
    public void EnterRecordingState()
    {
        if (IsRecording) return;
        EnterRecording(CreateSession(_inserter.CaptureSelection()));
    }

    void EnterRecording(DictationSession session)
    {
        RecordingChanged?.Invoke();
        _hud.Apply(new HudState(HudStateKind.Listening));
        if (session.Selection is { } sel)
            _hud.FlashTarget($"replacing {sel.Length} selected characters", TimeSpan.FromSeconds(3));
        var front = _inserter.Frontmost();
        _hud.UpdateTarget(front.Name);
        StartPauseWatch(session);
        _log.Write("recording started");

        _tickTimer = _scheduler.Interval(TimeSpan.FromMilliseconds(250), () =>
        {
            if (!session.IsRecording) return;
            _hud.UpdateElapsed(DateTime.UtcNow - session.StartedAt);
            _hud.UpdateTarget(_inserter.Frontmost().Name);
        });
        ArmSilenceWatch(session);
        _maxDurationTimer = _scheduler.Delay(TimeSpan.FromMinutes(5), () =>
        {
            if (!session.IsRecording || session != _session) return;
            StopSession(StopReason.Hotkey);
        });
    }

    /// <summary>
    /// Nothing heard back after ten seconds. Which of four different failures
    /// that is matters: a dead microphone and a dead network used to be
    /// indistinguishable. If the audio side is healthy the socket gets one more
    /// chance — a fresh connection with the whole dictation replayed into it —
    /// before the session is given up on.
    /// </summary>
    void ArmSilenceWatch(DictationSession session)
    {
        _silenceTimer?.Dispose();
        _silenceTimer = _scheduler.Delay(TimeSpan.FromSeconds(10), () =>
        {
            if (!session.IsRecording || session != _session || session.SawAnyText) return;
            LogAudioState(session);
            if (MicrophoneLooksHealthy && Reconnect(session, "no transcript after 10s"))
                ArmSilenceWatch(session);
            else
                AbortSession(session, Diagnosis(session));
        });
    }

    bool MicrophoneLooksHealthy => _recorder.FramesCaptured > 0 && _recorder.PeakLevel >= 0.004f;

    /// <summary>
    /// Replace the socket without interrupting the recording. Once per session:
    /// if a second connection also fails, the problem is not transient.
    /// </summary>
    bool Reconnect(DictationSession session, string why)
    {
        if (!session.IsRecording || session.DidReconnect) return false;
        var creds = ResolveCreds();
        if (creds is null) return false;
        session.DidReconnect = true;
        _log.Write($"reconnecting speech-to-text — {why}; replaying {session.AudioBytes / 32000}s of audio");

        session.Client.Cancel();
        var client = _sttFactory();
        client.Log = _log.Write;
        session.Client = client;
        session.SocketReady = false;
        session.SentChunks = 0;
        Attach(client, session);
        client.Connect(creds.Token, _settings.Language);
        if (session.OwnsHud) _hud.FlashTarget("reconnecting…", TimeSpan.FromSeconds(4));
        return true;
    }

    void StartSelfTest(DictationSession session)
    {
        if (!File.Exists(_selfTestPath))
        {
            SelfTestResult?.Invoke($"SELFTEST: cannot read {_selfTestPath}");
            return;
        }
        var pcm = File.ReadAllBytes(_selfTestPath);
        EnterRecording(session);
        _log.Write($"SELFTEST: streaming {pcm.Length / 32000}s of audio");
        var offset = 0;
        const int chunk = 3200;
        _selfTestTimer = _scheduler.Interval(TimeSpan.FromMilliseconds(30), () =>
        {
            if (!session.IsRecording) { _selfTestTimer?.Dispose(); _selfTestTimer = null; return; }
            if (offset >= pcm.Length)
            {
                _selfTestTimer?.Dispose();
                _selfTestTimer = null;
                StopSession(StopReason.Hotkey);
                // QUILL_SELFTEST_OVERLAP: start the next dictation the instant
                // this one stops, while its transcript is still in flight — the
                // situation that used to strand both.
                if (_selfTestOverlapPending)
                {
                    _selfTestOverlapPending = false;
                    _log.Write("SELFTEST: starting a second dictation while the first finalises");
                    StartSession();
                }
                return;
            }
            var end = Math.Min(offset + chunk, pcm.Length);
            Capture(session, pcm[offset..end]);
            offset = end;
        });
    }

    /// <summary>
    /// Why did nothing come back? "No speech detected" was covering four
    /// completely different failures, which made a broken microphone and a
    /// broken network indistinguishable.
    /// </summary>
    public string Diagnosis() => Diagnosis(_session);

    string Diagnosis(DictationSession? session)
    {
        if (_recorder.FramesCaptured == 0)
            return "No audio from the microphone — check Sound ▸ Input";
        if (_recorder.PeakLevel < 0.004f)
            return "Microphone is silent — wrong input device, or muted";
        if (session is not { SocketReady: true })
            return "Couldn't reach speech-to-text — check your connection";
        return "Heard you, but no transcript came back";
    }

    void LogAudioState(DictationSession session)
    {
        _log.Write("  audio: input=" + _recorder.InputDescription
            + " frames=" + _recorder.FramesCaptured
            + " peak=" + _recorder.PeakLevel.ToString("0.0000")
            + " buffered=" + (session.AudioBytes / 32000) + "s"
            + " socketReady=" + session.SocketReady
            + " sawText=" + session.SawAnyText);
    }

    /// <summary>
    /// Opens Grok Build without interrupting the recording. Only fired when the
    /// transcript starts with the command, so the rest of that opening sentence
    /// can still become the prompt.
    /// </summary>
    void RunOpenGrok(DictationSession session)
    {
        _log.Write("voice command: open Grok");
        if (session.OwnsHud) _hud.FlashTarget("opening Grok Build…", TimeSpan.FromSeconds(8));
        _grok.Open(outcome =>
        {
            switch (outcome)
            {
                case GrokOutcome.Opened opened:
                    session.DeliverToOpenedGrok = true;
                    if (session == _session && session.IsRecording) RecordingChanged?.Invoke();
                    _log.Write("  click-to-insert off — Grok is the destination");
                    if (session.OwnsHud)
                        _hud.FlashTarget("Grok Build opened in " + opened.Terminal, TimeSpan.FromSeconds(2));
                    break;
                case GrokOutcome.Failed failed:
                    _log.Write("  open Grok failed — " + failed.Message);
                    if (session.OwnsHud)
                        _hud.FlashTarget("couldn't open Grok Build", TimeSpan.FromSeconds(4));
                    break;
            }
        });
    }

    /// <summary>
    /// Stop when "that's it" is the last thing said — but only after a beat of
    /// silence, so a mid-sentence "that's it exactly" cannot cut someone off.
    /// Any further speech cancels the pending stop.
    /// </summary>
    void ConsiderVoiceStop(DictationSession session, string text)
    {
        if (!_settings.StopPhrase || !session.IsRecording || !VoiceCommands.EndsWithStopPhrase(text))
        {
            session.PendingVoiceStop?.Dispose();
            session.PendingVoiceStop = null;
            session.LastStopCandidate = null;
            return;
        }
        // The same text arriving again is not a new stop request — the server
        // re-sends an unchanged partial every couple of hundred milliseconds.
        if (text == session.LastStopCandidate && session.PendingVoiceStop is not null) return;
        session.LastStopCandidate = text;
        session.PendingVoiceStop?.Dispose();
        session.PendingVoiceStop = _scheduler.Delay(TimeSpan.FromSeconds(0.7), () =>
        {
            if (!session.IsRecording || session != _session) return;
            _log.Write("voice stop: heard the finish phrase");
            _hud.FlashTarget("finishing…", TimeSpan.FromSeconds(2));
            StopSession(StopReason.Voice);
        });
    }

    /// <summary>
    /// Level is judged against a floor that adapts to the room, so a noisy
    /// environment does not read as constant speech and block the stop forever.
    /// </summary>
    void Observe(DictationSession session, float level)
    {
        if (level < session.NoiseFloor)
            session.NoiseFloor = session.NoiseFloor * 0.90f + level * 0.10f;   // settle downward quickly
        else
            session.NoiseFloor = session.NoiseFloor * 0.995f + level * 0.005f; // rise only slowly
        if (level > Math.Max(0.07f, session.NoiseFloor * 2.5f))
            session.LastVoiceAt = DateTime.UtcNow;
    }

    void StartPauseWatch(DictationSession session)
    {
        _pauseTimer?.Dispose();
        if (_settings.PauseSeconds <= 0) return;
        _pauseTimer = _scheduler.Interval(TimeSpan.FromMilliseconds(250), () =>
        {
            var quiet = (DateTime.UtcNow - session.LastVoiceAt).TotalSeconds;
            var window = _settings.PauseSeconds;
            if (!session.IsRecording || session != _session || !session.SawAnyText
                || window <= 0 || quiet < window) return;
            _log.Write($"pause stop: {quiet:0.0}s of silence");
            _hud.FlashTarget("finishing…", TimeSpan.FromSeconds(2));
            StopSession(StopReason.Voice);
        });
    }

    /// <summary>
    /// Microphone off, timers down, clicks and Escape no longer watched. The
    /// session moves on to waiting for its transcript.
    /// </summary>
    void LeaveRecordingState(DictationSession session, StopReason reason)
    {
        session.Phase = DictationSession.SessionPhase.Finalising;
        session.StopReason = reason;
        session.FinaliseStartedAt = DateTime.UtcNow;
        session.PendingVoiceStop?.Dispose();
        session.PendingVoiceStop = null;
        InvalidateTimers();
        _recorder.Stop();
        RecordingChanged?.Invoke();
    }

    public void StopSession(StopReason reason)
    {
        if (_session is not { IsRecording: true } session) return;
        LeaveRecordingState(session, reason);

        // Never discard the session just because no partial has arrived yet — on
        // the first recording the socket is often still connecting. Let it
        // finish and decide on the actual transcript instead.
        _log.Write($"stop ({reason.ToString().ToLowerInvariant()}) — finalising, sawText={session.SawAnyText}");
        LogAudioState(session);
        _hud.Apply(new HudState(HudStateKind.Thinking));
        session.Client.Finish();
    }

    /// <summary>
    /// The stream died. While still recording, the first failure gets a fresh
    /// socket with the audio replayed; a second one ends the recording but keeps
    /// whatever words made it through rather than throwing them away.
    /// </summary>
    void HandleFailure(DictationSession session, SttFailure failure)
    {
        var heard = session.Client.Transcript;
        _log.Write($"speech-to-text failed — {failure.Message} (phase={session.Phase}, heard {heard.Length} chars)");

        if (session.IsRecording)
        {
            if (failure.Kind != SttFailureKind.Unauthorized && Reconnect(session, failure.Message)) return;
            LeaveRecordingState(session, StopReason.Hotkey);
            if (heard.Length > 0)
            {
                if (session.OwnsHud) _hud.Apply(new HudState(HudStateKind.Thinking));
                FinishSession(session, heard);
                return;
            }
            AbortSession(session, failure.Message);
            return;
        }

        // Already stopped: the words are final as far as the user is concerned.
        if (heard.Length > 0) FinishSession(session, heard);
        else AbortSession(session, failure.Message);
    }

    void FinishSession(DictationSession session, string text)
    {
        // A socket that dies mid-dictation completes with what it has; make sure
        // the microphone and the timers are not left running behind it.
        if (session.IsRecording) LeaveRecordingState(session, StopReason.Hotkey);
        session.Phase = DictationSession.SessionPhase.Delivering;

        // The command phrase must never reach the target app.
        var trimmed = VoiceCommands.StripAll(text).Trim();
        if (trimmed.Length == 0)
        {
            Release(session);
            if (!string.IsNullOrEmpty(_selfTestPath))
                SelfTestResult?.Invoke($"<empty> — {Diagnosis(session)}");
            if (!session.OwnsHud) return;
            if (session.DidRunVoiceCommand)
            {
                _hud.Apply(new HudState(HudStateKind.Notice, "Opened Grok Build"));
                _hud.CollapseAfter(TimeSpan.FromSeconds(1.6));
            }
            else
            {
                _hud.Apply(new HudState(HudStateKind.Notice, Diagnosis(session)));
                _hud.CollapseAfter(TimeSpan.FromSeconds(4));
            }
            return;
        }

        _settings.Remember(trimmed);
        if (session.OwnsHud) _hud.UpdateText(trimmed);

        var creds = _settings.Polish ? ResolveCreds() : null;
        if (creds is null)
        {
            CompleteSession(session, trimmed);
            return;
        }

        // Show the raw words while the cleanup runs, so nothing appears to stall.
        if (session.OwnsHud)
        {
            _hud.Apply(new HudState(HudStateKind.Thinking));
            _hud.UpdateText(trimmed);
        }
        _ = Task.Run(async () =>
        {
            var result = await Polisher.PolishAsync(trimmed, creds.Token, _log.Write).ConfigureAwait(false);
            _scheduler.Post(() => CompleteSession(session, result));
        });
    }

    /// <summary>
    /// Everything after the text is final, whichever way it got there. The
    /// self-test lives on this path too — routing it around the real one is how
    /// features end up appearing to pass while untested.
    /// </summary>
    void CompleteSession(DictationSession session, string trimmed)
    {
        if (!string.IsNullOrEmpty(_selfTestPath) && !_selfTestInsert)
        {
            SelfTestResult?.Invoke(trimmed);
            if (session.OwnsHud)
            {
                _hud.Apply(new HudState(HudStateKind.Delivered));
                _hud.CollapseAfter(TimeSpan.FromSeconds(0.7));
            }
            Release(session);
            return;
        }
        Deliver(session, trimmed);
    }

    /// <summary>Put the finished text into the focused app.</summary>
    void Deliver(DictationSession session, string trimmed)
    {
        // After a click we wait a beat: the click still has to land, focus has to
        // settle, and the app has to place its caret before we write into it.
        var settle = session.StopReason == StopReason.Click ? 0.22 : 0.16;
        if (session.DeliverToOpenedGrok) _grok.BringToFront();
        _scheduler.Delay(TimeSpan.FromSeconds(settle), () =>
        {
            if (session.DeliverToOpenedGrok) _grok.BringToFront();
            _inserter.Insert(trimmed, _settings.InsertAtEnd, session.Selection, _settings.Language, outcome =>
            {
                switch (outcome.Method)
                {
                    case InsertMethod.Accessibility:
                    case InsertMethod.Clipboard:
                        _log.Write("  tail: stop → inserted in "
                            + (DateTime.UtcNow - session.FinaliseStartedAt).TotalSeconds.ToString("0.00") + "s");
                        if (session.OwnsHud)
                        {
                            _hud.Apply(new HudState(HudStateKind.Delivered, outcome.App));
                            _hud.UpdateText(trimmed);
                            _hud.CollapseAfter(TimeSpan.FromSeconds(0.7));
                        }
                        else if (IsRecording)
                        {
                            // A newer dictation is on screen; do not collapse it.
                            _hud.FlashTarget("previous dictation inserted", TimeSpan.FromSeconds(1.5));
                        }
                        if (!string.IsNullOrEmpty(_selfTestPath))
                            SelfTestMethod?.Invoke($"{outcome.Method} → {outcome.App ?? "unknown app"}");
                        break;
                    case InsertMethod.Blocked:
                        if (session.OwnsHud)
                        {
                            _hud.Apply(new HudState(HudStateKind.Notice,
                                "Grant accessibility so Quill can write into apps"));
                            _hud.CollapseAfter(TimeSpan.FromSeconds(4));
                        }
                        _inserter.RequestTrust();
                        break;
                }
                Release(session);
            });
        });
    }

    void AbortSession(DictationSession session, string message)
    {
        _log.Write("aborted — " + message);
        if (session.IsRecording) LeaveRecordingState(session, StopReason.Hotkey);
        session.Client.Cancel();
        Release(session);
        if (!string.IsNullOrEmpty(_selfTestPath))
            SelfTestResult?.Invoke($"<aborted> — {message}");
        if (!session.OwnsHud) return;
        _hud.Apply(new HudState(HudStateKind.Notice, message));
        _hud.CollapseAfter(TimeSpan.FromSeconds(4));
    }

    /// <summary>The session is over, one way or another. Forget it.</summary>
    void Release(DictationSession session)
    {
        if (_session == session) _session = null;
        _superseded.Remove(session);
        if (IsIdle) BecameIdle?.Invoke();
    }

    void InvalidateTimers()
    {
        _silenceTimer?.Dispose();
        _maxDurationTimer?.Dispose();
        _tickTimer?.Dispose();
        _selfTestTimer?.Dispose();
        _pauseTimer?.Dispose();
        _silenceTimer = null;
        _maxDurationTimer = null;
        _tickTimer = null;
        _selfTestTimer = null;
        _pauseTimer = null;
    }

    public void Dispose()
    {
        CancelSession();
        InvalidateTimers();
        _session?.Client.Cancel();
        foreach (var s in _superseded) s.Client.Cancel();
    }
}
