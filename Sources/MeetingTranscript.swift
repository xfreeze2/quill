import Foundation

// What the speech service sends while a conversation is going on, turned into who
// said what and when.
//
// Measured against the live service with two voices taking turns:
//  • Words carry their own punctuation ("started.") and a `speaker` index — but
//    only on the message that closes a pause. The chunks inside it name nobody,
//    or guess; the closing message names the voices correctly. So the transcript
//    is built from closing messages, and chunks are only shown as a provisional
//    live line.
//  • Silence produces empty chunks.
//  • Times are on the connection's own clock, so each connection gets a base.

struct SpokenWord: Equatable {
    var text: String
    var start: Double
    var end: Double
    var speaker: Int?
}

enum StreamKind {
    case interim
    case chunkFinal
    case utteranceFinal
}

/// A finished remark, on the meeting's clock.
struct Fragment: Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
    var epoch: Int
}

/// What is being said right now, not yet final.
struct LiveLine: Equatable {
    var speaker: String
    var text: String
}

/// Follows one connection to the speech service.
final class LaneAssembler {

    enum Voices {
        /// Everything on this connection is one known person ("you").
        case one(String)
        /// The service tells the voices apart.
        case several
    }

    let voices: Voices
    /// Seconds into the meeting at which this connection's clock began.
    let base: Double
    let epoch: Int
    /// Voice index → the id it goes by in the meeting. Indices restart on every
    /// connection, so whoever owns the lane hands out ids that never collide.
    var voiceName: (Int) -> String = { "s\($0)" }

    private var pendingChunks: [String] = []
    private var pendingWords: [SpokenWord] = []
    private var draft = ""
    private var lastSpeaker: Int?
    private var lastEnd: Double

    init(voices: Voices, base: Double, epoch: Int) {
        self.voices = voices
        self.base = base
        self.epoch = epoch
        self.lastEnd = base
    }

    /// Fragments that became final with this message.
    func apply(text: String, words: [SpokenWord], kind: StreamKind) -> [Fragment] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .interim:
            // Silence arrives as empty drafts; they never wipe what is showing.
            if !clean.isEmpty { draft = clean }
            return []

        case .chunkFinal:
            draft = ""
            if !clean.isEmpty {
                pendingChunks.append(clean)
                pendingWords += words
                noteSpeaker(in: words)
            }
            return []

        case .utteranceFinal:
            draft = ""
            guard !clean.isEmpty else { return flush() }
            let held = pendingChunks.joined(separator: " ")
            var finalText = clean
            var finalWords = words
            // The closing message normally repeats every chunk since the pause.
            // If it somehow holds less than the chunks did, keep the fuller one.
            if !held.isEmpty, !Self.contains(clean, held), held.count > clean.count {
                finalText = held
                finalWords = pendingWords
            }
            pendingChunks = []
            pendingWords = []
            noteSpeaker(in: finalWords)
            return fragments(text: finalText, words: finalWords)
        }
    }

    /// The connection is ending: whatever was heard but not yet closed is kept.
    func flush() -> [Fragment] {
        draft = ""
        guard !pendingChunks.isEmpty else { return [] }
        let text = pendingChunks.joined(separator: " ")
        let words = pendingWords
        pendingChunks = []
        pendingWords = []
        return fragments(text: text, words: words)
    }

    /// The words being spoken now, for the live view.
    var live: LiveLine? {
        let text = (pendingChunks + [draft]).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return LiveLine(speaker: speakerID(provisional()), text: text)
    }

    // MARK: Building fragments

    private func fragments(text: String, words: [SpokenWord]) -> [Fragment] {
        guard !words.isEmpty, Self.sameWords(words.map(\.text).joined(separator: " "), text) else {
            // No usable word detail: one remark, on the best guess of who.
            let speaker = speakerID(provisional(words))
            let start = words.first.map { base + $0.start } ?? lastEnd
            let end = words.last.map { base + $0.end } ?? start + max(1, Double(text.split(separator: " ").count) * 0.4)
            lastEnd = end
            return [Fragment(speaker: speaker, start: start, end: end, text: text, epoch: epoch)]
        }

        var runs: [(speaker: Int, words: [SpokenWord])] = []
        var current = firstKnownSpeaker(in: words) ?? lastSpeaker ?? 0
        for word in words {
            if let speaker = word.speaker { current = speaker }
            if let last = runs.last, last.speaker == current {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append((current, [word]))
            }
        }
        runs = Self.smoothed(runs)

        return runs.map { run in
            let start = base + run.words[0].start
            let end = base + run.words[run.words.count - 1].end
            lastEnd = max(lastEnd, end)
            return Fragment(speaker: speakerID(run.speaker), start: start, end: end,
                            text: run.words.map(\.text).joined(separator: " "), epoch: epoch)
        }
    }

    /// A single word labelled as someone else, between two stretches of one
    /// voice, is the service wavering, not a person interrupting.
    static func smoothed(_ runs: [(speaker: Int, words: [SpokenWord])]) -> [(speaker: Int, words: [SpokenWord])] {
        var runs = runs
        var index = 1
        while index < runs.count - 1 {
            if runs[index].words.count == 1, runs[index - 1].speaker == runs[index + 1].speaker {
                runs[index - 1].words += runs[index].words + runs[index + 1].words
                runs.removeSubrange(index...(index + 1))
            } else {
                index += 1
            }
        }
        return runs
    }

    private func firstKnownSpeaker(in words: [SpokenWord]) -> Int? {
        words.compactMap(\.speaker).first
    }

    private func noteSpeaker(in words: [SpokenWord]) {
        if let speaker = words.compactMap(\.speaker).last { lastSpeaker = speaker }
    }

    /// Who is probably speaking, before the closing message says.
    private func provisional(_ words: [SpokenWord]? = nil) -> Int {
        let heard = (words ?? pendingWords).compactMap(\.speaker)
        return heard.first ?? lastSpeaker ?? 0
    }

    private func speakerID(_ index: Int) -> String {
        switch voices {
        case .one(let id): return id
        case .several:     return voiceName(index)
        }
    }

    // MARK: Text comparison

    static func normalised(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
    }

    static func sameWords(_ a: String, _ b: String) -> Bool {
        normalised(a) == normalised(b)
    }

    /// Whether `inner` appears inside `outer`, ignoring punctuation and case.
    static func contains(_ outer: String, _ inner: String) -> Bool {
        let o = normalised(outer).joined(separator: " ")
        let i = normalised(inner).joined(separator: " ")
        return !i.isEmpty && o.contains(i)
    }
}

