import SwiftUI

struct MeetingsView: View {
    @ObservedObject var model: AppModel

    /// With nothing saved there is nothing to list, so the page is just the new
    /// meeting, with the whole window to itself.
    private var hasAny: Bool { !model.meetings.isEmpty || model.session != nil }

    var body: some View {
        HStack(spacing: 0) {
            if hasAny {
                MeetingList(model: model)
                    .frame(width: 290)
                Rectangle().fill(Palette.hairline).frame(width: 1).ignoresSafeArea()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.selectedMeetingID == nil, !model.composingMeeting, !model.showingTasks {
                if let live = model.session?.meeting.id {
                    model.selectedMeetingID = live
                } else if let newest = model.meetings.first {
                    model.selectedMeetingID = newest.id
                } else {
                    model.composingMeeting = true
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let session = model.session, session.isActive || session.phase == .stopping,
           model.selectedMeetingID == session.meeting.id, !model.showingTasks, !model.composingMeeting {
            LiveMeetingView(model: model, session: session)
                .id(session.meeting.id)
        } else if model.showingTasks {
            TasksView(model: model)
        } else if model.composingMeeting {
            NewMeetingView(model: model)
        } else if let id = model.selectedMeetingID, let meeting = model.meeting(id) {
            MeetingDetailView(model: model, meeting: meeting)
                .id(id)
        } else {
            NewMeetingView(model: model)
        }
    }
}

// MARK: - List

enum MeetingRow {
    static func subtitle(_ meeting: Meeting, live: Bool) -> String {
        if live { return "Recording" }
        var parts = [Formatting.time(meeting.createdAt)]
        if meeting.isFinished, meeting.duration >= 1 { parts.append(Meeting.describe(duration: meeting.duration)) }
        let people = meeting.speakers.count
        if people > 1 { parts.append("\(people) people") }
        return parts.joined(separator: " · ")
    }

    /// A line or two about what the meeting was.
    static func glance(_ meeting: Meeting) -> String {
        if let overview = meeting.summary?.overview, !overview.isEmpty { return overview }
        if let note = meeting.liveNotes.first?.text { return note }
        return meeting.utterances.first?.text ?? ""
    }
}

private struct MeetingList: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var pendingDelete: Meeting?

    /// The meeting being recorded belongs at the top of the list, though it isn't
    /// among the saved ones until it ends.
    private var all: [Meeting] {
        guard let live = model.session?.meeting, !model.meetings.contains(where: { $0.id == live.id }) else {
            return model.meetings
        }
        return [live] + model.meetings
    }

    private var filtered: [Meeting] {
        let terms = AppSearch.terms(query)
        guard !terms.isEmpty else { return all }
        return all.filter { meeting in
            let haystack = (meeting.title + " " + meeting.utterances.map(\.text).joined(separator: " ")
                            + " " + (meeting.summary?.overview ?? "")).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var groups: [(day: Date, meetings: [Meeting])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Meeting]] = [:]
        for meeting in filtered {
            let day = calendar.startOfDay(for: meeting.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(meeting)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        let openCount = model.openTasks.count
        let anyTasks = !Tasks.all(in: model.meetings).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meetings").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { model.newMeeting() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(IconButtonStyle())
                    .help("New meeting  ⌘N")
            }
            .padding(.horizontal, 16)
            .padding(.top, Layout.titlebar)
            .padding(.bottom, 12)

            SearchBox(text: $query, prompt: "Filter")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if anyTasks, query.isEmpty {
                TasksRow(count: openCount, selected: model.showingTasks) { model.openTasksPage() }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }

            if filtered.isEmpty {
                Spacer()
                Text("No matches").font(.system(size: 13)).foregroundColor(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.day) { group in
                            Text(Formatting.day(group.day))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(group.meetings) { meeting in row(meeting) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(Palette.panel.ignoresSafeArea())
        .alert("Delete this meeting?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let meeting = pendingDelete { model.deleteMeeting(meeting.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The transcript, notes and any recording are removed from this Mac. This can't be undone.")
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        let live = model.session?.meeting.id == meeting.id
        let shown = live ? (model.session?.meeting ?? meeting) : meeting
        let selected = model.selectedMeetingID == meeting.id && !model.composingMeeting && !model.showingTasks
        return MeetingListRow(meeting: shown, live: live, selected: selected) {
            model.openMeeting(meeting.id)
        }
        .contextMenu {
            Button("Copy as Markdown") {
                model.copy(MeetingMarkdown.render(shown), message: "Copied")
            }
            Divider()
            Button("Delete…") { pendingDelete = meeting }
                .disabled(live)
        }
    }
}

private struct TasksRow: View {
    var count: Int
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: "checkmark", tile: .green, size: 22)
                Text("To-dos").font(.system(size: 13.5, weight: .medium)).foregroundColor(.primary)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1.5)
                        .background(Capsule().fill(Tile.green.bottom))
                } else {
                    Text("All done").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.selected : (hovering ? Palette.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MeetingListRow: View {
    var meeting: Meeting
    var live: Bool
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    private var problem: Bool { !live && meeting.summaryState == .failed }
    private var open: Int { (meeting.summary?.actionItems ?? []).filter { !$0.done }.count }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(meeting.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                    if live { PulsingDot(size: 7) }
                    else if open > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle").font(.system(size: 10.5, weight: .semibold))
                            Text("\(open)").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        }
                        .foregroundColor(.secondary)
                    }
                }
                Text(problem ? "Summary didn't finish" : MeetingRow.subtitle(meeting, live: live))
                    .font(.system(size: 12))
                    .foregroundColor(live ? Palette.record : (problem ? Palette.caution : .secondary))
                    .lineLimit(1)
                let glance = MeetingRow.glance(meeting)
                if !glance.isEmpty, !live {
                    Text(glance)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.selected : (hovering ? Palette.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - To-dos

/// Every action item from every meeting, in one place.
struct TasksView: View {
    @ObservedObject var model: AppModel
    @State private var showDone = false

    private func grouped(_ tasks: [OpenTask]) -> [(id: UUID, title: String, date: Date, tasks: [OpenTask])] {
        var order: [UUID] = []
        var buckets: [UUID: [OpenTask]] = [:]
        for task in tasks {
            if buckets[task.meetingID] == nil { order.append(task.meetingID) }
            buckets[task.meetingID, default: []].append(task)
        }
        return order.compactMap { id in
            guard let list = buckets[id], let first = list.first else { return nil }
            return (id, first.meetingTitle, first.meetingDate, list)
        }
    }

    var body: some View {
        let open = model.openTasks
        let done = model.doneTasks
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(symbol: "checkmark.circle", tile: .green, title: "To-dos",
                           subtitle: open.isEmpty ? "Nothing waiting on you" : "\(open.count) open, from your meetings")

                if open.isEmpty {
                    Panel(padding: 28) {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundColor(Palette.positive)
                            Text("All clear").font(.system(size: 15, weight: .semibold))
                            Text("Action items from your meeting summaries land here, so nothing slips.")
                                .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(grouped(open), id: \.id) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { model.openMeeting(group.id) } label: {
                                HStack(spacing: 6) {
                                    Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                                    Text(Formatting.shortDate(group.date)).font(.system(size: 12)).foregroundColor(.secondary)
                                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)).foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.leading, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Panel(padding: 0) { rows(group.tasks) }
                        }
                    }
                }

                if !done.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { withAnimation(.easeOut(duration: 0.18)) { showDone.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
                                    .rotationEffect(.degrees(showDone ? 90 : 0))
                                Text("Done · \(done.count)").font(.system(size: 12, weight: .semibold))
                                Spacer()
                            }
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showDone { Panel(padding: 0) { rows(done) } }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, Layout.titlebar - 4)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(PageGround(tint: .green))
    }

    private func rows(_ tasks: [OpenTask]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 { RowDivider().padding(.leading, 44) }
                Button { model.toggleAction(task.meetingID, task.item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: task.item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundColor(task.item.done ? Palette.positive : .secondary.opacity(0.55))
                        Text(task.item.task)
                            .font(.system(size: 14))
                            .strikethrough(task.item.done)
                            .foregroundColor(task.item.done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let owner = task.item.owner {
                            Chip(text: owner)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - New meeting

struct NewMeetingView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.meetingCapture) private var captureRaw = MeetingCapture.call.rawValue
    @AppStorage(Defaults.meetingKeepAudio) private var keepAudio = false
    @AppStorage(Defaults.meetingLanguage) private var language = "auto"
    @State private var askConsent = false

    private var capture: MeetingCapture { MeetingCapture(rawValue: captureRaw) ?? .call }

    @ViewBuilder private func showcase(compact: Bool) -> some View {
        ShowcaseCard(title: "Who said what", caption: "Voices told apart, with each person's share of the talk.", compact: compact) {
            VoiceMapSketch()
        }
        ShowcaseCard(title: "Notes as you go", caption: "A few lines every minute, then a summary with action items.", compact: compact) {
            NotesSketch()
        }
        ShowcaseCard(title: "Ask anything", caption: "Questions answered from what was said. Draft the follow-up.", compact: compact) {
            AskSketch()
        }
    }

    var body: some View {
        GeometryReader { geo in page(narrow: geo.size.width < 700) }
    }

    private func page(narrow: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(symbol: "person.2.wave.2", tile: .indigo, title: "New meeting",
                           subtitle: "Quill listens, tells the voices apart, and writes the notes as you go.")

                Panel(padding: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 12) {
                            CaptureCard(symbol: "video.fill", tile: .indigo, title: "Call on this Mac",
                                        detail: "Zoom, Meet, Teams, FaceTime. Your mic is you; the Mac's sound is everyone else.",
                                        selected: capture == .call) { captureRaw = MeetingCapture.call.rawValue }
                            CaptureCard(symbol: "person.3.fill", tile: .coral, title: "In the room",
                                        detail: "People together in one place. One microphone hears everyone.",
                                        selected: capture == .room) { captureRaw = MeetingCapture.room.rawValue }
                        }

                        RowDivider()

                        Toggle(isOn: Binding(get: { keepAudio }, set: { on in
                            if on { askConsent = true } else { keepAudio = false }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep the recording").font(.system(size: 13.5))
                                Text("Saved on this Mac only, so you can listen back.")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        notices

                        HStack(spacing: 12) {
                            Button { model.startMeeting(capture: capture, keepAudio: keepAudio, language: language) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "record.circle")
                                    Text("Start meeting")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle(large: true))
                            .keyboardShortcut(.return, modifiers: [.command])
                            Keycap(text: "⌘↩")
                            Spacer()
                        }

                        if keepAudio {
                            Text("Tell people they're being recorded. Laws about recording conversations vary, and some require everyone's agreement.")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    GroupHeading(text: "What you get")
                    if narrow {
                        VStack(spacing: 10) { showcase(compact: true) }
                    } else {
                        HStack(alignment: .top, spacing: 14) { showcase(compact: false) }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, Layout.titlebar - 4)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(PageGround(tint: .indigo))
        .alert("Keep a recording of this meeting?", isPresented: $askConsent) {
            Button("Keep Recording") { keepAudio = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quill will save the sound of the meeting on this Mac, and only here. Make sure everyone taking part knows and agrees. You can delete the recording at any time and keep the transcript.")
        }
    }

    @ViewBuilder private var notices: some View {
        if model.access.account == nil {
            notice("Quill needs a Grok sign-in or an xAI API key to turn speech into text.", button: "Set up…") {
                model.bridge.openSetup()
            }
        } else if capture == .call, SystemAudioPermission.isSupported, model.access.systemAudio == .denied {
            notice("Quill can't hear your Mac's audio yet, so the other side of a call would be missing.", button: "Allow…") {
                SystemAudioPermission.openSettings()
            }
        } else if capture == .call, !SystemAudioPermission.isSupported {
            notice("Hearing the other side of a call needs macOS 14.2 or newer. Quill will listen to the microphone only.", button: nil) {}
        } else if capture == .call {
            HStack(spacing: 8) {
                Image(systemName: "headphones").font(.system(size: 12)).foregroundColor(.secondary)
                Text("Headphones keep your own line clean. On speakers, your microphone also hears the call.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notice(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button { Button(button, action: action).buttonStyle(SecondaryButtonStyle()) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.caution.opacity(0.10)))
    }
}

private struct CaptureCard: View {
    var symbol: String
    var tile: Tile
    var title: String
    var detail: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(symbol: symbol, tile: tile, size: 30)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundColor(selected ? Palette.accent : Color.secondary.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.primary)
                    Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Palette.accentSoft : (hovering ? Palette.hover : Palette.sunken)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Palette.accent : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
