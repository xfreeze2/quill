import SwiftUI

/// A meeting in progress. Quill is listening: it tells you who is talking,
/// writes the notes as the conversation moves, and leaves you a place of your own.
struct LiveMeetingView: View {
    @ObservedObject var model: AppModel
    let session: MeetingSession
    @State private var title: String
    @State private var notes: String
    @State private var showTranscript = false
    @State private var follow = true
    @FocusState private var titleFocused: Bool

    init(model: AppModel, session: MeetingSession) {
        self.model = model
        self.session = session
        _title = State(initialValue: session.meeting.title)
        _notes = State(initialValue: session.meeting.userNotes)
    }

    private var meeting: Meeting { session.meeting }
    private var stopping: Bool { session.phase == .stopping }
    private var notesAreOn: Bool { Defaults.bool(Defaults.meetingLiveNotes) }

    var body: some View {
        let _ = model.tick
        VStack(alignment: .leading, spacing: 18) {
            header
            ForEach(session.notices.keys.sorted(), id: \.self) { key in
                if let text = session.notices[key], !text.isEmpty { Notice(text: text) }
            }
            LiveSpeakers(meeting: meeting, speaking: session.live.map(\.speaker))
            GeometryReader { geo in
                if geo.size.width >= 760 {
                    HStack(alignment: .top, spacing: 32) {
                        main
                        yourNotes.frame(width: 270)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        main
                        yourNotes.frame(height: 124)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, Layout.titlebar - 4)
        .padding(.bottom, 26)
        .background(PageGround(tint: .rose))
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { title = meeting.title } else if trimmed != meeting.title { model.rename(meeting.id, to: trimmed) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Meeting title", text: $title, onCommit: commitTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .bold))
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { if !$0 { commitTitle() } }
                stopButton
            }
            HStack(spacing: 8) {
                if stopping { ProgressView().controlSize(.small) } else { PulsingDot() }
                Text(Meeting.clock(session.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(stopping ? .secondary : Palette.record)
                Text(detailLine).font(.system(size: 13)).foregroundColor(.secondary)
                Spacer(minLength: 0)
                meters
            }
        }
    }

    private var detailLine: String {
        var parts = ["·", meeting.capture.title]
        if session.keepsAudio { parts.append("· Recording sound") }
        return parts.joined(separator: " ")
    }

    private var stopButton: some View {
        Button { model.stopMeeting() } label: {
            HStack(spacing: 7) {
                if stopping { ProgressView().controlSize(.small) } else { Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)) }
                Text(stopping ? "Finishing…" : "Stop")
            }
        }
        .buttonStyle(PrimaryButtonStyle(tint: Palette.record))
        .disabled(stopping)
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Stop and write up the notes  ⌘↩")
    }

    private var meters: some View {
        HStack(spacing: 14) {
            meter(label: meeting.capture == .call ? "You" : "Room", level: session.micLevel)
            if meeting.capture == .call, session.notices["call"] == nil || session.systemLevel > 0 {
                meter(label: "Others", level: session.systemLevel)
            }
        }
    }

    private func meter(label: String, level: Float) -> some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                LevelBars(level: label == "Others" ? session.systemLevel : session.micLevel)
            }
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    // MARK: Main pane

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TabStrip(tabs: [false, true], selection: $showTranscript) { $0 ? "Transcript" : "Notes" }
                    .frame(maxWidth: 190)
                Spacer()
                if showTranscript {
                    Button { follow.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: follow ? "arrow.down.to.line" : "pause")
                            Text(follow ? "Following" : "Paused")
                        }
                    }
                    .buttonStyle(GhostButtonStyle(tint: follow ? Palette.accentText : nil))
                    .help("Scroll along as people speak")
                }
            }
            Panel(padding: 0) {
                if showTranscript { transcript } else { liveNotes }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 10)
            nowSaying
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveNotes: some View {
        let items = meeting.liveNotes
        return ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty {
                    VStack(spacing: 8) {
                        LevelBars(level: max(session.micLevel, session.systemLevel))
                        Text(stopping ? "Finishing up…" : "Listening…").font(.system(size: 15, weight: .semibold))
                        Text(notesAreOn
                             ? "Notes appear here as the conversation moves."
                             : "Live notes are off. The transcript is still being kept.")
                            .font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(Meeting.clock(note.time)).font(.system(size: 11.5).monospacedDigit())
                                    .foregroundColor(.secondary).frame(width: 38, alignment: .trailing)
                                Text(note.text).font(.system(size: 15)).lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(note.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                    .animation(.easeOut(duration: 0.3), value: items.count)
                }
            }
            .onChange(of: items.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var transcript: some View {
        let turns = meeting.turns()
        let live = session.live
        let signature = "\(turns.count)-\(turns.last?.text.count ?? 0)-\(live.map(\.text.count))"
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(turns) { turn in
                        TurnRow(meeting: meeting, turn: turn).id(turn.id)
                    }
                    ForEach(Array(live.enumerated()), id: \.offset) { _, line in
                        LiveTurnRow(meeting: meeting, line: line)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
            }
            .onChange(of: signature) { _ in
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// The words being said this moment, so you can see it is hearing.
    @ViewBuilder private var nowSaying: some View {
        if !showTranscript, let line = session.live.last {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.name(for: line.speaker))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.voice(line.speaker))
                Text(line.text).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .padding(.top, 10)
        }
    }

    // MARK: Your notes

    private var yourNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Your notes")
                .padding(.top, 4)
            NotesEditor(text: $notes, placeholder: "Jot anything down. It's kept with the meeting.",
                        onChange: { model.setNotes(meeting.id, $0) })
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        }
        .frame(maxHeight: .infinity)
    }
}
