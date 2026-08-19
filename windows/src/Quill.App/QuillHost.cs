using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;
using Quill;
using Quill.Win.Native;

namespace Quill.Win;

sealed class QuillHost : IDisposable
{
    readonly IClassicDesktopStyleApplicationLifetime _desktop;
    readonly Settings _settings;
    readonly Log _log;
    readonly CredentialStore _keys = new();
    readonly WinLoginItem _login = new();
    readonly UiInserter _inserter = new();
    readonly WindowsMic _mic = new();
    readonly UiScheduler _scheduler = new();
    readonly WaveRecorder _recorder = new();
    readonly HotkeyHook _hotkey = new();
    readonly HudWindow _hud;
    readonly WinGrokLauncher _grok;
    readonly DictationController _session;
    TrayIcon? _tray;
    SetupWindow? _setup;
    NativeMenuItem? _startStopItem;

    public QuillHost(IClassicDesktopStyleApplicationLifetime desktop)
    {
        _desktop = desktop;
        _settings = new Settings(new JsonSettingsStore());
        _log = new Log(Log.DefaultPath);
        _hud = new HudWindow(_settings);
        _grok = new WinGrokLauncher(_log.Write);
        _session = new DictationController(
            _settings, _log, _scheduler, _recorder, _hud, _inserter, _grok, _mic, _keys)
        {
            ResolveCreds = () => Auth.Current(Auth.DefaultPath, _keys.Load()),
        };
        _session.RecordingChanged += () => Dispatcher.UIThread.Post(RefreshTray);
        _hud.OnClick = () =>
        {
            if (!_mic.IsAuthorized || Auth.Current(Auth.DefaultPath, _keys.Load()) is null)
            {
                ShowSetup();
                return;
            }
            _session.Toggle();
        };
        _hud.OnMenu = ShowTrayMenu;
        _hud.ShowsIdlePill = _settings.CornerButton;
        _inserter.Log = _log.Write;
    }

    public void Start()
    {
        _hud.Show();
        _inserter.ClipboardOwner = _hud.NativeHandle;
        _scheduler.Delay(TimeSpan.FromMilliseconds(400), () =>
            _inserter.ClipboardOwner = _hud.NativeHandle);
        _hotkey.Trigger = _settings.Trigger;
        _hotkey.SingleTap = _settings.SingleTap;
        _hotkey.OnTrigger = () => Dispatcher.UIThread.Post(() => _session.Toggle());
        _hotkey.OnCancel = () => Dispatcher.UIThread.Post(() => _session.CancelSession());
        _hotkey.OnClickAnywhere = (x, y) => Dispatcher.UIThread.Post(() =>
        {
            if (_session.DeliverToOpenedGrok) return;
            _inserter.NoteClick(x, y);
            _session.HandleClickAnywhere(x, y);
        });
        _hotkey.OnFirstEvent = () => _log.Write("event tap is LIVE — first event delivered");
        var hooked = _hotkey.Start();
        _session.RecordingChanged += () =>
        {
            _hotkey.WatchClicks = _session.IsRecording && _settings.ClickToInsert && !_session.DeliverToOpenedGrok;
            _hotkey.WatchForCancel(_session.IsRecording);
        };

        _log.Write($"launch — Quill {BuildInfo.Version} — hooked={hooked} "
            + $"trigger={TriggerInfo.Gesture(_settings.Trigger, _settings.SingleTap)}");

        BuildTray();
        _hud.SetNeedsPermission(!_mic.IsAuthorized || Auth.Current(Auth.DefaultPath, _keys.Load()) is null);

        if (_settings.NotifyUpdates)
        {
            _scheduler.Delay(TimeSpan.FromSeconds(4), () => CheckForUpdate(force: false, announce: true));
        }

        var firstRun = !_settings.DidShowSetup;
        var missing = !_mic.IsAuthorized || Auth.Current(Auth.DefaultPath, _keys.Load()) is null;
        if (firstRun || missing)
        {
            _settings.DidShowSetup = true;
            _scheduler.Delay(TimeSpan.FromMilliseconds(400), ShowSetup);
        }
    }

