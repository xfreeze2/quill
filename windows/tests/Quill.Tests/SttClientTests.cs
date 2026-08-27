using Quill;
using Xunit;

namespace Quill.Tests;

public class SttClientTests
{
    [Fact]
    public async Task ConcurrentSendsNeverThrow()
    {
        // Audio arrives on the recorder driver's thread while audio.done and
        // buffered flushes come from others. All sends must be queue-backed —
        // ClientWebSocket itself allows only one outstanding SendAsync, and an
        // exception on the driver thread would kill the whole process.
        var client = new SttClient();
        var chunk = new byte[3200];

        Parallel.For(0, 8, _ =>
        {
            for (var i = 0; i < 200; i++) client.SendPcm(chunk);
        });

        client.Finish();
        client.SendPcm(chunk);
        client.Cancel();
        client.SendPcm(chunk); // after cancel: ignored, not an error
        await client.DisposeAsync();
    }

    [Fact]
    public async Task CancelBeforeConnectIsSafe()
    {
        var client = new SttClient();
        client.Cancel();
        await client.DisposeAsync();
    }
}