// MARK: - Echo

enum Echo {

    /// Without headphones the microphone hears the other side of the call from the
    /// speakers, so the same words arrive twice: once from the call, once as if
    /// you had said them. True if two remarks are, for this purpose, one.
    static func isEcho(_ a: String, _ b: String) -> Bool {
        let x = LaneAssembler.normalised(a)
        let y = LaneAssembler.normalised(b)
        guard min(x.count, y.count) >= 4 else { return false }
        let (shorter, longer) = x.count <= y.count ? (x, y) : (y, x)
        var available: [String: Int] = [:]
        for word in longer { available[word, default: 0] += 1 }
        var shared = 0
        for word in shorter where (available[word] ?? 0) > 0 {
            available[word]! -= 1
            shared += 1
        }
        return Double(shared) / Double(shorter.count) >= 0.75
    }
}

// MARK: - The whole meeting

/// Everything said so far, in time order, from every connection.
final class MeetingTranscript {

    private(set) var utterances: [Utterance] = []
    private var nextID = 0

    /// Remarks this close in time, one yours and one not, can be the same sound.
    var echoWindow = 3.0
    private let youSpeaker = "you"

    init(existing: [Utterance] = []) {
        utterances = existing.sorted { $0.start < $1.start }
        nextID = (existing.map(\.id).max() ?? -1) + 1
    }

    /// Returns true if the transcript changed.
    @discardableResult
    func add(_ fragments: [Fragment]) -> Bool {
        var changed = false
        for fragment in fragments {
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if fragment.speaker == youSpeaker {
                if utterances.contains(where: { $0.speaker != youSpeaker && overlaps($0, fragment) && Echo.isEcho($0.text, text) }) {
                    continue
                }
            } else {
                let before = utterances.count
                utterances.removeAll { $0.speaker == youSpeaker && overlaps($0, fragment) && Echo.isEcho($0.text, text) }
                if utterances.count != before { changed = true }
            }

            let utterance = Utterance(id: nextID, speaker: fragment.speaker, start: fragment.start,
                                      end: max(fragment.end, fragment.start), text: text, epoch: fragment.epoch)
            nextID += 1
            let position = utterances.lastIndex { $0.start <= utterance.start }.map { $0 + 1 } ?? 0
            utterances.insert(utterance, at: position)
            changed = true
        }
        return changed
    }

    private func overlaps(_ utterance: Utterance, _ fragment: Fragment) -> Bool {
        utterance.start <= fragment.end + echoWindow && utterance.end >= fragment.start - echoWindow
    }
}