    void BuildTray()
    {
        _tray?.Dispose();
        var icon = LoadIcon();
        _startStopItem = new NativeMenuItem("Start dictation") { Command = new Relay(() => _session.Toggle()) };
        var menu = BuildMenu();
        _tray = new TrayIcon
        {
            ToolTipText = "Quill — tap Control to dictate",
            Icon = icon,
            Menu = menu,
            IsVisible = true,
        };
        _tray.Clicked += (_, _) => _session.Toggle();
        TrayIcon.SetIcons(App.Current!, new TrayIcons { _tray });
    }

    void ShowTrayMenu()
    {
        // Avalonia tray menus open on right-click of the icon. The pill's
        // right-click rebuilds and shows the same items via a window context menu.
        var flyout = new MenuFlyout();
        foreach (var item in LogicalMenu())
            flyout.Items.Add(item);
        flyout.ShowAt(_hud);
    }

    NativeMenu BuildMenu()
    {
        var menu = new NativeMenu();
        menu.Items.Add(new NativeMenuItem($"Quill {BuildInfo.Version}") { IsEnabled = false });

        var cached = CachedUpdate();
        if (cached is not null)
        {
            menu.Items.Add(new NativeMenuItem($"⬆︎ Update to {cached.Version} available…")
            {
                Command = new Relay(() => OpenUrl(cached.Url)),
            });
        }

        var account = Auth.Current(Auth.DefaultPath, _keys.Load());
        var header = account?.Source switch
        {
            Auth.Source.ApiKey => "xAI API key · " + (_keys.Redacted ?? "set"),
            Auth.Source.GrokBuild => "Grok Build · " + (account.Email ?? "signed in"),
            _ => "Not signed in",
        };
        menu.Items.Add(new NativeMenuItem(header) { IsEnabled = false });
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(_startStopItem!);
        menu.Items.Add(new NativeMenuItem(TriggerInfo.Gesture(_settings.Trigger, _settings.SingleTap)) { IsEnabled = false });
        menu.Items.Add(new NativeMenuItemSeparator());

        var recent = new NativeMenu();
        var history = _settings.History;
        for (var i = 0; i < Math.Min(8, history.Count); i++)
        {
            var entry = history[i];
            var title = entry.Length > 60 ? entry[..60] + "…" : entry;
            var copy = entry;
            recent.Items.Add(new NativeMenuItem(title)
            {
                Command = new Relay(() =>
                {
                    _desktop.MainWindow ??= _hud;
                    // Clipboard via inserter path is overkill; leave a toast.
                    _hud.Apply(new HudState(HudStateKind.Notice, "Copied to clipboard"));
                    _hud.CollapseAfter(TimeSpan.FromSeconds(1.2));
                    SetClipboard(copy);
                }),
            });
        }
        recent.Items.Add(new NativeMenuItemSeparator());
        recent.Items.Add(new NativeMenuItem("Clear recent") { Command = new Relay(() =>
        {
            _settings.ClearHistory();
            _log.Write("recent transcripts cleared");
            _hud.Apply(new HudState(HudStateKind.Notice, "Recent transcripts cleared"));
            _hud.CollapseAfter(TimeSpan.FromSeconds(2));
            RebuildTray();
        })});
        recent.Items.Add(Toggle("Keep recent transcripts", _settings.KeepHistory, () =>
        {
            _settings.KeepHistory = !_settings.KeepHistory;
            if (!_settings.KeepHistory) _settings.ClearHistory();
            RebuildTray();
        }));
        menu.Items.Add(new NativeMenuItem("Recent") { Menu = recent });
        menu.Items.Add(new NativeMenuItemSeparator());

        menu.Items.Add(Toggle("Click anywhere to insert", _settings.ClickToInsert, () => _settings.ClickToInsert = !_settings.ClickToInsert));
        menu.Items.Add(Toggle("Insert at end of field", _settings.InsertAtEnd, () => _settings.InsertAtEnd = !_settings.InsertAtEnd));
        menu.Items.Add(Toggle("Clean up grammar", _settings.Polish, () =>
        {
            _settings.Polish = !_settings.Polish;
            var on = _settings.Polish;
            _log.Write("grammar cleanup " + (on ? "on" : "off"));
            _hud.Apply(new HudState(HudStateKind.Notice, on
                ? "Grammar cleanup on — adds about a second, and never changes your wording"
                : "Grammar cleanup off"));
            _hud.CollapseAfter(TimeSpan.FromSeconds(3));
            RebuildTray();
        }));
        menu.Items.Add(Toggle("Stop when I say “that’s it” or “that’s all”", _settings.StopPhrase,
            () => { _settings.StopPhrase = !_settings.StopPhrase; RebuildTray(); }));

        var appearance = new NativeMenu();
        appearance.Items.Add(Toggle("Show idle pill", _settings.CornerButton, () =>
        {
            _settings.CornerButton = !_settings.CornerButton;
            _hud.ShowsIdlePill = _settings.CornerButton;
            if (!_settings.CornerButton)
            {
                _hud.Apply(new HudState(HudStateKind.Notice,
                    $"Idle pill hidden. {TriggerInfo.Gesture(_settings.Trigger, _settings.SingleTap)} still works; the tray icon brings it back."));
                _hud.CollapseAfter(TimeSpan.FromSeconds(6));
            }
            RebuildTray();
        }));
        appearance.Items.Add(new NativeMenuItem("Reset panel position")
        {
            Command = new Relay(_hud.ResetPosition),
        });
        menu.Items.Add(new NativeMenuItem("Appearance") { Menu = appearance });

        var pause = new NativeMenu();
        foreach (var (label, seconds) in new (string, double)[]
                 {
                     ("Off", 0), ("After 2 seconds", 2), ("After 3 seconds", 3),
                     ("After 5 seconds", 5), ("After 8 seconds", 8),
                 })
        {
            var s = seconds;
            pause.Items.Add(new NativeMenuItem(label)
            {
                ToggleType = NativeMenuItemToggleType.Radio,
                IsChecked = Math.Abs(_settings.PauseSeconds - s) < 0.01,
                Command = new Relay(() =>
                {
                    _settings.PauseSeconds = s;
                    _log.Write($"pause-to-finish set to {s}s");
                    _hud.Apply(new HudState(HudStateKind.Notice, s == 0
                        ? "Won't finish on its own — stop it yourself"
                        : $"Finishes after {(int)s} seconds of silence"));
                    _hud.CollapseAfter(TimeSpan.FromSeconds(2.5));
                    RebuildTray();
                }),
            });
        }
        menu.Items.Add(new NativeMenuItem("Finish when I stop talking") { Menu = pause });

        var trigger = new NativeMenu();
        foreach (var option in Enum.GetValues<Trigger>())
        {
            var o = option;
            trigger.Items.Add(new NativeMenuItem(TriggerInfo.Title(o))
            {
                ToggleType = NativeMenuItemToggleType.Radio,
                IsChecked = o == _settings.Trigger,
                Command = new Relay(() =>
                {
                    _settings.Trigger = o;
                    _hotkey.Trigger = o;
                    _log.Write("trigger set to " + TriggerInfo.WireName(o));
                    _hud.Apply(new HudState(HudStateKind.Notice,
                        "Trigger: " + TriggerInfo.Gesture(o, _settings.SingleTap)));
                    _hud.CollapseAfter(TimeSpan.FromSeconds(2.5));
                    RebuildTray();
                }),
            });
        }
        trigger.Items.Add(new NativeMenuItemSeparator());
        trigger.Items.Add(Toggle("Single tap (instead of double)", _settings.SingleTap, () =>
        {
            _settings.SingleTap = !_settings.SingleTap;
            _hotkey.SingleTap = _settings.SingleTap;
            RebuildTray();
        }));
        menu.Items.Add(new NativeMenuItem("Trigger") { Menu = trigger });

        var lang = new NativeMenu();
        var current = _settings.Language;
        var langIndex = 0;
        foreach (var (name, code) in Languages.All)
        {
            var c = code;
            lang.Items.Add(new NativeMenuItem(name)
            {
                ToggleType = NativeMenuItemToggleType.Radio,
                IsChecked = c == current,
                Command = new Relay(() => { _settings.Language = c; RebuildTray(); }),
            });
            if (langIndex == 1) lang.Items.Add(new NativeMenuItemSeparator());
            langIndex++;
        }
        menu.Items.Add(new NativeMenuItem("Language") { Menu = lang });

        menu.Items.Add(Toggle("Start at login", _login.IsEnabled, () =>
        {
            _login.SetEnabled(!_login.IsEnabled);
            RebuildTray();
        }));
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(new NativeMenuItem(_keys.HasKey ? "Change xAI API key…" : "Use my own xAI API key…")
        {
            Command = new Relay(ShowApiKey),
        });
        menu.Items.Add(Toggle("Notify about updates", _settings.NotifyUpdates,
            () => { _settings.NotifyUpdates = !_settings.NotifyUpdates; RebuildTray(); }));
        menu.Items.Add(new NativeMenuItem("Check for updates…")
        {
            Command = new Relay(() => CheckForUpdate(force: true, announce: false)),
        });
        menu.Items.Add(new NativeMenuItem(_mic.IsAuthorized && Auth.Current(Auth.DefaultPath, _keys.Load()) is not null
            ? "Setup…" : "Finish setup…")
        {
            Command = new Relay(ShowSetup),
        });
        menu.Items.Add(new NativeMenuItem("Quit Quill")
        {
            Command = new Relay(() => _desktop.Shutdown()),
        });
        return menu;
    }

