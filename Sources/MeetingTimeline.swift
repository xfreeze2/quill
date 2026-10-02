import Foundation

/// Who spoke when, drawn as lanes: one per person, a mark wherever they were
/// talking. Two voices given the same name are one person, as in the transcript.
struct MeetingTimeline: Equatable {

    struct Segment: Equatable {
        var start: Double
        var end: Double
    }

    struct Lane: Equatable, Identifiable {
        /// The first voice that carried this name — what the colour comes from.
        var id: String
        var name: String
        var segments: [Segment]
        var seconds: Double
        var words: Int
        /// This person's part of all the talking, 0…1.
        var share: Double
    }

    var lanes: [Lane]
    var duration: Double
    var chapters: [Chapter]

    var isEmpty: Bool { lanes.isEmpty }

    /// Remarks closer together than `joinGap` seconds read as one stretch of talking.
    init(_ meeting: Meeting, joinGap: Double = 1.5) {
        var order: [String] = []
        var ids: [String: String] = [:]
        var segments: [String: [Segment]] = [:]
        var words: [String: Int] = [:]

        for utterance in meeting.utterances where utterance.end > utterance.start || !utterance.text.isEmpty {
            let name = meeting.name(for: utterance.speaker)
            if ids[name] == nil {
                ids[name] = utterance.speaker
                order.append(name)
            }
            segments[name, default: []].append(Segment(start: utterance.start, end: max(utterance.end, utterance.start + 0.4)))
            words[name, default: 0] += DictationEntry.wordCount(of: utterance.text)
        }

        var built: [Lane] = order.map { name in
            let merged = Self.join(segments[name] ?? [], gap: joinGap)
            let seconds = merged.reduce(0) { $0 + ($1.end - $1.start) }
            return Lane(id: ids[name] ?? name, name: name, segments: merged, seconds: seconds, words: words[name] ?? 0, share: 0)
        }
        let total = built.reduce(0) { $0 + $1.seconds }
        if total > 0 {
            for index in built.indices { built[index].share = built[index].seconds / total }
        }
        lanes = built
        duration = max(meeting.duration, built.flatMap(\.segments).map(\.end).max() ?? 0)
        chapters = meeting.chapters
    }

    private static func join(_ segments: [Segment], gap: Double) -> [Segment] {
        var out: [Segment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, segment.start - last.end <= gap {
                last.end = max(last.end, segment.end)
                out[out.count - 1] = last
            } else {
                out.append(segment)
            }
        }
        return out
    }

    /// The lane talking at `time`, if anyone was.
    func speaker(at time: Double) -> Lane? {
        lanes.first { lane in lane.segments.contains { time >= $0.start && time <= $0.end } }
    }

    /// "31%", or "<1%" for someone who barely spoke.
    static func percent(_ share: Double) -> String {
        let value = share * 100
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }
}
