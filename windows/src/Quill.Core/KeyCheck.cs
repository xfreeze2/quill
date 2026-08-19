namespace Quill;

public static class KeyCheck
{
    public static async Task<(bool ok, string? detail)> VerifyAsync(
        string key, HttpClient http, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.x.ai/v1/models");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + key);
        try
        {
            using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
            var code = (int)resp.StatusCode;
            return code switch
            {
                200 => (true, null),
                401 or 403 => (false, "it was not accepted"),
                429 => (false, "rate limited, try again shortly"),
                _ => (false, "HTTP " + code),
            };
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }
}