    IEnumerable<Control> LogicalMenu()
    {
        // Lightweight window menu for the pill. The tray holds the full one.
        yield return new MenuItem { Header = "Start / stop dictation", Command = new Relay(() => _session.Toggle()) };
        yield return new MenuItem { Header = "Setup…", Command = new Relay(ShowSetup) };
        yield return new MenuItem { Header = "Quit Quill", Command = new Relay(() => _desktop.Shutdown()) };
    }

    static NativeMenuItem Toggle(string title, bool on, Action flip)
    {
        var item = new NativeMenuItem(title)
        {
            ToggleType = NativeMenuItemToggleType.CheckBox,
            IsChecked = on,
            Command = new Relay(flip),
        };
        return item;
    }

    void RebuildTray()
    {
        if (_tray is not null) _tray.Menu = BuildMenu();
        RefreshTray();
    }

    void RefreshTray()
    {
        if (_startStopItem is not null)
            _startStopItem.Header = _session.IsRecording ? "Stop dictation" : "Start dictation";
        if (_tray is not null)
            _tray.ToolTipText = _session.IsRecording
                ? "Quill — listening"
                : "Quill — " + TriggerInfo.Gesture(_settings.Trigger, _settings.SingleTap);
    }

    void ShowSetup()
    {
        if (_setup is { IsVisible: true })
        {
            _setup.Activate();
            _setup.Update();
            return;
        }
        _setup = new SetupWindow(_settings, _keys, _inserter, _mic, ShowApiKey);
        _setup.Closed += (_, _) => _setup = null;
        _setup.Show();
    }

