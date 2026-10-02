import SwiftUI

struct MeetingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            MeetingList(model: model)
                .frame(width: 280)
            Rectangle().fill(Palette.hairline).frame(width: 1).ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.selectedMeetingID == nil, !model.composingMeeting {
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
           model.selectedMeetingID == session.meeting.id {
            LiveMeetingView(model: model, session: session)
                .id(session.meeting.id)
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
        let terms = query.lowercased().split(separator: " ").map(String.init)
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

            SearchBox(text: $query, prompt: "Search")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if all.isEmpty {
                Spacer()
                Text("No meetings yet")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if filtered.isEmpty {
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
        return MeetingListRow(meeting: shown, live: live, selected: model.selectedMeetingID == meeting.id && !model.composingMeeting) {
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

private struct MeetingListRow: View {
    var meeting: Meeting
    var live: Bool
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    private var problem: Bool { !live && meeting.summaryState == .failed }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Text(problem ? "Summary didn't finish" : MeetingRow.subtitle(meeting, live: live))
                        .font(.system(size: 12))
                        .foregroundColor(live ? Palette.record : (problem ? Palette.caution : .secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if live { PulsingDot(size: 7) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Palette.selected : (hovering ? Palette.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New meeting").font(.system(size: 26, weight: .semibold))
                    Text("Quill listens, tells the voices apart, and writes the notes as you go.")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: Binding(get: { capture }, set: { captureRaw = $0.rawValue })) {
                        Text("Call on this Mac").tag(MeetingCapture.call)
                        Text("In the room").tag(MeetingCapture.room)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(capture == .call
                         ? "Zoom, Meet, Teams, FaceTime. Your microphone is you; what the Mac plays is everyone else."
                         : "People together in one place. One microphone hears the room.")
                        .font(.system(size: 12.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: Binding(get: { keepAudio }, set: { on in
                    if on { askConsent = true } else { keepAudio = false }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the recording").font(.system(size: 13.5))
                        Text("Saved on this Mac only, so you can listen back. Off unless you turn it on.")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                notices

                HStack(spacing: 14) {
                    Button { model.startMeeting(capture: capture, keepAudio: keepAudio, language: language) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle")
                            Text("Start")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.return, modifiers: [.command])
                    Text("⌘↩").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                }

                if keepAudio {
                    Text("Tell people they're being recorded. Laws about recording conversations vary, and some require everyone's agreement.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 40)
            Spacer(minLength: 24)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Headphones keep your own line clean. On speakers, your microphone also hears the call.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
