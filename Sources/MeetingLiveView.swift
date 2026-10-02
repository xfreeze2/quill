import SwiftUI

/// A meeting in progress: the words arriving, your own notes beside them, and
/// the way to stop.
struct LiveMeetingView: View {
    @ObservedObject var model: AppModel
    let session: MeetingSession
    @State private var title: String
    @State private var notes: String
    @State private var follow = true

    init(model: AppModel, session: MeetingSession) {
        self.model = model
        self.session = session
        _title = State(initialValue: session.meeting.title)
        _notes = State(initialValue: session.meeting.userNotes)
    }

    private var meeting: Meeting { session.meeting }
    private var stopping: Bool { session.phase == .stopping }

    var body: some View {
        let _ = model.tick
        VStack(alignment: .leading, spacing: 16) {
            header
            ForEach(session.notices.keys.sorted(), id: \.self) { key in
                if let text = session.notices[key], !text.isEmpty { Notice(text: text) }
            }
            HStack(alignment: .top, spacing: 16) {
                transcript
                notesCard.frame(width: 290)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 26)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                if stopping { ProgressView().controlSize(.small) } else { PulsingDot() }
                TextField("Meeting title", text: $title, onCommit: { model.rename(meeting.id, to: title) })
                    .textFieldStyle(.plain)
                    .font(.display(27))
                Spacer(minLength: 12)
                stopButton
            }
            HStack(spacing: 10) {
                Chip(text: Meeting.clock(session.elapsed), symbol: "clock", tint: Palette.record)
                Chip(text: meeting.capture.title, symbol: meeting.capture == .call ? "video" : "person.3")
                if session.keepsAudio { Chip(text: "Recording sound", symbol: "record.circle", tint: Palette.record) }
                Spacer(minLength: 0)
                meters
            }
        }
    }

    private var stopButton: some View {
        Button { model.stopMeeting() } label: {
            HStack(spacing: 8) {
                if stopping { ProgressView().controlSize(.small) } else { Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)) }
                Text(stopping ? "Finishing…" : "Stop & summarise")
            }
        }
        .buttonStyle(PrimaryButtonStyle(tint: Palette.record))
        .disabled(stopping)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var meters: some View {
        HStack(spacing: 16) {
            meter(label: meeting.capture == .call ? "You" : "Room", level: session.micLevel)
            if meeting.capture == .call, session.notices["call"] == nil || session.systemLevel > 0 {
                meter(label: "Others", level: session.systemLevel)
            }
        }
    }

    private func meter(label: String, level: Float) -> some View {
        HStack(spacing: 7) {
            TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                LevelBars(level: label == "Others" ? session.systemLevel : session.micLevel)
            }
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let turns = meeting.turns()
        let live = session.live
        let signature = "\(turns.count)-\(turns.last?.text.count ?? 0)-\(live.map(\.text.count))"
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionLabel(text: "Transcript")
                    Spacer()
                    Button { follow.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: follow ? "arrow.down.to.line" : "pause")
                            Text(follow ? "Following" : "Paused")
                        }
                    }
                    .buttonStyle(GhostButtonStyle(tint: follow ? Palette.accentText : nil))
                    .help("Scroll along as people speak")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)

                if turns.isEmpty && live.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        LevelBars(level: max(session.micLevel, session.systemLevel))
                        Text(stopping ? "Finishing up…" : "Listening…").font(.display(18))
                        Text("Start talking, and the words appear here with who said them.")
                            .font(.system(size: 12.5)).foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(turns) { turn in
                                    TurnRow(meeting: meeting, turn: turn)
                                        .id(turn.id)
                                }
                                ForEach(Array(live.enumerated()), id: \.offset) { _, line in
                                    LiveTurnRow(meeting: meeting, line: line)
                                }
                                Color.clear.frame(height: 1).id("end")
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                        .onChange(of: signature) { _ in
                            guard follow else { return }
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Notes

    private var notesCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "My notes")
                    .padding(.top, 12)
                Text("Jot what matters. It's kept with the meeting and used in the summary.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NotesEditor(text: $notes, placeholder: "Decisions, names, things to follow up…",
                            onChange: { model.setNotes(meeting.id, $0) })
                    .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
    }
}
