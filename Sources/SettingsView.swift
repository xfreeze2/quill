import SwiftUI
import AVFoundation

/// Languages the speech service transcribes, plus Chinese — the service handles
/// it although the grok command-line tool's own list leaves it out.
enum Languages {
    static let all: [(String, String)] = [
        ("Auto-detect", "auto"),
        ("English", "en"),
        ("Arabic", "ar"), ("Chinese", "zh"), ("Czech", "cs"), ("Danish", "da"),
        ("Dutch", "nl"), ("Filipino", "fil"), ("French", "fr"), ("German", "de"),
        ("Hindi", "hi"), ("Indonesian", "id"), ("Italian", "it"), ("Japanese", "ja"),
        ("Korean", "ko"), ("Macedonian", "mk"), ("Malay", "ms"), ("Persian", "fa"),
        ("Polish", "pl"), ("Portuguese", "pt"), ("Romanian", "ro"), ("Russian", "ru"),
        ("Spanish", "es"), ("Swedish", "sv"), ("Thai", "th"), ("Turkish", "tr"),
        ("Vietnamese", "vi"),
    ]
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @AppStorage(Defaults.language) private var language = "en"
    @AppStorage(Defaults.trigger) private var trigger = Trigger.control.rawValue
    @AppStorage(Defaults.singleTap) private var singleTap = true
    @AppStorage(Defaults.pauseSeconds) private var pause = 5.0
    @AppStorage(Defaults.clickToInsert) private var clickToInsert = true
    @AppStorage(Defaults.insertAtEnd) private var insertAtEnd = true
    @AppStorage(Defaults.stopPhrase) private var stopPhrase = true
    @AppStorage(Defaults.polish) private var polish = false
    @AppStorage(Defaults.keepHistory) private var keepHistory = true
    @AppStorage(Defaults.cornerButton) private var cornerButton = true

    @AppStorage(Defaults.liveTarget) private var liveTarget = "en"
    @AppStorage(Defaults.liveSource) private var liveSource = "system"
    @AppStorage(Defaults.liveLayout) private var liveLayout = "both"
    @AppStorage(Defaults.liveHideFromCapture) private var liveHide = true
    @AppStorage(Defaults.liveDoubleTap) private var liveDoubleTap = true

    @AppStorage(Defaults.meetingCapture) private var meetingCapture = MeetingCapture.call.rawValue
    @AppStorage(Defaults.meetingKeepAudio) private var meetingKeepAudio = false
    @AppStorage(Defaults.meetingAutoSummarize) private var autoSummarize = true
    @AppStorage(Defaults.meetingLanguage) private var meetingLanguage = "auto"

    @AppStorage(Defaults.notifyUpdates) private var notifyUpdates = true

