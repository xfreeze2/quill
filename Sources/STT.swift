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
            case .unauthorized:      return "Grok session expired — open Grok Build once to refresh"
            case .offline(let m):    return m
            case .server(let m):     return m
            }
        }
    }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private static let traceRaw = ProcessInfo.processInfo.environment["QUILL_TRACE_STT"] != nil

    /// The server segments an utterance by `start` time. Within one segment the
    /// partials are cumulative (each carries the whole segment so far), and the
    /// segment closes with is_final=true — emitted TWICE, once with
    /// speech_final=false and once with true, carrying identical text. So the only
    /// correct model is last-write-wins per `start`, never append.
    private var segmentOrder: [Double] = []
    private var segments: [Double: String] = [:]
    private var didFinish = false
    private var doneTimer: Timer?
    private var connectTimer: Timer?
    private var socketOpen = false
    private var finishRequested = false
    private var doneSent = false
    private var connectedAt: Date?

    /// How long to keep waiting for a still-connecting socket once the user has
    /// asked to finish. Without a bound the session sat on "Transcribing" until
    /// the URL timeout — 20 seconds, or longer when the connection was half-dead
    /// — which reads as the app hanging. Generous, because the alternative is
    /// losing the words: a cold connection takes about two seconds, so a socket
    /// that has not opened eight seconds after the recording ended is not going to.
    private let connectGrace: TimeInterval = 8.0

    /// How long to wait for the last words after saying the audio is done.
    var doneGrace: TimeInterval = 3.0

    /// Best transcript so far — fires on every partial.
    var onText: (String) -> Void = { _ in }
    /// A partial exactly as the server sent it, for callers that follow the
    /// stream sentence by sentence rather than as one transcript.
    ///
    /// Measured against the live endpoint with the language left to auto-detect:
    /// interim partials carry the growing text of the chunk being spoken; each
    /// chunk closes with `isFinal`, whose `start` is the utterance's rather
    /// than the chunk's; and at a pause, `speechFinal` repeats every chunk
    /// since the last pause, joined. `language` is the socket's — it locks on
    /// the first speech it hears and stays there.
    struct Segment {
        let start: Double
        let text: String
        let isFinal: Bool
        let speechFinal: Bool
        let language: String?
        /// When its first word began and its last word ended, on this socket's
        /// clock — seconds of audio sent to it. Unlike `start`, the chunk's own.
        let firstWordAt: Double?
        let lastWordEnd: Double?
    }

    var onSegment: (Segment) -> Void = { _ in }
    /// The socket is up and audio is being accepted.
    var onReady: () -> Void = {}
    /// Terminal: the complete transcript.
    var onComplete: (String) -> Void = { _ in }
    /// Terminal: the stream is dead. `transcript` still holds whatever arrived
    /// before it died, so the caller can decide to keep it.
    var onFailure: (Failure) -> Void = { _ in }

    var transcript: String {
        segmentOrder.compactMap { segments[$0] }.joined(separator: " ")
    }

    /// True once the socket has opened and audio is actually being accepted.
    var isOpen: Bool { socketOpen }

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

        connectedAt = Date()
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
    /// made the first dictation silently produce nothing. The wait is bounded:
    /// if the socket never opens, the session completes with whatever it has and
    /// the caller shows the real "couldn't reach speech-to-text" message.
    func finish() {
        guard !didFinish else { return }
        if socketOpen {
            sendDone()
        } else {
            Log.write("  finish deferred — socket still connecting, audio held")
            finishRequested = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFinish, !self.socketOpen else { return }
                self.connectTimer?.invalidate()
                self.connectTimer = Timer.scheduledTimer(withTimeInterval: self.connectGrace, repeats: false) { [weak self] _ in
                    guard let self, !self.didFinish, !self.socketOpen else { return }
                    Log.write("  gave up waiting for the socket after \(Int(self.connectGrace))s")
                    self.complete()
                }
            }
        }
    }

    private func sendDone() {
        doneSent = true
        task?.send(.string(#"{"type":"audio.done"}"#)) { _ in }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.doneTimer?.invalidate()
            self.doneTimer = Timer.scheduledTimer(withTimeInterval: self.doneGrace, repeats: false) { [weak self] _ in
                self?.complete()
            }
        }
    }

    func cancel() {
        didFinish = true
        doneTimer?.invalidate()
        connectTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
    }

    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        doneTimer?.invalidate()
        connectTimer?.invalidate()
        let text = transcript
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { [weak self] in self?.onComplete(text) }
    }

    private func fail(_ failure: Failure) {
        guard !didFinish else { return }
        didFinish = true
        doneTimer?.invalidate()
        connectTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        DispatchQueue.main.async { [weak self] in self?.onFailure(failure) }
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
        guard !didFinish,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        if Self.traceRaw {
            var brief = object
            if let words = object["words"] as? [[String: Any]] {
                brief["words"] = "\(words.count) words"
                    + (words.first.map { " first=\($0)" } ?? "") + (words.last.map { " last=\($0)" } ?? "")
            }
            FileHandle.standardError.write(Data("  raw \(brief)\n".utf8))
        }

        switch type {
        case "transcript.partial":
            let start = (object["start"] as? Double) ?? 0
            let text = (object["text"] as? String) ?? ""
            record(start: start, text: text)
            let snapshot = transcript
            let words = object["words"] as? [[String: Any]]
            let segment = Segment(start: start, text: text,
                                  isFinal: (object["is_final"] as? Bool) ?? false,
                                  speechFinal: (object["speech_final"] as? Bool) ?? false,
                                  language: object["language"] as? String,
                                  firstWordAt: words?.first?["start"] as? Double,
                                  lastWordEnd: words?.last?["end"] as? Double)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFinish else { return }
                self.onText(snapshot)
                self.onSegment(segment)
            }

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
            // After audio.done a server error changes nothing about the words
            // already received — deliver them rather than throwing them away.
            if doneSent, !transcript.isEmpty { complete() } else { fail(.server(message)) }

        default:
            break
        }
    }

    private func handleTransportFailure(_ error: Error) {
        guard !didFinish else { return }

        if let response = task?.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            fail(.unauthorized)
            return
        }

        // Once we have said audio.done, the server closing the socket is the
        // normal end of the conversation and arrives here as an error. Before
        // that it is a genuine drop mid-dictation, and the caller decides
        // whether to reconnect or to keep the words that made it through.
        if doneSent {
            complete()
            return
        }
        fail(.offline(Self.describe(error)))
    }

    /// Something a person can act on, rather than a POSIX error string.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:    return "No network connection"
            case NSURLErrorTimedOut:                  return "Speech-to-text did not answer in time"
            case NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:           return "Couldn't reach speech-to-text — check your connection"
            case NSURLErrorNetworkConnectionLost:     return "Lost the connection to speech-to-text"
            case NSURLErrorSecureConnectionFailed:    return "Secure connection to speech-to-text failed"
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            // ENOTCONN (57), ECONNRESET (54), EPIPE (32), ETIMEDOUT (60)
            return "Lost the connection to speech-to-text"
        }
        return ns.localizedDescription
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectTimer?.invalidate()
            self.connectTimer = nil
            // The grace timer may already have completed the session; a late open
            // is then nothing to act on.
            guard !self.didFinish else { return }
            self.socketOpen = true
            if let started = self.connectedAt {
                Log.write("  socket open in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            }
            self.onReady()                       // flushes whatever was buffered
            if self.finishRequested { self.sendDone() }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard !didFinish else { return }
        if doneSent {
            complete()
        } else {
            fail(.server("Speech-to-text closed the connection (code \(closeCode.rawValue))"))
        }
    }
}
