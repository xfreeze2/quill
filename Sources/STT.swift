import Foundation

/// Streaming speech-to-text over the same socket Grok Build's /voice uses.
///
/// Protocol, verified live against the endpoint:
///   → binary PCM16 frames, then {"type":"audio.done"}
///   ← {"type":"transcript.created", id}
///   ← {"type":"transcript.partial", text, words[], is_final, speech_final}
///   ← {"type":"transcript.done"}          (text is empty; the real text is the
///                                          accumulation of the partials)
final class STTClient: NSObject, URLSessionWebSocketDelegate {

    enum Failure: Equatable {
        case unauthorized
        case offline(String)
        case server(String)

        var message: String {
            switch self {
            case .unauthorized:      return "Not authorized — refresh Grok Build sign-in, or check your xAI API key"
            case .offline(let m):    return m
            case .server(let m):     return m
            }
        }
    }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    /// The server segments an utterance by `start` time. Within one segment the
    /// partials are cumulative (each carries the whole segment so far), and the
    /// segment closes with is_final=true — emitted TWICE, once with
    /// speech_final=false and once with true, carrying identical text. So the only
    /// correct model is last-write-wins per `start`, never append.
    private var segmentOrder: [Double] = []
    private var segments: [Double: String] = [:]
    private var didFinish = false
    private var doneTimer: Timer?
    private var socketOpen = false
    private var finishRequested = false

    /// Best transcript so far — fires on every partial.
    var onText: (String) -> Void = { _ in }
    /// The socket is up and audio is being accepted.
    var onReady: () -> Void = {}
    /// Terminal: the complete transcript.
    var onComplete: (String) -> Void = { _ in }
    var onFailure: (Failure) -> Void = { _ in }

    var transcript: String {
        segmentOrder.compactMap { segments[$0] }.joined(separator: " ")
    }

    private func record(start: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Interim empties are the server clearing its buffer between segments —
        // they must never wipe text we already have.
        guard !trimmed.isEmpty else { return }
        if segments[start] == nil { segmentOrder.append(start) }
        segments[start] = trimmed
    }

    func connect(token: String, language: String) {
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        var items: [URLQueryItem] = [
            .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "pcm"),
            .init(name: "interim_results", value: "true"),
        ]
        if !language.isEmpty, language != "auto" {
            items.append(.init(name: "language", value: language))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        receive()
    }

    func send(pcm: Data) {
        task?.send(.data(pcm)) { _ in }
    }

    /// Tell the server we're done, then wait for the tail of the transcript.
    ///
    /// If the socket has not finished connecting yet — which is exactly the case
    /// on the first recording after launch, where DNS and the TLS handshake are
    /// still in flight — the request is held until it opens, so the buffered audio
    /// is still sent and still transcribed. Ending the session early here is what
    /// made the first dictation silently produce nothing.
    func finish() {
        guard !didFinish else { return }
        if socketOpen {
            sendDone()
        } else {
            Log.write("  finish deferred — socket still connecting, audio held")
            finishRequested = true
        }
    }

    private func sendDone() {
        task?.send(.string(#"{"type":"audio.done"}"#)) { _ in }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.doneTimer?.invalidate()
            self.doneTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.complete()
            }
        }
    }

    func cancel() {
        didFinish = true
        doneTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
    }

    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        doneTimer?.invalidate()
        let text = transcript
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { [weak self] in self?.onComplete(text) }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleTransportFailure(error)
            case .success(let message):
                switch message {
                case .string(let s): self.handle(json: s)
                case .data(let d):   self.handle(json: String(decoding: d, as: UTF8.self))
                @unknown default:    break
                }
                self.receive()
            }
        }
    }

    private func handle(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "transcript.partial":
            record(start: (object["start"] as? Double) ?? 0,
                   text: (object["text"] as? String) ?? "")
            let snapshot = transcript
            DispatchQueue.main.async { [weak self] in self?.onText(snapshot) }

        case "transcript.created":
            break

        case "transcript.done":
            let text = ((object["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // Server sent a consolidated transcript — prefer it wholesale.
                segmentOrder = [-1]
                segments = [-1: text]
            }
            complete()

        case "error":
            let message = (object["message"] as? String)
                ?? (object["error"] as? String)
                ?? "Transcription error"
            DispatchQueue.main.async { [weak self] in self?.onFailure(.server(message)) }

        default:
            break
        }
    }

    private func handleTransportFailure(_ error: Error) {
        guard !didFinish else { return }

        if let response = task?.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            didFinish = true
            DispatchQueue.main.async { [weak self] in self?.onFailure(.unauthorized) }
            return
        }

        // A normal server-side close after audio.done arrives here as an error.
        if !transcript.isEmpty {
            complete()
            return
        }

        didFinish = true
        let ns = error as NSError
        let message = ns.code == NSURLErrorNotConnectedToInternet
            ? "No network connection"
            : ns.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onFailure(.offline(message)) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.socketOpen = true
            self.onReady()                       // flushes whatever was buffered
            if self.finishRequested { self.sendDone() }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard !didFinish else { return }
        if !transcript.isEmpty {
            complete()
        } else {
            didFinish = true
            DispatchQueue.main.async { [weak self] in
                self?.onFailure(.server("Connection closed (code \(closeCode.rawValue))"))
            }
        }
    }
}
