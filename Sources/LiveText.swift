import Foundation

/// One stretch of speech as the speech-to-text service segments it, and its
/// translation.
struct LiveSegment: Equatable {
    let id: Int
    var original: String
    var isFinal: Bool

    /// Which socket heard it, and where its audio began on that socket's clock —
    /// what a re-transcription needs to replay it.
    var generation = 0
    var audioStart: Double?
    /// Being heard again by a socket set to the right language; its words stay
    /// until the new ones arrive.
    var beingReplaced = false
    /// Superseded by that re-hearing. Kept so ids stay indices, never shown.
    var hidden = false

    var translation = ""
    /// The translation belongs to the finished sentence, not a draft of it.
    var translationIsFinal = false
    /// Spoken in the target language already — shown as-is, never sent off.
    var sameLanguage = false
    /// ISO 639-1 code, from on-device detection or from the translator.
    var language: String?

    /// Every request gets a new revision; replies for an older one are stale.
    var revision = 0
    var lastRequestedText = ""
    var lastRequestAt: TimeInterval = -.infinity
    var draftInFlight = false
    var requestedFinal = false
    /// The exact words the current translation was completed for.
    var translatedText = ""

    init(id: Int, original: String, isFinal: Bool) {
        self.id = id
        self.original = original
        self.isFinal = isFinal
    }

    var wordCount: Int {
        original.split { $0.isWhitespace }.count
    }
}

/// A translation to ask for.
struct TranslationRequest: Equatable {
    let id: Int
    let revision: Int
    let text: String
    let isFinal: Bool
    let context: [String]
}

/// The running transcript of a live session: sentences in the order they were
/// heard.
///
/// The service is followed as a sequence, not by timestamps — measured, its
/// `start` values disagree between a chunk's drafts and its close. Interim text
/// grows the sentence being spoken; a chunk final closes it; the utterance
/// final that follows at a pause repeats every chunk since the last pause and
/// adds nothing new. Each socket (a reconnect, a rotation) is its own
/// generation, so a retiring socket can finish its sentence while a new one
/// starts the next.
struct LiveTranscript {

    enum Kind {
        case interim
        case chunkFinal
        case utteranceFinal
    }

    private(set) var segments: [LiveSegment] = []
    private var nextID = 0
    /// The sentence each socket is still in the middle of.
    private var open: [Int: Int] = [:]
    /// What each socket has closed since its last pause, joined.
    private var sincePause: [Int: String] = [:]

    /// Longest a draft translation waits after the previous one.
    var draftInterval: TimeInterval = 1.2
    /// Too few words and a draft is noise — most of it would change.
    var draftMinimumWords = 4
    /// How many earlier sentences travel with a request, for pronouns and terms.
    var contextCount = 2

    struct Update: Equatable {
        let id: Int
        let becameFinal: Bool
        let textChanged: Bool
    }

    @discardableResult
    mutating func apply(generation: Int, text: String, kind: Kind, audioStart: Double? = nil) -> Update? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .interim:
            guard !trimmed.isEmpty else { return nil }
            if let id = open[generation] {
                // Drafts of a chunk the service abandoned are replaced by the
                // next chunk's; its audio then starts where that chunk does.
                if let audioStart, let index = index(of: id), let old = segments[index].audioStart,
                   abs(audioStart - old) > 1.0 {
                    segments[index].audioStart = audioStart
                }
                return revise(id, to: trimmed, final: false, audioStart: audioStart)
            }
            return add(trimmed, final: false, generation: generation, audioStart: audioStart, keepOpen: true)

        case .chunkFinal:
            if !trimmed.isEmpty {
                let before = sincePause[generation] ?? ""
                sincePause[generation] = before.isEmpty ? trimmed : before + " " + trimmed
            }
            if let id = open.removeValue(forKey: generation) {
                // The close's word timings are the chunk's own; they win.
                if let audioStart, let index = index(of: id) { segments[index].audioStart = audioStart }
                return revise(id, to: trimmed, final: true, audioStart: audioStart)
            }
            guard !trimmed.isEmpty else { return nil }
            return add(trimmed, final: true, generation: generation, audioStart: audioStart, keepOpen: false)

        case .utteranceFinal:
            let closed = sincePause.removeValue(forKey: generation) ?? ""
            guard closed.isEmpty else {
                // A repeat of what is already closed. Only a sentence still open
                // (its own close never came) can gain words from it: the tail
                // after everything already closed.
                guard let id = open.removeValue(forKey: generation) else { return nil }
                let tail = trimmed.hasPrefix(closed)
                    ? String(trimmed.dropFirst(closed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return revise(id, to: tail, final: true)
            }
            if let id = open.removeValue(forKey: generation) { return revise(id, to: trimmed, final: true) }
            guard !trimmed.isEmpty else { return nil }
            return add(trimmed, final: true, generation: generation, audioStart: audioStart, keepOpen: false)
        }
    }

