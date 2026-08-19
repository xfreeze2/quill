using Quill;
using Xunit;

namespace Quill.Tests;

public class AuthTests
{
    [Fact]
    public void LoadsNewestEntryWithAKey()
    {
        var path = Path.Combine(Path.GetTempPath(), "quill-auth-" + Guid.NewGuid().ToString("n") + ".json");
        File.WriteAllText(path, """
            {
              "old::one": {
                "key": "old-token",
                "email": "old@example.com",
                "create_time": "2026-01-01T00:00:00Z",
                "expires_at": "2026-01-02T00:00:00Z"
              },
              "new::two": {
                "key": "new-token",
                "email": "new@example.com",
                "create_time": "2026-08-01T00:00:00Z",
                "expires_at": "2027-01-01T00:00:00Z"
              }
            }
            """);
        try
        {
            var creds = Auth.Load(path);
            Assert.NotNull(creds);
            Assert.Equal("new-token", creds!.Token);
            Assert.Equal("new@example.com", creds.Email);
            Assert.Equal(Auth.Source.GrokBuild, creds.Source);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void MissingFileIsNull() =>
        Assert.Null(Auth.Load(Path.Combine(Path.GetTempPath(), "no-such-quill-auth.json")));

    [Fact]
    public void ApiKeyWinsOverGrokSession()
    {
        var creds = Auth.Current("/does/not/exist.json", "xai-abcdefghijklmnopqrstuvwxyz");
        Assert.NotNull(creds);
        Assert.Equal(Auth.Source.ApiKey, creds!.Source);
        Assert.Equal("xai-abcdefghijklmnopqrstuvwxyz", creds.Token);
    }

    [Fact]
    public void RedactsKey() =>
        Assert.Equal("xai-ab…" + "wxyz", Auth.Redact("xai-abcdefghijklmnopqrstuvwxyz"));

    [Fact]
    public void LooksLikeApiKey()
    {
        Assert.True(Auth.LooksLikeApiKey("xai-abcdefghijklmnopqrstuvwxyz"));
        Assert.False(Auth.LooksLikeApiKey("short"));
        Assert.False(Auth.LooksLikeApiKey("has spaces in it definitely"));
    }
}
