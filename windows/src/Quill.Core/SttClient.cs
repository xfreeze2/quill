using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Quill;

public enum SttFailureKind { Unauthorized, Offline, Server }

public sealed record SttFailure(SttFailureKind Kind, string Message);

/// <summary>
/// Streaming speech-to-text over the same socket Grok Build's /voice uses.
/// Protocol, verified live against the endpoint:
///   → binary PCM16 frames, then {"type":"audio.done"}
///   ← transcript.created / transcript.partial / transcript.done
/// </summary>
public sealed class SttClient : IAsyncDisposable
{
    readonly TranscriptAssembler _assembler = new();
    ClientWebSocket? _socket;
    CancellationTokenSource? _cts;
    Task? _receive;
    int _didFinish;
    int _socketOpen;
    int _finishRequested;

    public Action<string> OnText { get; set; } = _ => { };
    public Action OnReady { get; set; } = () => { };
    public Action<string> OnComplete { get; set; } = _ => { };
    public Action<SttFailure> OnFailure { get; set; } = _ => { };
    public Action<string>? Log { get; set; }

    public string Transcript => _assembler.Transcript;

    public async Task ConnectAsync(string token, string language, CancellationToken ct = default)
    {
        var url = "wss://api.x.ai/v1/stt?sample_rate=16000&encoding=pcm&interim_results=true";
        if (!string.IsNullOrEmpty(language) && language != "auto")
            url += "&language=" + Uri.EscapeDataString(language);

        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _socket = new ClientWebSocket();
        _socket.Options.SetRequestHeader("Authorization", "Bearer " + token);
        _socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);

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

        Volatile.Write(ref _socketOpen, 1);
        OnReady();
        if (Volatile.Read(ref _finishRequested) == 1)
            _ = SendDoneAsync();

        _receive = ReceiveLoop(_cts.Token);
    }

    public void SendPcm(ReadOnlyMemory<byte> pcm)
    {
        var socket = _socket;
        if (socket is not { State: WebSocketState.Open }) return;
        _ = socket.SendAsync(pcm, WebSocketMessageType.Binary, true, CancellationToken.None);
    }

    public void Finish()
    {
        if (Volatile.Read(ref _didFinish) == 1) return;
        if (Volatile.Read(ref _socketOpen) == 1)
        {
            _ = SendDoneAsync();
        }
        else
        {
            Log?.Invoke("  finish deferred — socket still connecting, audio held");
            Volatile.Write(ref _finishRequested, 1);
        }
    }

    public void Cancel()
    {
        if (Interlocked.Exchange(ref _didFinish, 1) == 1) return;
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _socket?.Abort(); } catch { /* ignore */ }
    }

    async Task SendDoneAsync()
    {
        try
        {
            var socket = _socket;
            if (socket is { State: WebSocketState.Open })
            {
                var payload = Encoding.UTF8.GetBytes("""{"type":"audio.done"}""");
                await socket.SendAsync(payload, WebSocketMessageType.Text, true, CancellationToken.None)
                    .ConfigureAwait(false);
            }
        }
        catch
        {
            // complete() below still fires on the timeout.
        }

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
                    if (!string.IsNullOrEmpty(_assembler.Transcript)) Complete();
                    else Fail(new SttFailure(SttFailureKind.Server, $"Connection closed (code {(int)socket.CloseStatus.GetValueOrDefault()})"));
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
        var text = _assembler.Transcript;
        try { _socket?.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); }
        catch { /* ignore */ }
        OnComplete(text);
    }

    void FailFromTransport(Exception error)
    {
        if (Volatile.Read(ref _didFinish) == 1) return;
        if (!string.IsNullOrEmpty(_assembler.Transcript))
        {
            Complete();
            return;
        }
        var message = error is HttpRequestException or WebSocketException
            && error.Message.Contains("401", StringComparison.Ordinal)
            ? null
            : error.Message;
        if (message is null)
        {
            Fail(new SttFailure(SttFailureKind.Unauthorized, "Grok session expired — open Grok Build once to refresh"));
            return;
        }
        var offline = error is HttpRequestException ? "No network connection" : message;
        Fail(new SttFailure(SttFailureKind.Offline, offline));
    }

    void Fail(SttFailure failure)
    {
        if (Interlocked.Exchange(ref _didFinish, 1) == 1) return;
        OnFailure(failure);
    }

    public async ValueTask DisposeAsync()
    {
        Cancel();
        if (_receive is not null)
        {
            try { await _receive.ConfigureAwait(false); } catch { /* ignore */ }
        }
        _socket?.Dispose();
        _cts?.Dispose();
    }
}
