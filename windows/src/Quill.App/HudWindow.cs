using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Quill;
using Quill.Win.Native;

namespace Quill.Win;

sealed class HudWindow : Window, IHud
{
    public const double Compact = 30;
    public const double ExpandedW = 396;
    public const double ExpandedH = 68;
    const double EdgeMargin = 14;

    readonly Settings _settings;
    readonly Border _shell;
    readonly Panel _compact;
    readonly Panel _expanded;
    readonly Ellipse _dot;
    readonly TextBlock _elapsed;
    readonly TextBlock _target;
    readonly TextBlock _transcript;
    readonly WaveformControl _wave;
    readonly DispatcherTimer _pulse = new() { Interval = TimeSpan.FromMilliseconds(36) };
    readonly DispatcherTimer _collapse = new();

    HudStateKind _kind = HudStateKind.Idle;
    bool _needsPermission;
    bool _hovering;
    DateTime _targetOverrideUntil = DateTime.MinValue;
    Point? _dragOrigin;
    bool _didDrag;
    double _pulseT;
    IntPtr _hwnd;

    public Action OnClick { get; set; } = () => { };
    public Action OnMenu { get; set; } = () => { };
    public IntPtr NativeHandle => _hwnd != IntPtr.Zero ? _hwnd : TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;

    public bool ShowsIdlePill { get; set; } = true;

    public HudWindow(Settings settings)
    {
        _settings = settings;
        Width = Compact;
        Height = Compact;
        SystemDecorations = SystemDecorations.None;
        CanResize = false;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        Focusable = false;
        Background = Brushes.Transparent;
        TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent };
        TransparencyBackgroundFallback = Brushes.Transparent;

