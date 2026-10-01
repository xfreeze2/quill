using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Quill;

public enum SttFailureKind { Unauthorized, Offline, Server }

public sealed record SttFailure(SttFailureKind Kind, string Message);

/// <summary>
/// What the dictation controller needs from a speech-to-text stream. The seam
/// exists so session behaviour — reconnects, replays, overlapping dictations —
/// can be tested without a socket.
/// </summary>
public interface ISttClient
{
    Action<string> OnText { get; set; }
    Action OnReady { get; set; }
    Action<string> OnComplete { get; set; }
    Action<SttFailure> OnFailure { get; set; }
    Action<string>? Log { get; set; }
    /// <summary>Best transcript so far — whatever has arrived, even after a failure.</summary>
    string Transcript { get; }
    void Connect(string token, string language);
    void SendPcm(ReadOnlyMemory<byte> pcm);
    void Finish();
    void Cancel();
}

/// <summary>
/// Streaming speech-to-text over the same socket Grok Build's /voice uses.
/// Protocol, verified live against the endpoint:
///   → binary PCM16 frames, then {"type":"audio.done"}
///   ← transcript.created / transcript.partial / transcript.done
/// </summary>
public sealed class SttClient : ISttClient, IAsyncDisposable
{
    readonly TranscriptAssembler _assembler = new();

    // ClientWebSocket allows a single outstanding SendAsync. Audio arrives on
    // the recorder's driver thread, so every send is queued here and written
    // by one loop — overlapping SendAsync calls would throw, and an exception
    // on the driver thread kills the process.
    readonly Channel<(ReadOnlyMemory<byte> payload, WebSocketMessageType type)> _sends =
        Channel.CreateUnbounded<(ReadOnlyMemory<byte>, WebSocketMessageType)>(
            new UnboundedChannelOptions { SingleReader = true });

    // Serialises the open ↔ give-up-waiting transition so a socket that opens
    // at the same instant the grace timer fires cannot both complete the
    // session and start streaming into it.
    readonly object _phase = new();

    ClientWebSocket? _socket;
    CancellationTokenSource? _cts;
    Task? _receive;
    Task? _sendLoop;
    Timer? _connectGrace;
    int _didFinish;
    int _socketOpen;
    int _finishRequested;
    int _doneSent;

    /// <summary>
    /// How long to keep waiting for a still-connecting socket once the user has
    /// asked to finish. Without a bound the session sat on "Transcribing" until
    /// the connect timeout — 20 seconds, or longer when the connection was
    /// half-dead — which reads as the app hanging. Generous, because the
    /// alternative is losing the words: a cold connection takes about two
    /// seconds, so a socket that has not opened eight seconds after the
    /// recording ended is not going to.
    /// </summary>
    internal static TimeSpan ConnectGrace = TimeSpan.FromSeconds(8);

    public Action<string> OnText { get; set; } = _ => { };
    public Action OnReady { get; set; } = () => { };
    public Action<string> OnComplete { get; set; } = _ => { };
    /// <summary>Terminal: the stream is dead. <see cref="Transcript"/> still holds
    /// whatever arrived before it died, so the caller can decide to keep it.</summary>
    public Action<SttFailure> OnFailure { get; set; } = _ => { };
    public Action<string>? Log { get; set; }

    public string Transcript => _assembler.Transcript;

    /// <summary>True once the socket has opened and audio is actually being accepted.</summary>
    public bool IsOpen => Volatile.Read(ref _socketOpen) == 1;

    public void Connect(string token, string language) => _ = ConnectAsync(token, language);

    public async Task ConnectAsync(string token, string language, CancellationToken ct = default)
    {
        var url = "wss://api.x.ai/v1/stt?sample_rate=16000&encoding=pcm&interim_results=true";
        if (!string.IsNullOrEmpty(language) && language != "auto")
            url += "&language=" + Uri.EscapeDataString(language);

        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _socket = new ClientWebSocket();
        _socket.Options.SetRequestHeader("Authorization", "Bearer " + token);
        _socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
        _socket.Options.CollectHttpResponseDetails = true;     // lets a 401 be told apart from a dead network

        var started = Environment.TickCount64;
        try
        {
            using var openCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            openCts.CancelAfter(TimeSpan.FromSeconds(20));
            await _socket.ConnectAsync(new Uri(url), openCts.Token).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            FailFromTransport(ex);
            return;
        }

        lock (_phase)
        {
            DisposeGrace();
            // The grace timer may already have completed the session; a late
            // open is then nothing to act on.
            if (Volatile.Read(ref _didFinish) == 1)
            {
                try { _socket.Abort(); } catch { /* ignore */ }
                return;
            }
            Volatile.Write(ref _socketOpen, 1);
        }
        Log?.Invoke($"  socket open in {Environment.TickCount64 - started}ms");
        _sendLoop = SendLoop();
        OnReady();
        if (Volatile.Read(ref _finishRequested) == 1)
            _ = SendDoneAsync();

        _receive = ReceiveLoop(_cts.Token);
    }

