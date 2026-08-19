using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Quill;

/// <summary>
/// Checks GitHub for a newer release. Notice only — never downloads or installs.
/// Prefers the /releases/latest redirect so we are not subject to the unauthenticated
/// REST API's 60 requests/hour/IP cap.
/// </summary>
public static class Updater
{
    public const string RedirectUrl = "https://github.com/xfreeze2/quill/releases/latest";
    public const string ApiUrl = "https://api.github.com/repos/xfreeze2/quill/releases/latest";
    public static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);

    public sealed record Update(string Version, string Url);

    public sealed class CheckError : Exception
    {
        public bool IsRateLimit { get; init; }
        public DateTimeOffset? ResetAt { get; init; }

        public CheckError(string message, bool isRateLimit = false, DateTimeOffset? resetAt = null)
            : base(message)
        {
            IsRateLimit = isRateLimit;
            ResetAt = resetAt;
        }

        public string DisplayMessage
        {
            get
            {
                if (!IsRateLimit) return Message;
                if (ResetAt is { } reset)
                {
                    var minutes = Math.Max(1, (int)(reset - DateTimeOffset.Now).TotalMinutes);
                    return $"GitHub rate limit reached on this network — try again in {minutes}m";
                }
                return "GitHub rate limit reached on this network — try again shortly";
            }
        }
    }

    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string s) =>
            s.Split('.').Select(p =>
            {
                var digits = Regex.Match(p, @"^\d+");
                return digits.Success && int.TryParse(digits.Value, out var n) ? n : 0;
            }).ToArray();

        var a = Parts(candidate);
        var b = Parts(current);
        var n = Math.Max(a.Length, b.Length);
        for (var i = 0; i < n; i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    public static async Task<(Update? update, CheckError? error)> CheckViaRedirectAsync(
        string currentVersion, HttpMessageInvoker http, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Head, RedirectUrl);
        using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
        var final = resp.RequestMessage?.RequestUri ?? resp.Headers.Location;
        // HttpClient follows redirects by default; the final URI is .../releases/tag/vX.Y.Z
        var last = final?.Segments.LastOrDefault()?.Trim('/');
        if (string.IsNullOrEmpty(last) || !last.StartsWith('v'))
            return (null, new CheckError("unexpected response"));

        var latest = last[1..];
        return Record(latest, $"https://github.com/xfreeze2/quill/releases/tag/v{latest}", currentVersion);
    }

    public static async Task<(Update? update, CheckError? error)> CheckViaApiAsync(
        string currentVersion, HttpMessageInvoker http, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, ApiUrl);
        req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
        req.Headers.TryAddWithoutValidation("User-Agent", "Quill/" + currentVersion);
        using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
        if ((int)resp.StatusCode != 200)
        {
            resp.Headers.TryGetValues("x-ratelimit-remaining", out var remaining);
            resp.Headers.TryGetValues("x-ratelimit-reset", out var reset);
            var isLimit = resp.StatusCode == HttpStatusCode.Forbidden && remaining?.FirstOrDefault() == "0";
            DateTimeOffset? resetAt = null;
            if (reset?.FirstOrDefault() is { } r && double.TryParse(r, out var unix))
                resetAt = DateTimeOffset.FromUnixTimeSeconds((long)unix);
            return (null, new CheckError($"HTTP {(int)resp.StatusCode}", isLimit, resetAt));
        }

        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        if (!doc.RootElement.TryGetProperty("tag_name", out var tagEl) || tagEl.GetString() is not { } tag)
            return (null, new CheckError("unreadable response"));
        var latest = tag.StartsWith('v') ? tag[1..] : tag;
        return Record(latest, $"https://github.com/xfreeze2/quill/releases/tag/{tag}", currentVersion);
    }

    public static async Task<(Update? update, CheckError? error)> CheckAsync(
        string currentVersion, HttpMessageInvoker http, CancellationToken ct = default)
    {
        try
        {
            var viaRedirect = await CheckViaRedirectAsync(currentVersion, http, ct).ConfigureAwait(false);
            if (viaRedirect.error is null) return viaRedirect;
        }
        catch
        {
            // Fall through to API.
        }

        try
        {
            return await CheckViaApiAsync(currentVersion, http, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return (null, new CheckError(ex.Message));
        }
    }

    static (Update? update, CheckError? error) Record(string latest, string url, string current)
    {
        if (IsNewer(latest, current))
            return (new Update(latest, url), null);
        return (null, null);
    }
}
