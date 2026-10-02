import SwiftUI

/// Who spoke when, as lanes: a row per person with a mark wherever they were
/// talking, the topics along the top, and — if the sound was kept — a playhead
/// to listen along. Click anywhere to go to that moment.
struct ConversationMap: View {
    let timeline: MeetingTimeline
    @ObservedObject var player: MeetingPlayer
    var onRename: (String, String) -> Void
    var onJump: (Double) -> Void

    private let laneHeight: CGFloat = 26
    private let markerRow: CGFloat = 20
    private let labelWidth: CGFloat = 112
    private let shareWidth: CGFloat = 34

    @State private var renaming: String?
    @State private var draft = ""

    private var chartHeight: CGFloat { markerRow + CGFloat(timeline.lanes.count) * laneHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel(text: "Conversation")
                Spacer()
                if player.isReady { playback }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: markerRow)
                    ForEach(timeline.lanes) { lane in label(lane) }
                }
                .frame(width: labelWidth, alignment: .leading)

                chart

                VStack(alignment: .trailing, spacing: 0) {
                    Color.clear.frame(height: markerRow)
                    ForEach(timeline.lanes) { lane in
                        Text(MeetingTimeline.percent(lane.share))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(height: laneHeight)
                    }
                }
                .frame(width: shareWidth, alignment: .trailing)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.sunken))
    }

    // MARK: Pieces

    private var playback: some View {
        HStack(spacing: 8) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Listen")
            Text("\(Meeting.clock(player.position)) / \(Meeting.clock(player.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : (player.rate == 1.5 ? "1.5×" : "2×"))
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle())
            .help("Playback speed")
        }
    }

    private func label(_ lane: MeetingTimeline.Lane) -> some View {
        Button {
            draft = lane.name.hasPrefix("Speaker ") ? "" : lane.name
            renaming = lane.id
        } label: {
            HStack(spacing: 7) {
                SpeakerAvatar(id: lane.id, name: lane.name, size: 18)
                Text(lane.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)
            }
            .frame(height: laneHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename")
        .popover(isPresented: Binding(get: { renaming == lane.id }, set: { if !$0 { renaming = nil } }), arrowEdge: .bottom) {
            RenameVoice(defaultName: Meeting.defaultName(for: lane.id), draft: $draft) { final in
                onRename(lane.id, final)
                renaming = nil
            }
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(1, timeline.duration)
            ZStack(alignment: .topLeading) {
                ForEach(Array(timeline.lanes.enumerated()), id: \.element.id) { index, lane in
                    let y = markerRow + CGFloat(index) * laneHeight + laneHeight / 2
                    Capsule().fill(Palette.hairline).frame(width: width, height: 2).position(x: width / 2, y: y)
                    LaneBars(segments: lane.segments, duration: duration)
                        .fill(Palette.voice(lane.id))
                        .frame(width: width, height: 10)
                        .position(x: width / 2, y: y)
                }

                ForEach(Array(timeline.chapters.enumerated()), id: \.element.id) { index, chapter in
                    let x = CGFloat(min(1, chapter.start / duration)) * width
                    Rectangle().fill(Palette.hairline).frame(width: 1, height: chartHeight - markerRow + 2)
                        .position(x: x, y: markerRow + (chartHeight - markerRow) / 2)
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Palette.accent))
                        .position(x: min(max(x, 7), width - 7), y: 8)
                        .help(chapter.title)
                }

                if player.isReady, player.isPlaying || player.position > 0.2 {
                    Rectangle().fill(Color.primary.opacity(0.75)).frame(width: 1.5, height: chartHeight - 4)
                        .position(x: CGFloat(min(1, player.position / duration)) * width, y: chartHeight / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let fraction = Double(min(max(value.location.x / max(1, width), 0), 1))
                if value.location.y < markerRow, let near = nearestChapter(to: value.location.x, width: width, duration: duration) {
                    onJump(near.start)
                } else {
                    onJump(fraction * duration)
                }
            })
        }
        .frame(height: chartHeight)
    }

    private func nearestChapter(to x: CGFloat, width: CGFloat, duration: Double) -> Chapter? {
        timeline.chapters
            .map { ($0, abs(CGFloat($0.start / duration) * width - x)) }
            .filter { $0.1 < 12 }
            .min { $0.1 < $1.1 }?.0
    }
}

/// The marks of one person's talking, as a single shape.
private struct LaneBars: Shape {
    var segments: [MeetingTimeline.Segment]
    var duration: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in segments {
            let x = CGFloat(segment.start / duration) * rect.width
            let w = max(3, CGFloat((segment.end - segment.start) / duration) * rect.width)
            path.addRoundedRect(in: CGRect(x: x, y: 0, width: min(w, rect.width - x), height: rect.height),
                                cornerSize: CGSize(width: 3, height: 3))
        }
        return path
    }
}

/// Giving a voice a real name.
struct RenameVoice: View {
    var defaultName: String
    @Binding var draft: String
    var done: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?").font(.system(size: 13, weight: .semibold))
            Text("Every remark by this voice takes the name. Give two voices the same name to join them.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(defaultName, text: $draft, onCommit: { done(draft) })
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Reset") { done("") }.buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Done") { done(draft) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// During a meeting: who is in it, who is talking right now, and how the talking
/// is shared so far.
struct LiveSpeakers: View {
    let meeting: Meeting
    /// The voices speaking at this moment.
    var speaking: [String]

    private struct Person: Identifiable {
        var id: String
        var name: String
        var share: Double
    }

    private var people: [Person] {
        var out = MeetingTimeline(meeting).lanes.map { Person(id: $0.id, name: $0.name, share: $0.share) }
        for voice in speaking where !out.contains(where: { $0.name == meeting.name(for: voice) }) {
            out.append(Person(id: voice, name: meeting.name(for: voice), share: 0))
        }
        return out
    }

    var body: some View {
        let people = self.people
        let activeNames = Set(speaking.map { meeting.name(for: $0) })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                ForEach(people) { person in
                    let active = activeNames.contains(person.name)
                    HStack(spacing: 8) {
                        SpeakerAvatar(id: person.id, name: person.name, size: 24, ring: active)
                            .padding(3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(person.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(active ? "speaking" : MeetingTimeline.percent(person.share))
                                .font(.system(size: 11.5))
                                .foregroundColor(active ? Palette.voice(person.id) : .secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if people.filter({ $0.share > 0 }).count > 1 {
                GeometryReader { geo in
                    let shown = people.filter { $0.share > 0 }
                    HStack(spacing: 2) {
                        ForEach(shown) { person in
                            Capsule().fill(Palette.voice(person.id))
                                .frame(width: max(4, (geo.size.width - CGFloat(shown.count - 1) * 2) * CGFloat(person.share)))
                        }
                    }
                }
                .frame(height: 5)
            }
        }
    }
}
