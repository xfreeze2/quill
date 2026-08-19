namespace Quill;

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
    readonly Func<SttClient> _sttFactory;
    readonly string _selfTestPath;
    readonly bool _selfTestInsert;

    SttClient? _stt;
    readonly List<byte[]> _pendingPcm = [];
    bool _socketReady;
    bool _sawAnyText;
    StopReason _stopReason = StopReason.Hotkey;
    bool _didRunVoiceCommand;
    bool _deliverToOpenedGrok;
    DateTime _finaliseStartedAt;
    IDisposable? _pendingVoiceStop;
    string? _lastStopCandidate;
    IDisposable? _pauseTimer;
    DateTime _lastVoiceAt = DateTime.UtcNow;
    string? _lastActivityText;
    float _noiseFloor = 0.02f;
    CapturedSelection? _capturedSelection;
    DateTime _startedAt;
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
        Func<SttClient>? sttFactory = null,
        string? selfTestPath = null,
        bool selfTestInsert = false)
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
    }

    public bool IsRecording { get; private set; }
    public event Action? RecordingChanged;
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

    public void CancelSession()
    {
        if (!IsRecording) return;
        _log.Write("cancelled by Escape");
        IsRecording = false;
        RecordingChanged?.Invoke();
        _pendingVoiceStop?.Dispose();
        _pendingVoiceStop = null;
        _pauseTimer?.Dispose();
        _pauseTimer = null;
        InvalidateTimers();
        _recorder.Stop();
        _stt?.Cancel();
        _stt = null;
        _hud.Apply(new HudState(HudStateKind.Notice, "Cancelled"));
        _hud.CollapseAfter(TimeSpan.FromSeconds(0.9));
    }

    public void StartSession()
    {
        if (IsRecording) return;
        _capturedSelection = _inserter.CaptureSelection();
        if (!string.IsNullOrEmpty(_selfTestPath))
        {
            BeginCapture();
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
            BeginCapture();
        });
    }

    void BeginCapture()
    {
        var creds = ResolveCreds();
        if (creds is null)
        {
            _hud.Apply(new HudState(HudStateKind.Notice,
                "No Grok Build session found — run grok once to sign in"));
            _hud.CollapseAfter(TimeSpan.FromSeconds(4));
            return;
        }

        var client = _sttFactory();
        _stt = client;
        _pendingPcm.Clear();
        _socketReady = false;
        _sawAnyText = false;
        _stopReason = StopReason.Hotkey;
        _didRunVoiceCommand = false;
        _deliverToOpenedGrok = false;
        _lastStopCandidate = null;
        client.Log = _log.Write;

        client.OnReady = () =>
        {
            _socketReady = true;
            foreach (var chunk in _pendingPcm) client.SendPcm(chunk);
            _pendingPcm.Clear();
        };
        client.OnText = text =>
        {
            if (string.IsNullOrEmpty(text)) return;
            _sawAnyText = true;
            if (!_didRunVoiceCommand && VoiceCommands.ContainsOpenGrok(text))
            {
                _didRunVoiceCommand = true;
                RunOpenGrok();
            }
            ConsiderVoiceStop(text);
            if (text != _lastActivityText)
            {
                _lastActivityText = text;
                NoteVoiceActivity();
            }
            _hud.UpdateText(VoiceCommands.StripAll(text));
        };
        client.OnComplete = text => FinishSession(text);
        client.OnFailure = failure => AbortSession(failure.Message);

        if (_settings.Polish)
            _ = Polisher.WarmAsync(creds.Token);

        _ = client.ConnectAsync(creds.Token, _settings.Language);

        _recorder.OnPcm = data =>
        {
            if (_socketReady) client.SendPcm(data);
            else if (_pendingPcm.Count < 200) _pendingPcm.Add(data);
        };
        _recorder.OnLevel = level =>
        {
            _scheduler.Post(() =>
            {
                Observe(level);
                _hud.UpdateLevel(level);
            });
        };

        if (!string.IsNullOrEmpty(_selfTestPath))
        {
            StartSelfTest(client);
            return;
        }

        try
        {
            _recorder.Start();
        }
        catch (Exception ex)
        {
            _stt?.Cancel();
            _stt = null;
            _hud.Apply(new HudState(HudStateKind.Notice, ex.Message));
            _hud.CollapseAfter(TimeSpan.FromSeconds(3.5));
            return;
        }

        EnterRecordingState();
    }

    public void EnterRecordingState()
    {
        IsRecording = true;
        _startedAt = DateTime.UtcNow;
        RecordingChanged?.Invoke();
        _hud.Apply(new HudState(HudStateKind.Listening));
        if (_capturedSelection is { } sel)
            _hud.FlashTarget($"replacing {sel.Length} selected characters", TimeSpan.FromSeconds(3));
        var front = _inserter.Frontmost();
        _hud.UpdateTarget(front.Name);
        _lastVoiceAt = DateTime.UtcNow;
        _lastActivityText = null;
        _noiseFloor = 0.02f;
        StartPauseWatch();
        _log.Write("recording started");

        _tickTimer = _scheduler.Interval(TimeSpan.FromMilliseconds(250), () =>
        {
            if (!IsRecording) return;
            _hud.UpdateElapsed(DateTime.UtcNow - _startedAt);
            _hud.UpdateTarget(_inserter.Frontmost().Name);
        });
        _silenceTimer = _scheduler.Delay(TimeSpan.FromSeconds(10), () =>
        {
            if (!IsRecording || _sawAnyText) return;
            LogAudioState();
            AbortSession(Diagnosis());
        });
        _maxDurationTimer = _scheduler.Delay(TimeSpan.FromMinutes(5), () =>
        {
            if (!IsRecording) return;
            StopSession(StopReason.Hotkey);
        });
    }

    void StartSelfTest(SttClient client)
    {
        if (!File.Exists(_selfTestPath))
        {
            SelfTestResult?.Invoke($"SELFTEST: cannot read {_selfTestPath}");
            return;
        }
        var pcm = File.ReadAllBytes(_selfTestPath);
        EnterRecordingState();
        _log.Write($"SELFTEST: streaming {pcm.Length / 32000}s of audio");
        var offset = 0;
        const int chunk = 3200;
        _selfTestTimer = _scheduler.Interval(TimeSpan.FromMilliseconds(30), () =>
        {
            if (offset >= pcm.Length)
            {
                _selfTestTimer?.Dispose();
                _selfTestTimer = null;
                StopSession(StopReason.Hotkey);
                return;
            }
            var end = Math.Min(offset + chunk, pcm.Length);
            var slice = pcm[offset..end];
            if (_socketReady) client.SendPcm(slice);
            else _pendingPcm.Add(slice);
            offset = end;
        });
    }

    public string Diagnosis()
    {
        if (_recorder.FramesCaptured == 0)
            return "No audio from the microphone — check Sound ▸ Input";
        if (_recorder.PeakLevel < 0.004f)
            return "Microphone is silent — wrong input device, or muted";
        if (!_socketReady)
            return "Couldn't reach speech-to-text — check your connection";
        return "Heard you, but no transcript came back";
    }

    void LogAudioState()
    {
        _log.Write("  audio: input=" + _recorder.InputDescription
            + " frames=" + _recorder.FramesCaptured
            + " peak=" + _recorder.PeakLevel.ToString("0.0000")
            + " socketReady=" + _socketReady
            + " sawText=" + _sawAnyText);
    }

    void RunOpenGrok()
    {
        _log.Write("voice command: open Grok");
        _hud.FlashTarget("opening Grok Build…", TimeSpan.FromSeconds(8));
        _grok.Open(outcome =>
        {
            switch (outcome)
            {
                case GrokOutcome.Opened opened:
                    _deliverToOpenedGrok = true;
                    _log.Write("  click-to-insert off — Grok is the destination");
                    _hud.FlashTarget("Grok Build opened in " + opened.Terminal, TimeSpan.FromSeconds(2));
                    break;
                case GrokOutcome.Failed failed:
                    _log.Write("  open Grok failed — " + failed.Message);
                    _hud.FlashTarget("couldn't open Grok Build", TimeSpan.FromSeconds(4));
                    break;
            }
        });
    }

    public bool DeliverToOpenedGrok => _deliverToOpenedGrok;

    void ConsiderVoiceStop(string text)
    {
        if (!_settings.StopPhrase || !IsRecording || !VoiceCommands.EndsWithStopPhrase(text))
        {
            _pendingVoiceStop?.Dispose();
            _pendingVoiceStop = null;
            _lastStopCandidate = null;
            return;
        }
        if (text == _lastStopCandidate && _pendingVoiceStop is not null) return;
        _lastStopCandidate = text;
        _pendingVoiceStop?.Dispose();
        _pendingVoiceStop = _scheduler.Delay(TimeSpan.FromSeconds(0.7), () =>
        {
            if (!IsRecording) return;
            _log.Write("voice stop: heard the finish phrase");
            _hud.FlashTarget("finishing…", TimeSpan.FromSeconds(2));
            StopSession(StopReason.Voice);
        });
    }

    void NoteVoiceActivity() => _lastVoiceAt = DateTime.UtcNow;

    void Observe(float level)
    {
        if (level < _noiseFloor)
            _noiseFloor = _noiseFloor * 0.90f + level * 0.10f;
        else
            _noiseFloor = _noiseFloor * 0.995f + level * 0.005f;
        if (level > Math.Max(0.07f, _noiseFloor * 2.5f)) NoteVoiceActivity();
    }

    void StartPauseWatch()
    {
        _pauseTimer?.Dispose();
        if (_settings.PauseSeconds <= 0) return;
        _pauseTimer = _scheduler.Interval(TimeSpan.FromMilliseconds(250), () =>
        {
            var quiet = (DateTime.UtcNow - _lastVoiceAt).TotalSeconds;
            var window = _settings.PauseSeconds;
            if (!IsRecording || !_sawAnyText || window <= 0 || quiet < window) return;
            _log.Write($"pause stop: {quiet:0.0}s of silence");
            _hud.FlashTarget("finishing…", TimeSpan.FromSeconds(2));
            StopSession(StopReason.Voice);
        });
    }

    public void StopSession(StopReason reason)
    {
        if (!IsRecording) return;
        IsRecording = false;
        _stopReason = reason;
        RecordingChanged?.Invoke();
        _pendingVoiceStop?.Dispose();
        _pendingVoiceStop = null;
        _pauseTimer?.Dispose();
        _pauseTimer = null;
        InvalidateTimers();
        _recorder.Stop();
        _log.Write($"stop ({reason.ToString().ToLowerInvariant()}) — finalising, sawText={_sawAnyText}");
        _finaliseStartedAt = DateTime.UtcNow;
        LogAudioState();
        _hud.Apply(new HudState(HudStateKind.Thinking));
        _stt?.Finish();
    }

    void FinishSession(string text)
    {
        _stt = null;
        var trimmed = VoiceCommands.StripAll(text).Trim();
        if (trimmed.Length == 0)
        {
            if (_didRunVoiceCommand)
            {
                _hud.Apply(new HudState(HudStateKind.Notice, "Opened Grok Build"));
                _hud.CollapseAfter(TimeSpan.FromSeconds(1.6));
            }
            else
            {
                _hud.Apply(new HudState(HudStateKind.Notice, Diagnosis()));
                _hud.CollapseAfter(TimeSpan.FromSeconds(4));
            }
            return;
        }

        _settings.Remember(trimmed);
        _hud.UpdateText(trimmed);

        if (!_settings.Polish)
        {
            CompleteSession(trimmed);
            return;
        }

        var creds = ResolveCreds();
        if (creds is null)
        {
            CompleteSession(trimmed);
            return;
        }

        _hud.Apply(new HudState(HudStateKind.Thinking));
        _hud.UpdateText(trimmed);
        _ = Task.Run(async () =>
        {
            var result = await Polisher.PolishAsync(trimmed, creds.Token, _log.Write).ConfigureAwait(false);
            _scheduler.Post(() => CompleteSession(result));
        });
    }

    void CompleteSession(string trimmed)
    {
        if (!string.IsNullOrEmpty(_selfTestPath) && !_selfTestInsert)
        {
            SelfTestResult?.Invoke(trimmed);
            _hud.Apply(new HudState(HudStateKind.Delivered));
            _hud.CollapseAfter(TimeSpan.FromSeconds(0.7));
            return;
        }
        Deliver(trimmed);
    }

    void Deliver(string trimmed)
    {
        var settle = _stopReason == StopReason.Click ? 0.22 : 0.16;
        if (_deliverToOpenedGrok) _grok.BringToFront();
        _scheduler.Delay(TimeSpan.FromSeconds(settle), () =>
        {
            if (_deliverToOpenedGrok) _grok.BringToFront();
            var selection = _capturedSelection;
            _capturedSelection = null;
            _inserter.Insert(trimmed, _settings.InsertAtEnd, selection, outcome =>
            {
                switch (outcome.Method)
                {
                    case InsertMethod.Accessibility:
                    case InsertMethod.Clipboard:
                        _log.Write("  tail: stop → inserted in "
                            + (DateTime.UtcNow - _finaliseStartedAt).TotalSeconds.ToString("0.00") + "s");
                        _hud.Apply(new HudState(HudStateKind.Delivered, outcome.App));
                        _hud.UpdateText(trimmed);
                        _hud.CollapseAfter(TimeSpan.FromSeconds(0.7));
                        if (!string.IsNullOrEmpty(_selfTestPath))
                            SelfTestMethod?.Invoke($"{outcome.Method} → {outcome.App ?? "unknown app"}");
                        break;
                    case InsertMethod.Blocked:
                        _hud.Apply(new HudState(HudStateKind.Notice,
                            "Grant accessibility so Quill can write into apps"));
                        _hud.CollapseAfter(TimeSpan.FromSeconds(4));
                        _inserter.RequestTrust();
                        break;
                }
            });
        });
    }

    void AbortSession(string message)
    {
        _log.Write("aborted — " + message);
        IsRecording = false;
        RecordingChanged?.Invoke();
        _pendingVoiceStop?.Dispose();
        _pendingVoiceStop = null;
        _pauseTimer?.Dispose();
        _pauseTimer = null;
        InvalidateTimers();
        _recorder.Stop();
        _stt?.Cancel();
        _stt = null;
        _hud.Apply(new HudState(HudStateKind.Notice, message));
        _hud.CollapseAfter(TimeSpan.FromSeconds(4));
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
        _stt?.Cancel();
    }
}