    public void SendPcm(ReadOnlyMemory<byte> pcm)
    {
        _sends.Writer.TryWrite((pcm, WebSocketMessageType.Binary));
    }

    async Task SendLoop()
    {
        try
        {
            await foreach (var (payload, type) in _sends.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                var socket = _socket;
                if (socket is not { State: WebSocketState.Open }) continue;
                try
                {
                    await socket.SendAsync(payload, type, true, CancellationToken.None).ConfigureAwait(false);
                }
                catch
                {
                    // Transport failures surface through the receive loop.
                }
            }
        }
        catch
        {
            // Channel completed — nothing more to send.
        }
    }

    /// <summary>
    /// The recording has ended; ask the server to finalise. If the socket is
    /// still connecting the request is held until it opens — the buffered audio
    /// is still sent and still transcribed. The wait is bounded: if the socket
    /// never opens, the session completes with whatever it has and the caller
    /// shows the real "couldn't reach speech-to-text" message.
    /// </summary>
    public void Finish()
    {
        if (Volatile.Read(ref _didFinish) == 1) return;
        if (Volatile.Read(ref _socketOpen) == 1)
        {
            _ = SendDoneAsync();
            return;
        }
        Log?.Invoke("  finish deferred — socket still connecting, audio held");
        Volatile.Write(ref _finishRequested, 1);
        var grace = new Timer(_ =>
        {
            lock (_phase)
            {
                if (Volatile.Read(ref _socketOpen) == 1) return;
                if (Interlocked.Exchange(ref _didFinish, 1) == 1) return;
            }
            Log?.Invoke($"  gave up waiting for the socket after {(int)ConnectGrace.TotalSeconds}s");
            FinishTerminal();
            OnComplete(_assembler.Transcript);
        }, null, ConnectGrace, Timeout.InfiniteTimeSpan);
        var old = Interlocked.Exchange(ref _connectGrace, grace);
        old?.Dispose();
        // The socket may have opened while the timer was being armed.
        if (Volatile.Read(ref _socketOpen) == 1 || Volatile.Read(ref _didFinish) == 1)
            DisposeGrace();
    }