    void ShowApiKey()
    {
        var w = new ApiKeyWindow(_keys, _log.Write, () =>
        {
            _hud.SetNeedsPermission(!_mic.IsAuthorized || Auth.Current(Auth.DefaultPath, _keys.Load()) is null);
            _setup?.Update();
            RebuildTray();
        });
        w.Show();
    }

    Updater.Update? CachedUpdate()
    {
        var v = _settings.Store.GetString(SettingKeys.AvailableUpdateVersion, "");
        var url = _settings.Store.GetString(SettingKeys.AvailableUpdateURL, "");
        if (string.IsNullOrEmpty(v) || string.IsNullOrEmpty(url)) return null;
        if (!Updater.IsNewer(v, BuildInfo.Version)) return null;
        return new Updater.Update(v, url);
    }

    async void CheckForUpdate(bool force, bool announce)
    {
        var last = _settings.Store.GetDouble(SettingKeys.LastUpdateCheck, 0);
        if (!force && DateTimeOffset.UtcNow.ToUnixTimeSeconds() - last < Updater.CheckInterval.TotalSeconds)
        {
            var cached = CachedUpdate();
            if (force)
            {
                _hud.Apply(new HudState(HudStateKind.Notice,
                    cached is null ? "You're on the latest version" : $"Quill {cached.Version} is available"));
                _hud.CollapseAfter(TimeSpan.FromSeconds(cached is null ? 2 : 5));
            }
            return;
        }

        try
        {
            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true })
            {
                Timeout = TimeSpan.FromSeconds(8),
            };
            var (update, error) = await Updater.CheckAsync(BuildInfo.Version, http);
            _settings.Store.SetDouble(SettingKeys.LastUpdateCheck, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            if (error is not null)
            {
                if (force)
                {
                    _hud.Apply(new HudState(HudStateKind.Notice, "Couldn't check for updates — " + error.DisplayMessage));
                    _hud.CollapseAfter(TimeSpan.FromSeconds(3));
                }
                return;
            }
            if (update is not null)
            {
                _settings.Store.SetString(SettingKeys.AvailableUpdateVersion, update.Version);
                _settings.Store.SetString(SettingKeys.AvailableUpdateURL, update.Url);
            }
            else
            {
                _settings.Store.Remove(SettingKeys.AvailableUpdateVersion);
                _settings.Store.Remove(SettingKeys.AvailableUpdateURL);
            }
            if (force)
            {
                _hud.Apply(new HudState(HudStateKind.Notice,
                    update is null ? "You're on the latest version" : $"Quill {update.Version} is available"));
                _hud.CollapseAfter(TimeSpan.FromSeconds(update is null ? 2 : 5));
            }
            if (announce && update is not null && !_session.IsRecording)
            {
                var already = _settings.Store.GetString(SettingKeys.NotifiedUpdateVersion, "");
                if (already != update.Version)
                {
                    _settings.Store.SetString(SettingKeys.NotifiedUpdateVersion, update.Version);
                    _hud.Apply(new HudState(HudStateKind.Notice, $"Quill {update.Version} is available — see the menu"));
                    _hud.CollapseAfter(TimeSpan.FromSeconds(5));
                }
            }
            RebuildTray();
        }
        catch (Exception ex)
        {
            if (force)
            {
                _hud.Apply(new HudState(HudStateKind.Notice, "Couldn't check for updates — " + ex.Message));
                _hud.CollapseAfter(TimeSpan.FromSeconds(3));
            }
        }
    }

    static void OpenUrl(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true,
            });
        }
        catch { /* ignore */ }
    }

    static void SetClipboard(string text)
    {
        try
        {
            var top = TopLevel.GetTopLevel(App.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d
                ? d.Windows.FirstOrDefault()
                : null);
            top?.Clipboard?.SetTextAsync(text);
        }
        catch { /* ignore */ }
    }

    static WindowIcon LoadIcon()
    {
        var uri = new Uri("avares://Quill/Assets/quill.ico");
        try
        {
            return new WindowIcon(Avalonia.Platform.AssetLoader.Open(uri));
        }
        catch
        {
            // Generated at build time; if missing, Avalonia accepts a 1×1 fallback below.
            var bytes = Convert.FromBase64String("AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAA");
            return new WindowIcon(new MemoryStream(bytes));
        }
    }

    public void Dispose()
    {
        _session.Dispose();
        _hotkey.Dispose();
        _recorder.Stop();
        _tray?.Dispose();
        _hud.Close();
    }
}

sealed class Relay(Action action) : System.Windows.Input.ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
}
