import Foundation

/// One thing to do, taken from a meeting's summary.
struct OpenTask: Identifiable, Equatable {
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var item: ActionItem
    var id: UUID { item.id }
}

enum Tasks {

    /// Every action item from every summary, newest meeting first, in the order the
    /// summary gave them.
    static func all(in meetings: [Meeting]) -> [OpenTask] {
        meetings
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap { meeting in
                (meeting.summary?.actionItems ?? []).map {
                    OpenTask(meetingID: meeting.id, meetingTitle: meeting.title, meetingDate: meeting.createdAt, item: $0)
                }
            }
    }

    static func open(in meetings: [Meeting]) -> [OpenTask] { all(in: meetings).filter { !$0.item.done } }
    static func done(in meetings: [Meeting]) -> [OpenTask] { all(in: meetings).filter { $0.item.done } }
}

/// What a search turns up: a meeting, something you dictated, or a task.
struct SearchHit: Identifiable, Equatable {
    enum Kind: Equatable { case meeting, dictation, task }

    var id: String
    var kind: Kind
    var title: String
    /// The words around the match.
    var detail: String
    var date: Date
    var meetingID: UUID?
    var entryID: UUID?
    var score: Int
}

/// One search over everything Quill keeps. Every word you type has to be found,
/// though not in the same place; a title counts for more than the transcript.
enum AppSearch {

    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func hits(for query: String, meetings: [Meeting], entries: [DictationEntry], limit: Int = 30) -> [SearchHit] {
        let terms = terms(query)
        guard !terms.isEmpty else { return [] }
        var out: [SearchHit] = []

        for meeting in meetings {
            let overview = meeting.summary?.overview ?? ""
            let spoken = meeting.utterances.map(\.text).joined(separator: " ")
            let notes = meeting.userNotes
            let live = meeting.liveNotes.map(\.text).joined(separator: " ")
            let topics = meeting.chapters.map(\.title).joined(separator: " ")
            let people = meeting.speakerNames.values.joined(separator: " ")
            let fields: [(text: String, weight: Int)] = [
                (meeting.title, 10), (topics, 5), (people, 5), (overview, 4), (live, 3), (notes, 3), (spoken, 2),
            ]
            for item in meeting.summary?.actionItems ?? [] {
                let text = item.task + " " + (item.owner ?? "")
                guard terms.allSatisfy({ text.lowercased().contains($0) }) else { continue }
                out.append(SearchHit(id: "t-\(item.id)", kind: .task, title: item.task,
                                     detail: [item.owner, meeting.title].compactMap { $0 }.joined(separator: " · "),
                                     date: meeting.createdAt, meetingID: meeting.id, entryID: nil, score: 6 + terms.count))
            }

            let all = fields.map { $0.text.lowercased() }.joined(separator: "\n")
            guard terms.allSatisfy({ all.contains($0) }) else { continue }

            var score = 0
            for term in terms {
                for field in fields where field.text.lowercased().contains(term) { score += field.weight }
            }
            let best = fields.dropFirst().first { field in terms.contains { field.text.lowercased().contains($0) } }
            let detail = best.map { snippet(in: $0.text, terms: terms) }
                ?? (overview.isEmpty ? "" : snippet(in: overview, terms: terms))
            out.append(SearchHit(id: "m-\(meeting.id)", kind: .meeting, title: meeting.title, detail: detail,
                                 date: meeting.createdAt, meetingID: meeting.id, entryID: nil, score: score))
        }

        for entry in entries {
            let text = (entry.text + " " + (entry.app ?? "")).lowercased()
            guard terms.allSatisfy({ text.contains($0) }) else { continue }
            out.append(SearchHit(id: "d-\(entry.id)", kind: .dictation, title: snippet(in: entry.text, terms: terms, width: 110),
                                 detail: entry.app ?? "", date: entry.date, meetingID: nil, entryID: entry.id, score: 2 * terms.count))
        }

        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }.prefix(max(1, limit)))
    }

    /// A short stretch of `text` around the first place a term appears.
    static func snippet(in text: String, terms: [String], width: Int = 100) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        guard flat.count > width else { return flat }
        let lower = flat.lowercased()
        let first = terms.compactMap { lower.range(of: $0)?.lowerBound }.min()
        let offset = first.map { lower.distance(from: lower.startIndex, to: $0) } ?? 0
        let begin = max(0, min(offset - width / 3, flat.count - width))
        let start = flat.index(flat.startIndex, offsetBy: begin)
        let end = flat.index(start, offsetBy: min(width, flat.count - begin))
        return (begin > 0 ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
    }
}
