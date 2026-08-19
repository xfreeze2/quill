using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Quill;

namespace Quill.Win;

sealed class ApiKeyWindow : Window
{
    public ApiKeyWindow(IApiKeyStore keys, Action<string> log, Action? onChanged)
    {
        Title = keys.HasKey ? "Change your xAI API key" : "Use your own xAI API key";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(22, 22, 22));
        Foreground = Brushes.White;

        var field = new TextBox
        {
            PasswordChar = '•',
            Watermark = keys.HasKey ? (keys.Redacted ?? "xai-…") : "xai-…",
            Margin = new Thickness(0, 12, 0, 16),
        };

        var status = new TextBlock
        {
            FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromRgb(160, 160, 160)),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 0),
        };

        var save = new Button { Content = "Save", Padding = new Thickness(14, 6) };
        var cancel = new Button { Content = "Cancel", Padding = new Thickness(14, 6) };
        var remove = new Button { Content = "Remove", Padding = new Thickness(14, 6), IsVisible = keys.HasKey };

        save.Click += async (_, _) =>
        {
            var key = field.Text?.Trim() ?? "";
            if (!Auth.LooksLikeApiKey(key))
            {
                status.Text = "That doesn't look like an API key. Copy it from console.x.ai — it starts with “xai-”.";
                return;
            }
            save.IsEnabled = false;
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
            var (ok, detail) = await KeyCheck.VerifyAsync(key, http);
            log("api key check → " + (ok ? "HTTP 200" : detail ?? "fail"));
            if (!ok)
            {
                status.Text = "That key was rejected by xAI" + (detail is null ? "." : " — " + detail + ".") + " Nothing was saved.";
                save.IsEnabled = true;
                return;
            }
            if (keys.Save(key))
            {
                log("api key stored: True");
                status.Text = "Key saved. Quill will use it from now on.";
                onChanged?.Invoke();
                await Task.Delay(600);
                Close();
            }
            else
            {
                status.Text = "Couldn't save the key. Nothing was stored.";
                save.IsEnabled = true;
            }
        };
        cancel.Click += (_, _) => Close();
        remove.Click += (_, _) =>
        {
            keys.Remove();
            log("api key removed");
            onChanged?.Invoke();
            Close();
        };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
            Children = { remove, cancel, save },
        };

        Content = new StackPanel
        {
            Margin = new Thickness(24),
            Children =
            {
                new TextBlock
                {
                    Text = Title,
                    FontSize = 16, FontWeight = FontWeight.SemiBold,
                },
                new TextBlock
                {
                    Text = "With a key from console.x.ai, Quill works without a Grok subscription. "
                        + "Usage is billed to your own xAI account. The key is stored in Windows Credential Manager, "
                        + "is never written to logs, and is only ever sent to api.x.ai.",
                    FontSize = 13,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = new SolidColorBrush(Color.FromRgb(180, 180, 180)),
                    Margin = new Thickness(0, 8, 0, 0),
                },
                field,
                buttons,
                status,
            },
        };
    }
}
