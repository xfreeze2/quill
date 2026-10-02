import SwiftUI
import UniformTypeIdentifiers

/// A finished meeting: the summary, the transcript, and your own notes.
struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", transcript = "Transcript", notes = "My notes"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary
    @State private var title = ""
    @State private var transcriptQuery = ""
    @State private var notes = ""
    @State private var confirmDelete = false
    @State private var notesSave: DispatchWorkItem?
    @FocusState private var titleFocused: Bool
    @StateObject private var player: MeetingPlayer

    init(model: AppModel, meeting: Meeting, tab: Tab = .summary) {
        self.model = model
        self.meeting = meeting
        _tab = State(initialValue: tab)
        _player = StateObject(wrappedValue: MeetingPlayer(url: meeting.hasAudio ? model.store.audioURL(for: meeting.id) : nil))
    }

    private var working: Bool { model.summarizing.contains(meeting.id) || meeting.summaryState == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 22)

            if meeting.hasAudio, player.isReady {
                PlayerBar(player: player)
                    .padding(.horizontal, 36)
                    .padding(.top, 14)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.horizontal, 36)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case .summary:    summary
                case .transcript: transcript
                case .notes:      notesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            title = meeting.title
            notes = meeting.userNotes
            if meeting.summary == nil, meeting.summaryState == .none, meeting.wordCount < 8 { tab = .transcript }
        }
        .onDisappear { player.stop() }
        .onChange(of: meeting.title) { title = $0 }
        .alert("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteMeeting(meeting.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript, notes and any recording are removed from this Mac. This can't be undone.")
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { title = meeting.title } else if trimmed != meeting.title { model.rename(meeting.id, to: trimmed) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Meeting title", text: $title, onCommit: commitTitle)
                    .textFieldStyle(.plain)
                    .font(.display(28))
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { if !$0 { commitTitle() } }
                Spacer(minLength: 10)
                copyMenu
                Button { export() } label: {
                    HStack(spacing: 6) { Image(systemName: "square.and.arrow.up"); Text("Export") }
                }
                .buttonStyle(SecondaryButtonStyle())
                moreMenu
            }
            HStack(spacing: 8) {
                Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary)
                if meeting.hasAudio { Chip(text: "Sound kept", symbol: "record.circle") }
            }
            if !meeting.speakers.isEmpty {
                HStack(spacing: 7) {
                    ForEach(meeting.speakers, id: \.self) { voice in
                        HStack(spacing: 6) {
                            SpeakerAvatar(id: voice, name: meeting.name(for: voice), size: 20)
                            Text(meeting.name(for: voice)).font(.system(size: 12, weight: .medium))
                        }
                        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.sunken))
                    }
                }
            }
        }
    }

    private var subtitle: String {
        var parts = [Formatting.shortDate(meeting.createdAt)]
        if meeting.duration >= 1 { parts.append(Meeting.describe(duration: meeting.duration)) }
        parts.append(meeting.capture.title)
        parts.append("\(Formatting.count(meeting.wordCount)) words")
        return parts.joined(separator: " · ")
    }

    private var copyMenu: some View {
        Menu {
            Button("Copy summary") { model.copy(summaryText(), message: "Summary copied") }
                .disabled(meeting.summary == nil)
            Button("Copy transcript") { model.copy(transcriptText(), message: "Transcript copied") }
                .disabled(meeting.utterances.isEmpty)
            Button("Copy everything as Markdown") {
                model.copy(MeetingMarkdown.render(meeting), message: "Meeting copied as Markdown")
            }
        } label: {
            HStack(spacing: 6) { Image(systemName: "doc.on.doc"); Text("Copy") }
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }

    private var moreMenu: some View {
        Menu {
            Button("Write the summary again") { model.summarize(meeting.id) }
                .disabled(working || meeting.wordCount < 8)
            if meeting.hasAudio {
                Button("Delete the recording, keep the transcript") { model.deleteRecording(meeting.id) }
            }
            Divider()
            Button("Delete meeting…") { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func summaryText() -> String {
        var markdown = MeetingMarkdown.render(meeting, includeTranscript: false)
        if let range = markdown.range(of: "\n## My notes") { markdown = String(markdown[..<range.lowerBound]) }
        return markdown
    }

    private func transcriptText() -> String {
        meeting.turns().map { "\(meeting.name(for: $0.speaker)) (\(Meeting.clock($0.start))): \($0.text)" }.joined(separator: "\n\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safe = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        panel.nameFieldStringValue = safe + ".md"
        panel.title = "Export meeting"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try MeetingMarkdown.render(meeting).write(to: url, atomically: true, encoding: .utf8)
                model.show(toast: "Exported")
            } catch {
                model.show(toast: "Couldn't save: \(error.localizedDescription)", seconds: 5)
            }
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !meeting.suggestedNames.isEmpty { suggestions }
                if working {
                    Card {
                        HStack(spacing: 14) {
                            ProgressView().controlSize(.regular)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Writing up the notes…").font(.system(size: 14, weight: .semibold))
                                Text("This takes a few seconds.").font(.system(size: 12.5)).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                } else if meeting.summaryState == .failed {
                    Notice(text: meeting.summaryError ?? "The summary couldn't be written.")
                    Button("Try again") { model.summarize(meeting.id) }.buttonStyle(SecondaryButtonStyle())
                } else if let summary = meeting.summary, !summary.isEmpty {
                    summaryBody(summary)
                } else if meeting.wordCount >= 8 {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No summary yet").font(.display(18))
                            Text("Quill can write up what was discussed, what was decided, and who needs to do what.")
                                .font(.system(size: 13)).foregroundColor(.secondary)
                            Button("Write the summary") { model.summarize(meeting.id) }.buttonStyle(PrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Card {
                        Text(meeting.summaryError ?? "Not enough was said to summarise.")
                            .font(.system(size: 13)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var suggestions: some View {
        let lines = meeting.suggestedNames.sorted { $0.key < $1.key }
            .map { "\(meeting.name(for: $0.key)) is \($0.value)" }
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 20)).foregroundColor(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quill picked up some names").font(.system(size: 13.5, weight: .semibold))
                Text(lines.joined(separator: " · ")).font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button("Not now") { model.dismissSuggestions(meeting.id) }.buttonStyle(GhostButtonStyle())
            Button("Use names") { model.acceptSuggestions(meeting.id) }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.accentSoft))
    }

    @ViewBuilder private func summaryBody(_ summary: MeetingSummary) -> some View {
        if !summary.overview.isEmpty {
            Card {
                Text(summary.overview)
                    .font(.system(size: 15.5))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        if !summary.actionItems.isEmpty {
            block(title: "Action items", symbol: "checkmark.circle") {
                ForEach(summary.actionItems) { item in
                    Button { model.toggleAction(meeting.id, item.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundColor(item.done ? Palette.positive : Palette.hairline.opacity(3))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.task).font(.system(size: 14))
                                    .strikethrough(item.done)
                                    .foregroundColor(item.done ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let owner = item.owner { Chip(text: owner, symbol: "person", tint: Palette.accentText) }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !summary.decisions.isEmpty {
            block(title: "Decisions", symbol: "checkmark.seal") { bullets(summary.decisions) }
        }
        if !summary.keyPoints.isEmpty {
            block(title: "Key points", symbol: "list.bullet") { bullets(summary.keyPoints) }
        }
        if !summary.openQuestions.isEmpty {
            block(title: "Open questions", symbol: "questionmark.circle") { bullets(summary.openQuestions) }
        }
    }

    private func block<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                SectionLabel(text: title)
            }
            .foregroundColor(.secondary)
            Card {
                VStack(alignment: .leading, spacing: 11) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bullets(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, text in
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Palette.accent.opacity(0.6)).frame(width: 5, height: 5).padding(.top, 7)
                Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let all = meeting.turns()
        let terms = transcriptQuery.lowercased().split(separator: " ").map(String.init)
        let shown = terms.isEmpty ? all : all.filter { turn in
            let hay = (turn.text + " " + meeting.name(for: turn.speaker)).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        let activeID: Int? = {
            guard player.isPlaying else { return nil }
            return all.last { $0.start <= player.position + 0.2 }?.id
        }()

        return VStack(spacing: 0) {
            if all.isEmpty {
                EmptyState(symbol: "text.alignleft", title: "Nothing was heard",
                           message: "No speech was picked up during this meeting.")
            } else {
                SearchBox(text: $transcriptQuery, prompt: "Search the transcript")
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(shown) { turn in
                            TurnRow(meeting: meeting, turn: turn,
                                    isPlaying: activeID == turn.id,
                                    canSeek: player.isReady,
                                    onSeek: { player.play(from: $0) },
                                    onRename: { model.nameSpeaker(meeting.id, voice: turn.speaker, as: $0) })
                        }
                        if shown.isEmpty {
                            Text("Nothing matches “\(transcriptQuery)”.").font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Notes

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What you jotted down during the meeting. Edit it any time — it's kept with the meeting.")
                .font(.system(size: 12.5)).foregroundColor(.secondary)
            Card(padding: 16) {
                NotesEditor(text: $notes, placeholder: "Nothing yet. Add notes, decisions, follow-ups…") { value in
                    notesSave?.cancel()
                    let work = DispatchWorkItem { model.setNotes(meeting.id, value) }
                    notesSave = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 30)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