    private mutating func add(_ text: String, final: Bool, generation: Int, audioStart: Double?,
                              keepOpen: Bool) -> Update {
        let id = nextID
        nextID += 1
        var segment = LiveSegment(id: id, original: text, isFinal: final)
        segment.generation = generation
        segment.audioStart = audioStart
        segments.append(segment)
        if keepOpen { open[generation] = id }
        return Update(id: id, becameFinal: final, textChanged: true)
    }

    /// Empty text never wipes words already heard.
    private mutating func revise(_ id: Int, to text: String, final: Bool, audioStart: Double? = nil) -> Update? {
        guard let index = index(of: id) else { return nil }
        var segment = segments[index]
        if segment.audioStart == nil { segment.audioStart = audioStart }
        let changed = !text.isEmpty && text != segment.original
        if changed { segment.original = text }
        let becameFinal = final && !segment.isFinal
        if final { segment.isFinal = true }
        segments[index] = segment
        guard changed || becameFinal else { return nil }
        return Update(id: id, becameFinal: becameFinal, textChanged: changed)
    }

    /// Close the sentence a dead or retired socket left open, keeping its words.
    mutating func finaliseOpen(generation: Int) -> [Int] {
        sincePause[generation] = nil
        guard let id = open.removeValue(forKey: generation), let index = index(of: id),
              !segments[index].isFinal else { return [] }
        segments[index].isFinal = true
        return [id]
    }

    func hasOpenSegment(generation: Int) -> Bool {
        open[generation] != nil
    }

    func openSegment(generation: Int) -> Int? {
        open[generation]
    }

    var visibleSegments: [LiveSegment] {
        segments.filter { !$0.hidden }
    }

    // MARK: Re-hearing

    /// A sentence came back in a language its socket was not listening for, so
    /// its audio is about to be sent again. It and everything its socket heard
    /// after it are marked; they stay on screen until the new words arrive.
    mutating func markReplacing(from id: Int) -> [Int] {
        guard let first = index(of: id) else { return [] }
        let generation = segments[first].generation
        var marked: [Int] = []
        for index in first..<segments.count where segments[index].generation == generation && !segments[index].hidden {
            segments[index].beingReplaced = true
            marked.append(segments[index].id)
        }
        open[generation] = nil
        sincePause[generation] = nil
        return marked
    }

    var isReplacing: Bool {
        segments.contains { $0.beingReplaced }
    }

    /// The new socket has started answering: the old words give way.
    mutating func commitReplacement() {
        for index in segments.indices where segments[index].beingReplaced {
            segments[index].beingReplaced = false
            segments[index].hidden = true
        }
    }

    /// The new socket never answered: keep what there was.
    mutating func cancelReplacement() {
        for index in segments.indices where segments[index].beingReplaced {
            segments[index].beingReplaced = false
        }
    }

    func segment(_ id: Int) -> LiveSegment? {
        index(of: id).map { segments[$0] }
    }

    mutating func markSameLanguage(_ id: Int, language: String?) {
        guard let index = index(of: id) else { return }
        segments[index].sameLanguage = true
        segments[index].language = language ?? segments[index].language
        segments[index].translation = segments[index].original
        segments[index].translationIsFinal = segments[index].isFinal
        segments[index].draftInFlight = false
    }

    mutating func setLanguage(_ id: Int, _ language: String) {
        guard let index = index(of: id) else { return }
        segments[index].language = language
    }

    /// What, if anything, should be sent for translation now.
    ///
    /// A finished segment is always sent once more if its words changed since the
    /// last request, and that request supersedes any draft. An unfinished one is
    /// drafted at most once per `draftInterval`, one request at a time, so a long
    /// sentence is readable in translation before the speaker reaches its end.
    mutating func request(for id: Int, now: TimeInterval) -> TranslationRequest? {
        guard let index = index(of: id) else { return nil }
        var segment = segments[index]
        guard !segment.sameLanguage, !segment.hidden, !segment.beingReplaced else { return nil }

        if segment.isFinal {
            guard !segment.requestedFinal || segment.lastRequestedText != segment.original else { return nil }
            segment.requestedFinal = true
            // The last draft was for exactly these words: it already is the final.
            if segment.translatedText == segment.original, !segment.translation.isEmpty {
                segment.translationIsFinal = true
                segment.draftInFlight = false
                segments[index] = segment
                return nil
            }
            segment.draftInFlight = false
        } else {
            guard !segment.draftInFlight,
                  segment.wordCount >= draftMinimumWords,
                  segment.original != segment.lastRequestedText,
                  now - segment.lastRequestAt >= draftInterval
            else { return nil }
            segment.draftInFlight = true
        }

        segment.revision += 1
        segment.lastRequestedText = segment.original
        segment.lastRequestAt = now
        segments[index] = segment

        let context = segments[..<index]
            .filter { $0.isFinal && !$0.hidden }
            .suffix(contextCount)
            .map { $0.original }
        return TranslationRequest(id: id, revision: segment.revision, text: segment.original,
                                  isFinal: segment.isFinal, context: Array(context))
    }