        _dot = new Ellipse
        {
            Width = 7, Height = 7,
            Fill = new SolidColorBrush(Color.FromRgb(255, 59, 48)),
        };
        _elapsed = new TextBlock
        {
            FontFamily = new FontFamily("Segoe UI, Segoe UI Variable"),
            FontSize = 11, FontWeight = FontWeight.SemiBold,
            Foreground = new SolidColorBrush(Colors.White, 0.55),
            Text = "0:00",
            VerticalAlignment = VerticalAlignment.Center,
        };
        _wave = new WaveformControl { Width = 130, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        _target = new TextBlock
        {
            FontSize = 11, FontWeight = FontWeight.Medium,
            Foreground = new SolidColorBrush(Colors.White, 0.48),
            TextAlignment = TextAlignment.Right,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 140,
        };
        _transcript = new TextBlock
        {
            FontSize = 13,
            Foreground = new SolidColorBrush(Colors.White, 0.96),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
        };

        var glyph = new TextBlock
        {
            Text = "∿",
            FontSize = 16,
            Foreground = Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _compact = new Grid { Children = { glyph } };

        var top = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children = { _dot, _elapsed, _wave },
        };
        var header = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(_target, Dock.Right);
        header.Children.Add(_target);
        header.Children.Add(top);

        _expanded = new DockPanel
        {
            Margin = new Thickness(16, 12, 16, 12),
            IsVisible = false,
        };
        DockPanel.SetDock(header, Dock.Top);
        _expanded.Children.Add(header);
        _expanded.Children.Add(_transcript);

        _shell = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(18, 18, 18), 0.90),
            BorderBrush = new SolidColorBrush(Colors.White, 0.16),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(15),
            ClipToBounds = true,
            Child = new Grid { Children = { _compact, _expanded } },
        };

        Content = _shell;
        PointerEntered += (_, _) => { _hovering = true; ApplyAlpha(); };
        PointerExited += (_, _) => { _hovering = false; ApplyAlpha(); };
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
        _pulse.Tick += (_, _) =>
        {
            _pulseT += 0.09;
            var o = 0.2 + 0.8 * (0.5 + 0.5 * Math.Sin(_pulseT));
            _dot.Opacity = o;
        };
        Opened += (_, _) =>
        {
            _hwnd = TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;
            Place(compact: true);
            ApplyNative(clickThrough: false);
        };
    }

    public void Apply(HudState state)
    {
        Dispatcher.UIThread.Post(() => ApplyCore(state));
    }

    void ApplyCore(HudState state)
    {
        _collapse.Stop();
        _kind = state.Kind;
        var compact = state.Kind == HudStateKind.Idle;
        _compact.IsVisible = compact;
        _expanded.IsVisible = !compact;
        _shell.CornerRadius = new CornerRadius(compact ? 15 : 19);
        _wave.IsVisible = state.Kind == HudStateKind.Listening;
        _elapsed.IsVisible = state.Kind != HudStateKind.Notice;

        switch (state.Kind)
        {
            case HudStateKind.Idle:
                StopPulse();
                _wave.Reset();
                ToolTip.SetTip(this, _needsPermission
                    ? "Quill needs a microphone and a Grok session — click to finish setup"
                    : "Tap the trigger key to dictate · drag to an edge");
                break;
            case HudStateKind.Listening:
                _dot.Fill = new SolidColorBrush(Color.FromRgb(255, 59, 48));
                StartPulse();
                _elapsed.Text = "0:00";
                _elapsed.FontWeight = FontWeight.SemiBold;
                _transcript.Foreground = new SolidColorBrush(Colors.White, 0.38);
                _transcript.Text = "Listening… click where the words should go";
                break;
            case HudStateKind.Thinking:
                StopPulse();
                _dot.Fill = new SolidColorBrush(Color.FromRgb(255, 159, 10));
                _elapsed.Text = "Transcribing";
                _elapsed.FontWeight = FontWeight.SemiBold;
                if (_transcript.Text?.StartsWith("Listening") == true) _transcript.Text = "";
                break;
            case HudStateKind.Delivered:
                StopPulse();
                _dot.Fill = new SolidColorBrush(Color.FromRgb(48, 209, 88));
                _elapsed.Text = "Inserted";
                _elapsed.FontWeight = FontWeight.Medium;
                _target.Text = state.Detail ?? "";
                break;
            case HudStateKind.Notice:
                StopPulse();
                _dot.Fill = new SolidColorBrush(Color.FromRgb(255, 214, 10));
                _target.Text = "";
                _transcript.Foreground = new SolidColorBrush(Colors.White, 0.78);
                _transcript.Text = state.Detail ?? "";
                break;
        }

        if (compact && !ShowsIdlePill)
        {
            Hide();
            return;
        }
        if (!IsVisible) Show();
        Place(compact);
        ApplyNative(clickThrough: !compact);
        ApplyAlpha();
    }

    public void UpdateText(string text) => Dispatcher.UIThread.Post(() =>
    {
        if (_kind == HudStateKind.Idle) return;
        _transcript.Foreground = new SolidColorBrush(Colors.White, 0.96);
        _transcript.Text = text;
    });

    public void UpdateLevel(float level) => Dispatcher.UIThread.Post(() => _wave.Push(level));

    public void UpdateElapsed(TimeSpan elapsed) => Dispatcher.UIThread.Post(() =>
    {
        if (_kind == HudStateKind.Idle) return;
        var whole = (int)elapsed.TotalSeconds;
        _elapsed.Text = $"{whole / 60}:{whole % 60:00}";
    });

    public void UpdateTarget(string? name) => Dispatcher.UIThread.Post(() =>
    {
        if (DateTime.UtcNow < _targetOverrideUntil) return;
        if (_kind == HudStateKind.Idle) return;
        _target.Text = name ?? "";
    });

    public void FlashTarget(string message, TimeSpan duration) => Dispatcher.UIThread.Post(() =>
    {
        _targetOverrideUntil = DateTime.UtcNow + duration;
        _target.Text = message;
    });

    public void CollapseAfter(TimeSpan delay)
    {
        Dispatcher.UIThread.Post(() =>
        {
            _collapse.Stop();
            _collapse.Interval = delay;
            EventHandler? tick = null;
            tick = (_, _) =>
            {
                _collapse.Stop();
                _collapse.Tick -= tick!;
                ApplyCore(new HudState(HudStateKind.Idle));
            };
            _collapse.Tick += tick;
            _collapse.Start();
        });
    }

    public bool ContainsPoint(double x, double y)
    {
        if (!IsVisible) return false;
        var r = new Rect(Position.X - 6, Position.Y - 6, Bounds.Width + 12, Bounds.Height + 12);
        return r.Contains(new Point(x, y));
    }

    public void SetNeedsPermission(bool needed)
    {
        _needsPermission = needed;
        if (_kind == HudStateKind.Idle) ApplyCore(new HudState(HudStateKind.Idle));
    }

    public void ResetPosition()
    {
        _settings.HudEdge = "right";
        _settings.HudEdgeOffset = 0.82;
        Place(_kind == HudStateKind.Idle);
    }

    void Place(bool compact)
    {
        var screen = Screens.Primary ?? Screens.All.FirstOrDefault();
        if (screen is null) return;
        var area = screen.WorkingArea;
        var w = compact ? Compact : ExpandedW;
        var h = compact ? Compact : ExpandedH;
        Width = w;
        Height = h;
        var edge = _settings.HudEdge == "left" ? "left" : "right";
        var offset = Math.Clamp(_settings.HudEdgeOffset, 0.04, 0.96);
        var x = edge == "left" ? area.X + EdgeMargin : area.X + area.Width - w - EdgeMargin;
        var centreY = area.Y + offset * area.Height;
        var y = Math.Clamp(centreY - h / 2, area.Y + 6, area.Y + area.Height - h - 6);
        Position = new PixelPoint((int)x, (int)y);
    }

    void ApplyNative(bool clickThrough)
    {
        if (_hwnd == IntPtr.Zero)
            _hwnd = TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;
        if (_hwnd != IntPtr.Zero)
            Win32.ApplyNoActivate(_hwnd, clickThrough);
    }

    void ApplyAlpha()
    {
        if (_kind != HudStateKind.Idle)
        {
            Opacity = 1;
            return;
        }
        if (_needsPermission) Opacity = _hovering ? 1.0 : 0.85;
        else Opacity = _hovering ? 0.9 : 0.20;
    }

    void StartPulse()
    {
        _pulseT = 0;
        if (!_pulse.IsEnabled) _pulse.Start();
    }

    void StopPulse()
    {
        _pulse.Stop();
        _dot.Opacity = 1;
    }

    void OnPressed(object? sender, PointerPressedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (point.Properties.IsRightButtonPressed)
        {
            OnMenu();
            return;
        }
        if (_kind != HudStateKind.Idle) return;
        _didDrag = false;
        _dragOrigin = e.GetPosition(this);
        e.Pointer.Capture(this);
    }

    void OnMoved(object? sender, PointerEventArgs e)
    {
        if (_dragOrigin is not { } origin || _kind != HudStateKind.Idle) return;
        var now = e.GetPosition(this);
        if (!_didDrag && Math.Abs(now.X - origin.X) + Math.Abs(now.Y - origin.Y) < 3) return;
        _didDrag = true;
        var screen = e.GetPosition(null);
        // GetPosition(null) is window-relative in Avalonia; use pointer screen point.
        var p = e.GetPosition(this);
        Position = new PixelPoint(
            Position.X + (int)(p.X - origin.X),
            Position.Y + (int)(p.Y - origin.Y));
    }

    void OnReleased(object? sender, PointerReleasedEventArgs e)
    {
        e.Pointer.Capture(null);
        if (_kind != HudStateKind.Idle)
        {
            _dragOrigin = null;
            return;
        }
        if (_didDrag)
        {
            SnapFromCurrent();
        }
        else if (e.InitialPressMouseButton == MouseButton.Left)
        {
            OnClick();
        }
        _dragOrigin = null;
        _didDrag = false;
    }

    void SnapFromCurrent()
    {
        var screen = Screens.ScreenFromWindow(this) ?? Screens.Primary;
        if (screen is null) return;
        var area = screen.WorkingArea;
        var centreX = Position.X + Bounds.Width / 2;
        var centreY = Position.Y + Bounds.Height / 2;
        _settings.HudEdge = (centreX - area.X) < (area.X + area.Width - centreX) ? "left" : "right";
        _settings.HudEdgeOffset = Math.Clamp((centreY - area.Y) / Math.Max(area.Height, 1), 0.04, 0.96);
        Place(true);
    }
}

sealed class WaveformControl : Control
{
    readonly double[] _samples = new double[34];
    double _smoothed;

    public void Push(float level)
    {
        var value = Math.Clamp(level, 0, 1);
        _smoothed = _smoothed * 0.62 + value * 0.38;
        Array.Copy(_samples, 1, _samples, 0, _samples.Length - 1);
        _samples[^1] = _smoothed;
        InvalidateVisual();
    }

    public void Reset()
    {
        Array.Clear(_samples);
        _smoothed = 0;
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var barWidth = 2.5;
        var n = _samples.Length;
        var spacing = (Bounds.Width - n * barWidth) / Math.Max(n - 1, 1);
        var midY = Bounds.Height / 2;
        for (var i = 0; i < n; i++)
        {
            var recency = (double)i / (n - 1);
            var alpha = 0.14 + 0.66 * recency;
            var height = Math.Max(barWidth, Bounds.Height * (0.10 + 0.90 * _samples[i]));
            var rect = new Rect(i * (barWidth + spacing), midY - height / 2, barWidth, height);
            context.DrawRectangle(new SolidColorBrush(Colors.White, alpha), null, rect, barWidth / 2, barWidth / 2);
        }
    }
}