    @State private var startAtLogin = LoginItem.isEnabled
    @State private var askAudioConsent = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings").font(.display(30))
                    Text("Quill \(Build.version)").font(.system(size: 14)).foregroundColor(.secondary)
                }
                .padding(.top, 8)

                account
                permissions
                dictation
                translation
                meetings
                general
                data
            }
            .padding(.horizontal, 38)
            .padding(.top, 14)
            .padding(.bottom, 44)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .alert("Keep a recording of every meeting?", isPresented: $askAudioConsent) {
            Button("Keep Recordings") { meetingKeepAudio = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quill will save the sound of meetings on this Mac, and only here. Make sure everyone taking part knows and agrees. You can still choose per meeting, and delete any recording later.")
        }
        .alert("Delete all dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every dictation Quill has kept on this Mac. It can't be undone.")
        }
    }

    // MARK: Sections

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: title)
            Card(padding: 4) {
                VStack(spacing: 0) { content() }
                    .padding(.horizontal, 14)
            }
        }
    }

    private var account: some View {
        group("Account") {
            SettingRow(model.access.account ?? "Not signed in",
                       detail: model.access.account == nil
                       ? "Quill uses your Grok subscription, or your own xAI API key, to turn speech into text."
                       : "Used for transcription, translation and summaries.") {
                HStack(spacing: 8) {
                    Circle().fill(model.access.account == nil ? Palette.caution : Palette.positive).frame(width: 8, height: 8)
                    Button(Keychain.hasKey ? "Change key…" : "Use my own key…") {
                        model.bridge.editAPIKey()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.refreshAccess() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var permissions: some View {
        group("Permissions") {
            PermissionRow(title: "Microphone", detail: "So Quill can hear you.", granted: model.access.microphone == .authorized,
                          action: "Allow") {
                if model.access.microphone == .notDetermined {
                    Recorder.micAuthorization { _ in model.refreshAccess() }
                } else {
                    Inserter.openPrivacyPane("Privacy_Microphone")
                }
            }
            RowDivider()
            PermissionRow(title: "Accessibility", detail: "So the trigger key works and Quill can type into other apps.",
                          granted: model.access.accessibility, action: "Open Settings") {
                Inserter.requestTrust()
                Inserter.openPrivacyPane("Privacy_Accessibility")
            }
            if SystemAudioPermission.isSupported {
                RowDivider()
                PermissionRow(title: "System audio", detail: "To hear the other side of a call, and for live translation. Optional.",
                              granted: model.access.systemAudio == .granted, action: "Allow") {
                    if model.access.systemAudio == .unknown {
                        SystemAudioPermission.request { _ in model.refreshAccess() }
                    } else {
                        SystemAudioPermission.openSettings()
                    }
                }
            }
        }
    }

    private var dictation: some View {
        group("Dictation") {
            SettingRow("Language", detail: "What you speak when you dictate.") {
                Picker("", selection: $language) {
                    ForEach(Languages.all, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            SettingRow("Trigger key", detail: "Tap it anywhere to start and stop.") {
                Picker("", selection: $trigger) {
                    ForEach(Trigger.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            SettingRow("Single tap", detail: "A tap only counts if nothing else is pressed with it, so shortcuts like ⌃C never trigger it. Off means double-tap.") {
                Toggle("", isOn: $singleTap).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Finish when I stop talking") {
                Picker("", selection: $pause) {
                    Text("Never").tag(0.0)
                    Text("After 2 seconds").tag(2.0)
                    Text("After 3 seconds").tag(3.0)
                    Text("After 5 seconds").tag(5.0)
                    Text("After 8 seconds").tag(8.0)
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            SettingRow("Stop when I say “that's it”", detail: "Say “that's it” or “that's all” to finish hands-free.") {
                Toggle("", isOn: $stopPhrase).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Clean up grammar", detail: "Adds punctuation, joins split sentences and drops “um”s. Takes about a second and never changes your wording.") {
                Toggle("", isOn: $polish).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Click anywhere to insert", detail: "Click into a field while dictating and the words go there.") {
                Toggle("", isOn: $clickToInsert).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Insert at end of field", detail: "Add to what's already there instead of replacing the selection.") {
                Toggle("", isOn: $insertAtEnd).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Show the idle pill", detail: "The small button at the edge of the screen.") {
                HStack(spacing: 10) {
                    if cornerButton { Button("Reset position") { model.bridge.resetPanelPosition() }.buttonStyle(GhostButtonStyle()) }
                    Toggle("", isOn: $cornerButton).toggleStyle(.switch).labelsHidden()
                }
            }
            RowDivider()
            SettingRow("Keep a history of dictations", detail: "Stored in a private file on this Mac. Turn off and nothing new is kept.") {
                Toggle("", isOn: $keepHistory).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var translation: some View {
        group("Live translation") {
            SettingRow("Translate into") {
                Picker("", selection: $liveTarget) {
                    ForEach(Languages.all.filter { $0.1 != "auto" }, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            SettingRow("Listen to") {
                Picker("", selection: $liveSource) {
                    Text("Everything the Mac plays").tag("system")
                    Text("Microphone").tag("microphone")
                }
                .labelsHidden().frame(width: 190)
            }
            RowDivider()
            SettingRow("Show only the translation", detail: "Hide the original words in the panel.") {
                Toggle("", isOn: Binding(get: { liveLayout == TranslatorPanel.Layout.translationOnly.rawValue },
                                         set: { liveLayout = $0 ? TranslatorPanel.Layout.translationOnly.rawValue : TranslatorPanel.Layout.both.rawValue }))
                    .toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Hide from screen sharing", detail: "Keeps the translation window out of screen shares and recordings.") {
                Toggle("", isOn: $liveHide).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Double-tap to open", detail: singleTap ? "Double-tap the trigger key anywhere to start or stop."
                       : "Needs Single tap — in double-tap mode a double tap is dictation.") {
                Toggle("", isOn: $liveDoubleTap).toggleStyle(.switch).labelsHidden().disabled(!singleTap)
            }
        }
    }

    private var meetings: some View {
        group("Meetings") {
            SettingRow("Usually capture") {
                Picker("", selection: $meetingCapture) {
                    Text("A call on this Mac").tag(MeetingCapture.call.rawValue)
                    Text("People in the room").tag(MeetingCapture.room.rawValue)
                }
                .labelsHidden().frame(width: 190)
            }
            RowDivider()
            SettingRow("Language", detail: "Leave on auto-detect unless meetings are in one language.") {
                Picker("", selection: $meetingLanguage) {
                    ForEach(Languages.all, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            SettingRow("Write the summary when a meeting ends") {
                Toggle("", isOn: $autoSummarize).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Keep the sound of meetings", detail: "Off by default. When on, Quill saves a recording on this Mac so you can replay moments. Tell people they're being recorded.") {
                Toggle("", isOn: Binding(get: { meetingKeepAudio }, set: { on in
                    if on { askAudioConsent = true } else { meetingKeepAudio = false }
                })).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var general: some View {
        group("General") {
            SettingRow("Start Quill at login", detail: "Quill starts quietly in the menu bar.") {
                Toggle("", isOn: Binding(get: { startAtLogin }, set: { on in
                    LoginItem.setEnabled(on)
                    startAtLogin = LoginItem.isEnabled
                })).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow("Tell me about updates") {
                HStack(spacing: 10) {
                    Button("Check now") { model.bridge.checkForUpdates() }.buttonStyle(GhostButtonStyle())
                    Toggle("", isOn: $notifyUpdates).toggleStyle(.switch).labelsHidden()
                }
            }
            RowDivider()
            SettingRow("Setup guide", detail: "Walk through the permissions Quill needs.") {
                Button("Open setup") { model.bridge.openSetup() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var data: some View {
        group("Your data") {
            SettingRow("Everything stays on this Mac",
                       detail: "Dictations, meetings, notes and recordings are private files in your Library. Only speech and text you choose to transcribe or summarise is sent to Grok.") {
                Button("Show in Finder") { model.revealDataFolder() }.buttonStyle(SecondaryButtonStyle())
            }
            RowDivider()
            SettingRow("Delete dictation history", detail: "\(Formatting.count(model.stats.dictations)) dictations kept.") {
                Button("Delete…") { confirmClear = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.entries.isEmpty)
            }
        }
    }
}

private struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var action: String
    var perform: () -> Void

    var body: some View {
        SettingRow(title, detail: detail) {
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Palette.positive)
                    Text("Allowed").font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                }
            } else {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