    public void Cancel()
    {
        if (Interlocked.Exchange(ref _didFinish, 1) == 1) return;
        FinishTerminal();
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _socket?.Abort(); } catch { /* ignore */ }
    }

    async Task SendDoneAsync()
    {
        // Queued after any PCM still in flight, so no audio is cut off.
        Volatile.Write(ref _doneSent, 1);
        var payload = Encoding.UTF8.GetBytes("""{"type":"audio.done"}""");
        _sends.Writer.TryWrite((payload, WebSocketMessageType.Text));

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        }
        catch
        {
            return;
        }
        Complete();
    }

    async Task ReceiveLoop(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var socket = _socket;
        if (socket is null) return;
        var message = new MemoryStream();

        try
        {
            while (!ct.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    // Once audio.done is out, the server closing the socket is
                    // the normal end of the conversation. Before that it is a
                    // genuine drop mid-dictation, and the caller decides whether
                    // to reconnect or to keep the words that made it through.
                    if (Volatile.Read(ref _doneSent) == 1) Complete();
                    else Fail(new SttFailure(SttFailureKind.Server,
                        $"Speech-to-text closed the connection (code {(int)socket.CloseStatus.GetValueOrDefault()})"));
                    return;
                }
                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage) continue;
                var json = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                message.SetLength(0);
                HandleJson(json);
            }
        }
        catch (OperationCanceledException)
        {
            // cancelled
        }
        catch (Exception ex)
        {
            FailFromTransport(ex);
        }
    }

    void HandleJson(string json)
    {
        if (Volatile.Read(ref _didFinish) == 1) return;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("type", out var typeEl)) return;
            var type = typeEl.GetString();
            switch (type)
            {
                case "transcript.partial":
                    _assembler.Record(
                        root.TryGetProperty("start", out var startEl) && startEl.TryGetDouble(out var start) ? start : 0,
                        root.TryGetProperty("text", out var textEl) ? textEl.GetString() ?? "" : "");
                    OnText(_assembler.Transcript);
                    break;
                case "transcript.created":
                    break;
                case "transcript.done":
                    var doneText = root.TryGetProperty("text", out var doneEl) ? doneEl.GetString() ?? "" : "";
                    if (!string.IsNullOrWhiteSpace(doneText))
                        _assembler.ReplaceWithConsolidated(doneText);
                    Complete();
                    break;
                case "error":
                    var message = root.TryGetProperty("message", out var m) ? m.GetString()
                        : root.TryGetProperty("error", out var e) ? e.GetString()
                        : "Transcription error";
                    // After audio.done a server error changes nothing about the
                    // words already received — deliver them, don't throw them away.
                    if (Volatile.Read(ref _doneSent) == 1 && _assembler.Transcript.Length > 0)
                        Complete();
                    else
                        Fail(new SttFailure(SttFailureKind.Server, message ?? "Transcription error"));
                    break;
            }
        }
        catch
        {
            // ignore malformed frames
        }
    }

    void Complete()
    {
        if (Interlocked.Exchange(ref _didFinish, 1) == 1) return;
        FinishTerminal();
        var text = _assembler.Transcript;
        try { _socket?.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); }
        catch { /* ignore */ }
        OnComplete(text);
    }

    void FailFromTransport(Exception error)
    {
        if (Volatile.Read(ref _didFinish) == 1) return;
        if (Volatile.Read(ref _doneSent) == 1)
        {
            Complete();
            return;
        }
        if (IsUnauthorized(error))
        {
            Fail(new SttFailure(SttFailureKind.Unauthorized,
                "Grok session expired — open Grok Build once to refresh"));
            return;
        }
        Fail(new SttFailure(SttFailureKind.Offline, Describe(error)));
    }

    bool IsUnauthorized(Exception error)
    {
        if (_socket?.HttpStatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            return true;
        return error is HttpRequestException or WebSocketException
            && (error.Message.Contains("401", StringComparison.Ordinal)
                || error.Message.Contains("403", StringComparison.Ordinal));
    }

    /// <summary>Something a person can act on, rather than a raw socket error string.</summary>
    internal static string Describe(Exception error)
    {
        for (Exception? e = error; e is not null; e = e.InnerException)
        {
            switch (e)
            {
                case SocketException se:
                    return se.SocketErrorCode switch
                    {
                        SocketError.NetworkDown => "No network connection",
                        SocketError.TimedOut => "Speech-to-text did not answer in time",
                        SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain
                            or SocketError.NetworkUnreachable or SocketError.HostUnreachable
                            or SocketError.ConnectionRefused
                            => "Couldn't reach speech-to-text — check your connection",
                        _ => "Lost the connection to speech-to-text",
                    };
                case AuthenticationException:
                    return "Secure connection to speech-to-text failed";
                case OperationCanceledException:
                    return "Speech-to-text did not answer in time";
            }
        }
        if (error is WebSocketException ws && ws.WebSocketErrorCode == WebSocketError.ConnectionClosedPrematurely)
            return "Lost the connection to speech-to-text";
        if (error is HttpRequestException) return "Couldn't reach speech-to-text — check your connection";
        return error.Message;
    }

    void Fail(SttFailure failure)
    {
        if (Interlocked.Exchange(ref _didFinish, 1) == 1) return;
        FinishTerminal();
        try { _socket?.Abort(); } catch { /* ignore */ }
        OnFailure(failure);
    }

    /// <summary>Housekeeping shared by every terminal transition.</summary>
    void FinishTerminal()
    {
        _sends.Writer.TryComplete();
        DisposeGrace();
    }

    void DisposeGrace()
    {
        Interlocked.Exchange(ref _connectGrace, null)?.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        Cancel();
        if (_receive is not null)
        {
            try { await _receive.ConfigureAwait(false); } catch { /* ignore */ }
        }
        if (_sendLoop is not null)
        {
            try { await _sendLoop.ConfigureAwait(false); } catch { /* ignore */ }
        }
        _socket?.Dispose();
        _cts?.Dispose();
    }
}