    /// Streamed translation text for a request. Anything for a superseded
    /// revision is dropped, so a slow draft can never overwrite the final.
    @discardableResult
    mutating func receive(id: Int, revision: Int, text: String, language: String?, done: Bool) -> Bool {
        guard let index = index(of: id) else { return false }
        var segment = segments[index]
        guard segment.revision == revision, !segment.sameLanguage else { return false }
        if !text.isEmpty { segment.translation = text }
        if let language { segment.language = language }
        if done {
            segment.draftInFlight = false
            segment.translatedText = segment.lastRequestedText
            segment.translationIsFinal = segment.requestedFinal && segment.lastRequestedText == segment.original
        }
        segments[index] = segment
        return true
    }

    /// The target language changed: the last few sentences are translated again
    /// so the switch shows at once instead of on the next thing said.
    mutating func invalidateTranslations(last count: Int) -> [Int] {
        let visible = segments.indices.filter { !segments[$0].hidden }
        let chosen = visible.suffix(count)
        for index in chosen {
            segments[index].sameLanguage = false
            segments[index].requestedFinal = false
            segments[index].translatedText = ""
            segments[index].translationIsFinal = false
            segments[index].draftInFlight = false
            segments[index].lastRequestedText = ""
            segments[index].lastRequestAt = -.infinity
            segments[index].revision += 1
        }
        return chosen.map { segments[$0].id }
    }

    /// A request failed: let the next attempt go out rather than waiting on it.
    mutating func requestFailed(id: Int, revision: Int) {
        guard let index = index(of: id), segments[index].revision == revision else { return }
        segments[index].draftInFlight = false
        if segments[index].isFinal { segments[index].requestedFinal = false }
    }

    /// The whole session as plain text, original and translation paired.
    func plainText() -> String {
        visibleSegments.map { segment in
            let translation = segment.sameLanguage ? "" : segment.translation
            return translation.isEmpty ? segment.original : "\(segment.original)\n→ \(translation)"
        }.joined(separator: "\n\n")
    }

    private func index(of id: Int) -> Int? {
        // Ids are handed out in order and never removed, so they are indices.
        guard id >= 0, id < segments.count, segments[id].id == id else {
            return segments.firstIndex { $0.id == id }
        }
        return id
    }
}

/// The translator answers with the source language on its own first line, then
/// the translation. Parsed incrementally, because the reply is streamed.
enum TranslationReply {

    /// `complete` is false while the reply is still streaming: a first line
    /// without its newline may yet turn out to be the language code, so it is
    /// held back rather than flashed on screen.
    static func parse(_ raw: String, complete: Bool) -> (language: String?, text: String) {
        let body = raw.drop { $0 == "\n" || $0 == " " }
        guard let newline = body.firstIndex(of: "\n") else {
            let line = String(body).trimmingCharacters(in: .whitespaces)
            // Only a newline proves the first line was the code. A finished
            // one-word reply ("No" — also Norwegian's code) is the translation.
            if !complete, line.count <= 6 { return (nil, "") }
            return (nil, clean(line))
        }
        let first = String(body[..<newline]).trimmingCharacters(in: .whitespaces)
        guard isLanguageCode(first) else { return (nil, clean(String(body))) }
        let rest = String(body[body.index(after: newline)...])
        return (normalise(first), clean(rest))
    }

    static func isLanguageCode(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]():. "))
        return stripped.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z]{2,4})?$"#, options: .regularExpression) != nil
    }

    private static func normalise(_ code: String) -> String {
        let stripped = code.trimmingCharacters(in: CharacterSet(charactersIn: "[]():. "))
        return String(stripped.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    private static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > 1, out.hasPrefix("\""), out.hasSuffix("\"") {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }
}

/// One line of an OpenAI-style server-sent event stream.
enum StreamLine {
    case content(String)
    case done
    case ignore

    static func parse(_ line: String) -> StreamLine {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return .ignore }
        return .content(content)
    }
}
