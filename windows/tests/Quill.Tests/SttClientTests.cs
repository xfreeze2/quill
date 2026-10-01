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

    [Fact]
    public async Task FinishBeforeOpenGivesUpAfterTheGrace()
    {
        // Finishing while the socket is still connecting must not hang on the
        // connect timeout: after the grace it completes with whatever it has.
        var previous = SttClient.ConnectGrace;
        SttClient.ConnectGrace = TimeSpan.FromMilliseconds(80);
        try
        {
            var client = new SttClient();
            var completed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            client.OnComplete = t => completed.TrySetResult(t);
            client.OnFailure = f => completed.TrySetException(new Exception(f.Message));

            client.Finish();

            var done = await Task.WhenAny(completed.Task, Task.Delay(TimeSpan.FromSeconds(5)));
            Assert.Same(completed.Task, done);
            Assert.Equal("", await completed.Task);
            await client.DisposeAsync();
        }
        finally
        {
            SttClient.ConnectGrace = previous;
        }
    }

    [Fact]
    public void TransportErrorsReadLikeAdvice()
    {
        Assert.Equal("Couldn't reach speech-to-text — check your connection",
            SttClient.Describe(new System.Net.Sockets.SocketException(
                (int)System.Net.Sockets.SocketError.HostNotFound)));
        Assert.Equal("Speech-to-text did not answer in time",
            SttClient.Describe(new System.Net.Sockets.SocketException(
                (int)System.Net.Sockets.SocketError.TimedOut)));
        Assert.Equal("Lost the connection to speech-to-text",
            SttClient.Describe(new System.Net.Sockets.SocketException(
                (int)System.Net.Sockets.SocketError.ConnectionReset)));
        Assert.Equal("No network connection",
            SttClient.Describe(new System.Net.Sockets.SocketException(
                (int)System.Net.Sockets.SocketError.NetworkDown)));
        Assert.Equal("Secure connection to speech-to-text failed",
            SttClient.Describe(new System.Security.Authentication.AuthenticationException("boom")));
        // Wrapped errors resolve through their inner exceptions.
        Assert.Equal("Couldn't reach speech-to-text — check your connection",
            SttClient.Describe(new System.Net.WebSockets.WebSocketException(
                "outer", new System.Net.Sockets.SocketException(
                    (int)System.Net.Sockets.SocketError.ConnectionRefused))));
        Assert.Equal("Speech-to-text did not answer in time",
            SttClient.Describe(new TaskCanceledException()));
    }
}
