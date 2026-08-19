using System.Globalization;
using System.Text.Json;

namespace Quill;

/// <summary>
/// Reads the Grok Build (grok CLI) OIDC credential from ~/.grok/auth.json.
/// Never caches the token. An API key the user entered wins over the CLI session.
/// </summary>
public static class Auth
{
    public enum Source
    {
        GrokBuild,
        ApiKey,
    }

    public sealed record Creds(string Token, DateTimeOffset? ExpiresAt, string? Email, Source Source)
    {
        public bool IsExpired => ExpiresAt is { } exp && exp < DateTimeOffset.Now;
    }

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".grok", "auth.json");

    public static Creds? Current(string? authJsonPath, string? apiKey)
    {
        if (!string.IsNullOrWhiteSpace(apiKey))
            return new Creds(apiKey.Trim(), null, null, Source.ApiKey);
        return Load(authJsonPath ?? DefaultPath);
    }

    public static Creds? Load(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;

            JsonElement? newest = null;
            var newestTime = DateTimeOffset.MinValue;
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (prop.Value.ValueKind != JsonValueKind.Object) continue;
                if (!prop.Value.TryGetProperty("key", out var keyEl) || keyEl.ValueKind != JsonValueKind.String)
                    continue;
                var created = ParseDate(GetString(prop.Value, "create_time")) ?? DateTimeOffset.MinValue;
                if (created >= newestTime)
                {
                    newestTime = created;
                    newest = prop.Value;
                }
            }

            if (newest is not { } entry) return null;
            var key = GetString(entry, "key");
            if (string.IsNullOrEmpty(key)) return null;
            return new Creds(
                key,
                ParseDate(GetString(entry, "expires_at")),
                GetString(entry, "email"),
                Source.GrokBuild);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static string? Redact(string? key)
    {
        if (string.IsNullOrEmpty(key)) return null;
        if (key.Length <= 10) return "•••";
        return key[..6] + "…" + key[^4..];
    }

    public static bool LooksLikeApiKey(string raw)
    {
        var key = raw.Trim();
        return key.Length > 16 && !key.Contains(' ');
    }

    static string? GetString(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;

    static DateTimeOffset? ParseDate(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var dto))
            return dto;
        return null;
    }
}
