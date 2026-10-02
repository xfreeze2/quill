import SwiftUI
import UniformTypeIdentifiers

/// A finished meeting, read like a page: what was decided and who does what, a
/// map of who spoke when, the transcript, and a way to ask it questions.
struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", transcript = "Transcript", ask = "Ask", notes = "My notes"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary
    @State private var title = ""
    @State private var transcriptQuery = ""
    @State private var notes = ""
    @State private var question = ""
    @State private var confirmDelete = false
    @State private var notesSave: DispatchWorkItem?
    @State private var scrollTarget: Int?
    @FocusState private var titleFocused: Bool
    @StateObject private var player: MeetingPlayer
    @StateObject private var thread = AskThread()

    init(model: AppModel, meeting: Meeting, tab: Tab = .summary) {
        self.model = model
        self.meeting = meeting
        _tab = State(initialValue: tab)
        _player = StateObject(wrappedValue: MeetingPlayer(url: meeting.hasAudio ? model.store.audioURL(for: meeting.id) : nil))
    }

    private var working: Bool { model.summarizing.contains(meeting.id) || meeting.summaryState == .working }
    private var canAsk: Bool { meeting.wordCount >= 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 40)
                .padding(.top, Layout.titlebar - 4)

            TabStrip(tabs: Tab.allCases.filter { $0 != .ask || canAsk }, selection: $tab) { $0.rawValue }
                .padding(.horizontal, 40)
                .padding(.top, 16)

            Group {
                switch tab {
                case .summary:    summary
                case .transcript: transcript
                case .ask:        ask
                case .notes:      notesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PageGround(tint: .indigo))
        .onAppear {
            title = meeting.title
            notes = meeting.userNotes
            if meeting.summary == nil, meeting.liveNotes.isEmpty, meeting.summaryState == .none, meeting.wordCount < 8 { tab = .transcript }
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

    // MARK: Header

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { title = meeting.title } else if trimmed != meeting.title { model.rename(meeting.id, to: trimmed) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meeting title", text: $title, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                .focused($titleFocused)
                .onChange(of: titleFocused) { if !$0 { commitTitle() } }

            HStack(spacing: 10) {
                Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary)
                Spacer(minLength: 8)
                Button { model.copy(summaryText(), message: "Notes copied") } label: {
                    HStack(spacing: 6) { Image(systemName: "doc.on.doc"); Text("Copy notes") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(meeting.summary == nil && meeting.liveNotes.isEmpty)
                moreMenu
            }
        }
    }

    private var subtitle: String {
        var parts = [Formatting.shortDate(meeting.createdAt)]
        if meeting.duration >= 1 { parts.append(Meeting.describe(duration: meeting.duration)) }
        let people = meeting.speakers.count
        parts.append(people > 1 ? "\(people) people" : meeting.capture.title)
        if meeting.hasAudio { parts.append("Recording kept") }
        return parts.joined(separator: " · ")
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy transcript") { model.copy(transcriptText(), message: "Transcript copied") }
                .disabled(meeting.utterances.isEmpty)
            Button("Copy everything as Markdown") { model.copy(MeetingMarkdown.render(meeting), message: "Copied as Markdown") }
            Button("Export as Markdown…") { export() }
            Divider()
            Button("Draft a follow-up email") {
                tab = .ask
                thread.ask(MeetingAsk.followUp, about: meeting)
            }
            .disabled(!canAsk)
            Button("Write the summary again") { model.summarize(meeting.id) }
                .disabled(working || meeting.wordCount < 8)
            Divider()
            if meeting.hasAudio {
                Button("Delete the recording, keep the transcript") { model.deleteRecording(meeting.id) }
            }
            Button("Delete meeting…") { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
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

    /// Go to a moment: listen from there if the sound was kept, otherwise find it
    /// in the transcript.
    private func jump(to time: Double) {
        if player.isReady {
            player.play(from: time)
        } else {
            let turns = meeting.turns()
            scrollTarget = (turns.last { $0.start <= time + 0.5 } ?? turns.first)?.id
            tab = .transcript
        }
    }

    // MARK: Summary

    private struct Column: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 40)
                .padding(.top, 22)
                .padding(.bottom, 40)
                .frame(maxWidth: Layout.reading + 80, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }

    private var timeline: MeetingTimeline { MeetingTimeline(meeting) }

    /// A map of one voice with nothing to jump to says nothing.
    private var showsMap: Bool {
        !timeline.isEmpty && (timeline.lanes.count > 1 || meeting.hasAudio || !meeting.chapters.isEmpty)
    }

    @ViewBuilder private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !meeting.suggestedNames.isEmpty { suggestions }

                if let summary = meeting.summary, !summary.isEmpty {
                    overviewPanel(summary)
                    if showsMap {
                        ConversationMap(timeline: timeline, player: player,
                                        onRename: { model.nameSpeaker(meeting.id, voice: $0, as: $1) },
                                        onJump: jump)
                    }
                    summaryBody(summary)
                } else {
                    status
                    if showsMap {
                        ConversationMap(timeline: timeline, player: player,
                                        onRename: { model.nameSpeaker(meeting.id, voice: $0, as: $1) },
                                        onJump: jump)
                    }
                    if !meeting.liveNotes.isEmpty { liveNotes }
                }
            }
            .modifier(Column())
        }
    }

    /// Why there is no summary, and what to do about it.
    @ViewBuilder private var status: some View {
        if working {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Writing up the notes…").font(.system(size: 14)).foregroundColor(.secondary)
            }
        } else if meeting.summaryState == .failed {
            VStack(alignment: .leading, spacing: 10) {
                Notice(text: meeting.summaryError ?? "The summary couldn't be written.")
                Button("Try again") { model.summarize(meeting.id) }.buttonStyle(SecondaryButtonStyle())
            }
        } else if meeting.wordCount >= 8 {
            VStack(alignment: .leading, spacing: 10) {
                Text("No summary yet").font(.system(size: 15, weight: .semibold))
                Text("Quill can write up what was discussed, what was decided, and who needs to do what.")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                Button("Write the summary") { model.summarize(meeting.id) }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            Text(meeting.summaryError ?? "Not enough was said to summarise.")
                .font(.system(size: 13)).foregroundColor(.secondary)
        }
    }

    private var liveNotes: some View {
        section("Notes from the meeting", "text.bubble.fill", .sky) {
            ForEach(meeting.liveNotes) { note in
                Button { jump(to: note.time) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Meeting.clock(note.time)).font(.system(size: 11.5).monospacedDigit())
                            .foregroundColor(.secondary).frame(width: 38, alignment: .trailing)
                        Text(note.text).font(.system(size: 14.5)).foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestions: some View {
        let lines = meeting.suggestedNames.sorted { $0.key < $1.key }
            .map { "\(meeting.name(for: $0.key)) may be \($0.value)" }
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 15)).foregroundColor(Palette.accent)
            Text(lines.joined(separator: " · ")).font(.system(size: 13))
            Spacer(minLength: 8)
            Button("Not now") { model.dismissSuggestions(meeting.id) }.buttonStyle(GhostButtonStyle())
            Button("Use names") { model.acceptSuggestions(meeting.id) }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.accentSoft))
    }

    @ViewBuilder private func summaryBody(_ summary: MeetingSummary) -> some View {
        if !summary.actionItems.isEmpty {
            section("Action items", "checkmark.circle.fill", .green) {
                ForEach(summary.actionItems) { item in
                    Button { model.toggleAction(meeting.id, item.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundColor(item.done ? Palette.positive : .secondary.opacity(0.55))
                            Text(item.task)
                                .font(.system(size: 14.5))
                                .strikethrough(item.done)
                                .foregroundColor(item.done ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if let owner = item.owner {
                                Text(owner).font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !summary.decisions.isEmpty {
            section("Decisions", "flag.fill", .amber) { bullets(summary.decisions) }
        }
        if !meeting.chapters.isEmpty {
            section("Topics", "list.number", .indigo) {
                ForEach(Array(meeting.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button { jump(to: chapter.start) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Palette.accent))
                            Text(chapter.title).font(.system(size: 14.5)).foregroundColor(.primary)
                            Spacer(minLength: 8)
                            Text(Meeting.clock(chapter.start)).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !summary.keyPoints.isEmpty {
            section("Key points", "star.fill", .coral) { bullets(summary.keyPoints) }
        }
        if !summary.openQuestions.isEmpty {
            section("Open questions", "questionmark.circle.fill", .rose) { bullets(summary.openQuestions) }
        }
    }

    private func section<Content: View>(_ title: String, _ symbol: String, _ tile: Tile,
                                        @ViewBuilder content: () -> Content) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    IconTile(symbol: symbol, tile: tile, size: 22)
                    Text(title).font(.system(size: 14, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 11) { content() }
            }
        }
    }

    /// What it was about, and the numbers that go with it.
    @ViewBuilder private func overviewPanel(_ summary: MeetingSummary) -> some View {
        let facts = glance()
        if !summary.overview.isEmpty || !facts.isEmpty {
            Panel(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if !summary.overview.isEmpty {
                        Text(summary.overview)
                            .font(.system(size: 16))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(18)
                    }
                    if !summary.overview.isEmpty && !facts.isEmpty { RowDivider() }
                    if !facts.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                                if index > 0 { Rectangle().fill(Palette.hairline).frame(width: 1, height: 30) }
                                VStack(spacing: 1) {
                                    Text(fact.value)
                                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                                    Text(fact.label).font(.system(size: 11.5)).foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func glance() -> [(value: String, label: String)] {
        var out: [(String, String)] = []
        if meeting.duration >= 1 { out.append((Meeting.describe(duration: meeting.duration), "Length")) }
        if meeting.speakers.count > 0 { out.append(("\(meeting.speakers.count)", meeting.speakers.count == 1 ? "Person" : "People")) }
        if meeting.wordCount > 0 { out.append((Formatting.count(meeting.wordCount), "Words")) }
        let items = meeting.summary?.actionItems ?? []
        if !items.isEmpty {
            let open = items.filter { !$0.done }.count
            out.append(("\(open)", open == 1 ? "To-do open" : "To-dos open"))
        } else if !meeting.chapters.isEmpty {
            out.append(("\(meeting.chapters.count)", meeting.chapters.count == 1 ? "Topic" : "Topics"))
        }
        return out
    }

    private func bullets(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, text in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").font(.system(size: 14.5)).foregroundColor(.secondary)
                Text(text).font(.system(size: 14.5)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                ScrollViewReader { proxy in
                    ScrollView {
                        Panel(padding: 14) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(shown) { turn in
                                    TurnRow(meeting: meeting, turn: turn,
                                            isPlaying: activeID == turn.id,
                                            canSeek: player.isReady,
                                            onSeek: { player.play(from: $0) },
                                            onRename: { model.nameSpeaker(meeting.id, voice: turn.speaker, as: $0) })
                                        .id(turn.id)
                                }
                                if shown.isEmpty {
                                    Text("Nothing matches “\(transcriptQuery)”.").font(.system(size: 13)).foregroundColor(.secondary)
                                }
                            }
                        }
                        .modifier(Column())
                    }
                    .onChange(of: scrollTarget) { target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
                    }
                    .onAppear {
                        if let target = scrollTarget {
                            DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top); scrollTarget = nil }
                        }
                    }
                }
            }
        }
    }

    // MARK: Ask

    private var ask: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Panel(padding: 20) {
                    VStack(alignment: .leading, spacing: 22) {
                        if thread.exchanges.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Ask about this meeting").font(.system(size: 15, weight: .semibold))
                                Text("Answers come only from what was said.")
                                    .font(.system(size: 13)).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(MeetingAsk.suggestions, id: \.self) { suggestion in
                                        Button { send(suggestion) } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: "sparkles").font(.system(size: 11)).foregroundColor(Palette.accent)
                                                Text(suggestion).font(.system(size: 13.5))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.sunken))
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        ForEach(thread.exchanges) { exchange in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(exchange.question).font(.system(size: 14.5, weight: .semibold))
                                if let answer = exchange.answer {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(rendered(answer))
                                            .font(.system(size: 14.5)).lineSpacing(4)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button { model.copy(answer, message: "Copied") } label: {
                                            HStack(spacing: 5) { Image(systemName: "doc.on.doc"); Text("Copy") }
                                        }
                                        .buttonStyle(GhostButtonStyle())
                                    }
                                } else if let failure = exchange.failure {
                                    Notice(text: failure)
                                } else {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Reading the meeting…").font(.system(size: 13)).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .id(exchange.id)
                        }
                    }
                    }
                    .modifier(Column())
                }
                .onChange(of: thread.exchanges) { items in
                    guard let last = items.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask a question…", text: $question, onCommit: { send(question) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                Button { send(question) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundColor(question.trimmingCharacters(in: .whitespaces).isEmpty || thread.busy ? .secondary.opacity(0.4) : Palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || thread.busy)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .frame(maxWidth: Layout.reading)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private func send(_ text: String) {
        thread.ask(text, about: meeting)
        question = ""
    }

    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Notes

    private var notesTab: some View {
        NotesEditor(text: $notes, placeholder: "What you jotted down during the meeting. Edit it any time.") { value in
            notesSave?.cancel()
            let work = DispatchWorkItem { model.setNotes(meeting.id, value) }
            notesSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        .frame(maxWidth: Layout.reading)
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
    }
}
