import Foundation

// MARK: - Model

/// One thing one person said, placed on the meeting's clock.
struct Utterance: Codable, Equatable, Identifiable {
    var id: Int
    /// "you", or "s0", "s1"… for the voices the service told apart.
    var speaker: String
    var start: Double
    var end: Double
    var text: String
    /// Which speech connection heard it. Voice numbers are only meaningful within
    /// one: after a reconnect, "s0" may be a different person.
    var epoch: Int = 0
}

struct ActionItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var owner: String?
    var task: String
    var done = false
}

struct MeetingSummary: Codable, Equatable {
    var overview = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [String] = []

    var isEmpty: Bool {
        overview.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty
    }
}

enum MeetingCapture: String, Codable {
    /// A call on this Mac: your microphone is you, the Mac's audio is everyone else.
    case call
    /// People in the room: one microphone, voices told apart.
    case room

    var title: String {
        switch self {
        case .call: return "Call on this Mac"
        case .room: return "In the room"
        }
    }
}

enum SummaryState: String, Codable {
    case none, working, ready, failed
}

struct Meeting: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var endedAt: Date?
    var capture: MeetingCapture = .call
    var utterances: [Utterance] = []
    /// Names you gave the voices.
    var speakerNames: [String: String] = [:]
    /// Names the summary worked out from the conversation, not yet accepted.
    var suggestedNames: [String: String] = [:]
    var userNotes = ""
    var summary: MeetingSummary?
    var summaryState: SummaryState = .none
    var summaryError: String?
    var hasAudio = false
    /// True until you rename it yourself; the summary may then name it.
    var titleIsAutomatic = true

    init(title: String, createdAt: Date = Date(), capture: MeetingCapture = .call) {
        self.title = title
        self.createdAt = createdAt
        self.capture = capture
    }

    // Written by hand so a file from an older or newer Quill still opens.
    private enum Key: String, CodingKey {
        case id, title, createdAt, endedAt, capture, utterances, speakerNames, suggestedNames
        case userNotes, summary, summaryState, summaryError, hasAudio, titleIsAutomatic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled meeting"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        capture = try c.decodeIfPresent(MeetingCapture.self, forKey: .capture) ?? .call
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        suggestedNames = try c.decodeIfPresent([String: String].self, forKey: .suggestedNames) ?? [:]
        userNotes = try c.decodeIfPresent(String.self, forKey: .userNotes) ?? ""
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        summaryState = try c.decodeIfPresent(SummaryState.self, forKey: .summaryState) ?? .none
        summaryError = try c.decodeIfPresent(String.self, forKey: .summaryError)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        titleIsAutomatic = try c.decodeIfPresent(Bool.self, forKey: .titleIsAutomatic) ?? true
    }

    // MARK: Reading it

    var isFinished: Bool { endedAt != nil }

    /// Seconds, from the transcript or the clock, whichever says more.
    var duration: Double {
        let spoken = utterances.map(\.end).max() ?? 0
        let clock = endedAt.map { $0.timeIntervalSince(createdAt) } ?? 0
        return max(spoken, clock)
    }

    var wordCount: Int {
        utterances.reduce(0) { $0 + DictationEntry.wordCount(of: $1.text) }
    }

    /// Voices in the order they first spoke.
    var speakers: [String] {
        var seen = Set<String>()
        return utterances.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    func name(for speaker: String) -> String {
        if let custom = speakerNames[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return Self.defaultName(for: speaker)
    }

    static func defaultName(for speaker: String) -> String {
        if speaker == "you" { return "You" }
        if speaker == "others" { return "Others" }
        if speaker.hasPrefix("s"), let number = Int(speaker.dropFirst()) { return "Speaker \(number + 1)" }
        return speaker
    }

    /// "Meeting · Oct 2, 3:45 PM" — until it is given a better name.
    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return "Meeting · " + formatter.string(from: date)
    }

    /// Whether a voice still has the name it was given automatically.
    func hasCustomName(_ speaker: String) -> Bool {
        name(for: speaker) != Self.defaultName(for: speaker)
    }

    /// Consecutive remarks by one person, read as one paragraph. Two voices given
    /// the same name are one person: that is how a reconnect, which numbers the
    /// voices afresh, is put right.
    struct Turn: Identifiable, Equatable {
        var id: Int
        var speaker: String
        var start: Double
        var end: Double
        var text: String
        var epoch: Int
    }

    func turns(maxGap: Double = 8) -> [Turn] {
        var turns: [Turn] = []
        for u in utterances {
            if var last = turns.last, name(for: last.speaker) == name(for: u.speaker), u.start - last.end <= maxGap {
                last.end = max(last.end, u.end)
                last.text += " " + u.text
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(id: u.id, speaker: u.speaker, start: u.start, end: u.end, text: u.text, epoch: u.epoch))
            }
        }
        return turns
    }

    /// "[0:12] Karen: Okay, let's get started." — the transcript as the summary
    /// is asked to read it.
    func transcriptLines() -> [String] {
        turns().map { "[\(Self.clock($0.start))] \(name(for: $0.speaker)): \($0.text)" }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "42 min", "1 h 05 min", "under a minute".
    static func describe(duration seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 45 { return "under a minute" }
        if minutes < 60 { return "\(max(1, minutes)) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}

// MARK: - Markdown

enum MeetingMarkdown {

    static func render(_ meeting: Meeting, includeTranscript: Bool = true, dateStyle: DateFormatter? = nil) -> String {
        let formatter = dateStyle ?? {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        var out = "# \(meeting.title)\n\n"
        var facts = [formatter.string(from: meeting.createdAt)]
        if meeting.duration >= 1 { facts.append(Meeting.describe(duration: meeting.duration)) }
        facts.append(meeting.capture.title)
        let names = meeting.speakers.map { meeting.name(for: $0) }
        if names.count > 1 { facts.append(names.joined(separator: ", ")) }
        out += "*" + facts.joined(separator: " · ") + "*\n"

        if let summary = meeting.summary, !summary.isEmpty {
            out += "\n## Summary\n\n"
            if !summary.overview.isEmpty { out += summary.overview + "\n" }
            out += section("Key points", summary.keyPoints.map { "- \($0)" })
            out += section("Decisions", summary.decisions.map { "- \($0)" })
            out += section("Action items", summary.actionItems.map { item in
                let owner = item.owner.map { "**\($0)** — " } ?? ""
                return "- [\(item.done ? "x" : " ")] \(owner)\(item.task)"
            })
            out += section("Open questions", summary.openQuestions.map { "- \($0)" })
        }

        let notes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            out += "\n## My notes\n\n\(notes)\n"
        }

        if includeTranscript, !meeting.utterances.isEmpty {
            out += "\n## Transcript\n\n"
            out += meeting.turns().map { "**\(meeting.name(for: $0.speaker))** (\(Meeting.clock($0.start)))  \n\($0.text)" }
                .joined(separator: "\n\n")
            out += "\n"
        }
        return out
    }

    private static func section(_ title: String, _ lines: [String]) -> String {
        lines.isEmpty ? "" : "\n### \(title)\n\n" + lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Store

/// Meetings on disk: a folder each, with `meeting.json` and, if you chose to
/// keep it, `audio.m4a`. Readable by you alone.
final class MeetingStore {

    let directory: URL

    init(directory: URL) {
        self.directory = directory
        AppSupport.ensure(directory)
    }

    static func defaultDirectory() -> URL {
        AppSupport.directory.appendingPathComponent("Meetings", isDirectory: true)
    }

    func folder(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("audio.m4a")
    }

    private func fileURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("meeting.json")
    }

    @discardableResult
    func save(_ meeting: Meeting) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meeting) else { return false }
        AppSupport.write(data, to: fileURL(for: meeting.id))
        return true
    }

    /// Newest first. A file that will not read is left alone and skipped.
    func all() -> [Meeting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Meeting? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    func hasAudio(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: id).path)
    }

    /// A meeting that never got to say it had ended — Quill quit or crashed while
    /// it was recording. Keep what was heard, and close it.
    @discardableResult
    func closeInterrupted() -> [Meeting] {
        var closed: [Meeting] = []
        for var meeting in all() where meeting.endedAt == nil {
            meeting.endedAt = meeting.createdAt.addingTimeInterval(meeting.utterances.map(\.end).max() ?? 0)
            if meeting.summaryState == .working { meeting.summaryState = .none }
            meeting.hasAudio = hasAudio(meeting.id)
            save(meeting)
            closed.append(meeting)
        }
        return closed
    }
}
