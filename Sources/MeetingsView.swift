import SwiftUI

struct MeetingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            MeetingList(model: model)
                .frame(width: 292)
            Rectangle().fill(Palette.hairline).frame(width: 1)
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
            EmptyState(symbol: "person.2.wave.2", title: "Pick a meeting",
                       message: "Choose one from the list, or start a new one.",
                       actionTitle: "New meeting", action: { model.newMeeting() })
        }
    }
}

// MARK: - List

enum MeetingRow {
    static func subtitle(_ meeting: Meeting) -> String {
        var parts = [Formatting.shortDate(meeting.createdAt)]
        if meeting.isFinished, meeting.duration >= 1 { parts.append(Meeting.describe(duration: meeting.duration)) }
        else if !meeting.isFinished { parts.append("Recording") }
        let people = meeting.speakers.count
        if people > 1 { parts.append("\(people) people") }
        return parts.joined(separator: " · ")
    }
}

struct MeetingGlyph: View {
    var meeting: Meeting
    var live: Bool

    var body: some View {
        let symbol = live ? "waveform" : (meeting.summary == nil ? "text.alignleft" : "doc.text")
        let tint = live ? Palette.record : Palette.accent
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.13))
            Image(systemName: symbol).font(.system(size: 13.5, weight: .semibold)).foregroundColor(tint)
        }
        .frame(width: 34, height: 34)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meetings").font(.display(24))
                Spacer()
                Button { model.newMeeting() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.accent))
                }
                .buttonStyle(.plain)
                .help("New meeting")
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 12)

            SearchBox(text: $query, prompt: "Search meetings")
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if all.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No meetings yet").font(.system(size: 13, weight: .medium))
                    Text("They'll be listed here once you've taken some notes.")
                        .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            } else if filtered.isEmpty {
                VStack { Spacer(); Text("No matches").font(.system(size: 13)).foregroundColor(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { meeting in
                            row(meeting)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(Palette.canvas)
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
                model.copy(MeetingMarkdown.render(shown), message: "Meeting copied as Markdown")
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                MeetingGlyph(meeting: meeting, live: live)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        .foregroundColor(selected ? Palette.accentText : .primary)
                    Text(MeetingRow.subtitle(meeting)).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Palette.accentSoft : (hovering ? Palette.hover : Color.clear)))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New meeting").font(.display(30))
                    Text("Quill listens, writes down who said what, and summarises it when you're done.")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    CaptureTile(symbol: "video", title: "Call on this Mac",
                                message: "Zoom, Meet, Teams, FaceTime… Your microphone is you; everything the Mac plays is everyone else.",
                                selected: capture == .call) { captureRaw = MeetingCapture.call.rawValue }
                    CaptureTile(symbol: "person.3", title: "In the room",
                                message: "A meeting in person. One microphone hears the room, and Quill tells the voices apart.",
                                selected: capture == .room) { captureRaw = MeetingCapture.room.rawValue }
                }

                if capture == .call, SystemAudioPermission.isSupported, model.access.systemAudio == .denied {
                    notice(symbol: "speaker.slash", text: "Quill can't hear your Mac's audio yet, so the other side of a call would be missing.",
                           button: "Allow…") { SystemAudioPermission.openSettings() }
                } else if capture == .call, !SystemAudioPermission.isSupported {
                    notice(symbol: "exclamationmark.triangle", text: "Hearing the other side of a call needs macOS 14.2 or newer. Quill will listen to the microphone only.", button: nil) {}
                }
                if model.access.account == nil {
                    notice(symbol: "key", text: "Quill needs a Grok sign-in or an xAI API key to turn speech into text.",
                           button: "Set up…") { model.bridge.openSetup() }
                }
                if capture == .call {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "headphones").font(.system(size: 12)).foregroundColor(.secondary)
                        Text("Headphones keep your own line clean. On speakers, your microphone also hears the call.")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(padding: 4) {
                    VStack(spacing: 0) {
                        SettingRow("Also keep the sound",
                                   detail: "Saves a recording on this Mac only, so you can replay any moment. Off unless you turn it on.") {
                            Toggle("", isOn: Binding(get: { keepAudio }, set: { on in
                                if on { askConsent = true } else { keepAudio = false }
                            }))
                            .toggleStyle(.switch).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        RowDivider().padding(.horizontal, 14)
                        SettingRow("Language", detail: "Leave on auto-detect unless the meeting is in one language only.") {
                            Picker("", selection: $language) {
                                ForEach(Languages.all, id: \.1) { Text($0.0).tag($0.1) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        .padding(.horizontal, 14)
                    }
                }

                HStack(spacing: 14) {
                    Button { model.startMeeting(capture: capture, keepAudio: keepAudio, language: language) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle")
                            Text("Start meeting")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])

                    Text(keepAudio ? "The sound will be kept as well as the words." : "Only the words will be kept.")
                        .font(.system(size: 12.5)).foregroundColor(.secondary)
                }

                Text("Tell people they're being recorded. Laws about recording conversations vary, and some require everyone's agreement.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .alert("Keep a recording of this meeting?", isPresented: $askConsent) {
            Button("Keep Recording") { keepAudio = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quill will save the sound of the meeting on this Mac, and only here. Make sure everyone taking part knows and agrees. You can delete the recording at any time, and keep the transcript.")
        }
    }

    private func notice(symbol: String, text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundColor(Palette.caution)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button { Button(button, action: action).buttonStyle(SecondaryButtonStyle()) }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.caution.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.caution.opacity(0.28), lineWidth: 1))
    }
}

private struct CaptureTile: View {
    var symbol: String
    var title: String
    var message: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                        .foregroundColor(selected ? Palette.accent : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundColor(selected ? Palette.accent : Palette.hairline)
                }
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(message).font(.system(size: 12.5)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Palette.accentSoft : Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Palette.accent.opacity(0.7) : (hovering ? Palette.hairline.opacity(2) : Palette.hairline),
                        lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
