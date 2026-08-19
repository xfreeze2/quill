using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Quill;
using Quill.Win.Native;

namespace Quill.Win;

sealed class SetupWindow : Window
{
    readonly Settings _settings;
    readonly IApiKeyStore _keys;
    readonly IInserter _inserter;
    readonly IMic _mic;
    readonly Action _onUseKey;
    readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly TextBlock _footer = new() { FontSize = 12, Foreground = new SolidColorBrush(Color.FromRgb(160, 160, 160)), TextWrapping = TextWrapping.Wrap };
    readonly List<Row> _rows = [];
    WaveRecorder? _monitor;

    public SetupWindow(Settings settings, IApiKeyStore keys, IInserter inserter, IMic mic, Action onUseKey)
    {
        _settings = settings;
        _keys = keys;
        _inserter = inserter;
        _mic = mic;
        _onUseKey = onUseKey;

        Title = "Set up Quill";
        Width = 480;
        Height = 430;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(22, 22, 22));
        Foreground = Brushes.White;

        var title = new TextBlock { Text = "Quill", FontSize = 24, FontWeight = FontWeight.SemiBold };
        var subtitle = new TextBlock
        {
            Text = $"Speak anywhere. The text lands where you point.  ·  v{BuildInfo.Version}",
            FontSize = 13,
            Foreground = new SolidColorBrush(Color.FromRgb(160, 160, 160)),
            Margin = new Thickness(0, 4, 0, 26),
        };

        var stack = new StackPanel { Spacing = 18 };
        stack.Children.Add(MakeRow("Microphone", "So Quill can hear you.", "Allow", OnMic));
        stack.Children.Add(MakeRow("Type into apps", "So the trigger key works, and so Quill can type into other apps.", null, null));
        stack.Children.Add(MakeRow("Grok sign-in or API key", "Sign in to the grok command-line tool once, or use your own xAI API key.", "Use a key", OnKey));

        var root = new DockPanel { Margin = new Thickness(28, 26, 28, 24) };
        DockPanel.SetDock(_footer, Dock.Bottom);
        var header = new StackPanel { Children = { title, subtitle, stack } };
        root.Children.Add(_footer);
        root.Children.Add(header);
        Content = root;

        _refresh.Tick += (_, _) => Update();
        Opened += (_, _) => { Update(); _refresh.Start(); };
        Closed += (_, _) =>
        {
            _refresh.Stop();
            _monitor?.Stop();
            _monitor = null;
        };
    }

    Control MakeRow(string title, string detail, string? action, EventHandler<Avalonia.Interactivity.RoutedEventArgs>? click)
    {
        var row = new Row(title, detail, action, click);
        _rows.Add(row);
        return row.View;
    }

    void OnMic(object? sender, Avalonia.Interactivity.RoutedEventArgs e) =>
        _inserter.OpenMicrophoneSettings();

    void OnKey(object? sender, Avalonia.Interactivity.RoutedEventArgs e) => _onUseKey();

    public void Update()
    {
        var mic = _mic.IsAuthorized;
        var insert = _inserter.IsTrusted;
        var creds = Auth.Current(Auth.DefaultPath, _keys.Load());

        if (mic)
        {
            _monitor ??= new WaveRecorder();
            _monitor.OnLevel = level => Dispatcher.UIThread.Post(() => _rows[0].ShowLevel(level));
            try { if (!_monitor.IsRunning) _monitor.Start(); } catch { /* no device */ }
        }
        else
        {
            _monitor?.Stop();
            _monitor = null;
        }

        _rows[0].Apply(mic, mic ? "Say something — the bar should move." : null, showMeter: mic);
        _rows[1].Apply(insert, insert
            ? "Windows lets Quill type in your session without an extra toggle."
            : null, showMeter: false);
        string? credNote = creds is null ? null : creds.Source switch
        {
            Auth.Source.ApiKey => "Your own key — " + (Auth.Redact(creds.Token) ?? "stored"),
            _ => creds.Email ?? "Signed in",
        };
        if (creds is not null && creds.Source == Auth.Source.ApiKey)
            _rows[2].SetTitle("xAI API key");
        else
            _rows[2].SetTitle("Grok sign-in or API key");
        _rows[2].Apply(creds is not null, credNote, showMeter: false);

        var gesture = TriggerInfo.Gesture(_settings.Trigger, _settings.SingleTap);
        var all = mic && insert && creds is not null;
        _footer.Text = all
            ? $"You're set. {gesture} to start talking, then click where you want the words."
            : "Quill can't work until the items above are green. Nothing else is needed.";
    }

    sealed class Row
    {
        public Control View { get; }
        readonly TextBlock _mark = new() { Text = "○", FontSize = 15, FontWeight = FontWeight.Bold, Width = 18 };
        readonly TextBlock _title;
        readonly TextBlock _detail;
        readonly Button? _button;
        readonly ProgressBar _meter = new()
        {
            Minimum = 0, Maximum = 1, Width = 90, Height = 8, IsVisible = false,
            VerticalAlignment = VerticalAlignment.Center,
        };

        public Row(string title, string detail, string? action, EventHandler<Avalonia.Interactivity.RoutedEventArgs>? click)
        {
            _title = new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeight.SemiBold };
            _detail = new TextBlock
            {
                Text = detail, FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(160, 160, 160)),
                TextWrapping = TextWrapping.Wrap,
            };
            if (action is not null)
            {
                _button = new Button { Content = action, Padding = new Thickness(10, 4) };
                if (click is not null) _button.Click += click;
            }

            var head = new DockPanel();
            if (_button is not null)
            {
                DockPanel.SetDock(_button, Dock.Right);
                head.Children.Add(_button);
            }
            DockPanel.SetDock(_mark, Dock.Left);
            head.Children.Add(_mark);
            head.Children.Add(_title);

            var body = new DockPanel { Margin = new Thickness(26, 2, 0, 0) };
            DockPanel.SetDock(_meter, Dock.Right);
            body.Children.Add(_meter);
            body.Children.Add(_detail);

            View = new StackPanel { Children = { head, body } };
        }

        public void SetTitle(string title) => _title.Text = title;

        public void Apply(bool satisfied, string? note, bool showMeter)
        {
            _mark.Text = satisfied ? "✓" : "○";
            _mark.Foreground = satisfied
                ? new SolidColorBrush(Color.FromRgb(48, 209, 88))
                : new SolidColorBrush(Color.FromRgb(90, 90, 90));
            if (_button is not null) _button.IsVisible = !satisfied;
            if (note is not null) _detail.Text = note;
            _meter.IsVisible = showMeter;
        }

        public void ShowLevel(float level)
        {
            if (!_meter.IsVisible) return;
            _meter.Value = Math.Min(1, level * 3);
        }
    }
}
