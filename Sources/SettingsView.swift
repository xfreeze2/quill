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
    @AppStorage(Defaults.liveDoubleTap) private var liveDoubleTap = true

    @AppStorage(Defaults.meetingCapture) private var meetingCapture = MeetingCapture.call.rawValue
    @AppStorage(Defaults.meetingKeepAudio) private var meetingKeepAudio = false
    @AppStorage(Defaults.meetingAutoSummarize) private var autoSummarize = true
    @AppStorage(Defaults.meetingLiveNotes) private var liveNotes = true
    @AppStorage(Defaults.meetingLanguage) private var meetingLanguage = "auto"

    @AppStorage(Defaults.notifyUpdates) private var notifyUpdates = true

    @State private var startAtLogin = LoginItem.isEnabled
    @State private var askAudioConsent = false
    @State private var confirmClear = false
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(symbol: "gearshape.fill", tile: .slate, title: "Settings",
                           subtitle: "Quill \(Build.version)")
                account
                permissions
                dictation
                meetings
                general
                advanced
                data
            }
            .padding(.horizontal, 40)
            .padding(.top, Layout.titlebar - 4)
            .padding(.bottom, 48)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(PageGround(tint: .slate))
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

    // MARK: Building blocks

    private func heading(_ title: String, _ symbol: String, _ tile: Tile) -> some View {
        HStack(spacing: 9) {
            IconTile(symbol: symbol, tile: tile, size: 22)
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .padding(.leading, 2)
    }

    private func group<Content: View>(_ title: String, _ symbol: String, _ tile: Tile,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(title, symbol, tile)
            Panel(padding: 0) {
                VStack(spacing: 0) { content() }
                    .padding(.horizontal, 16)
            }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
    }

    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        SettingRow(title, detail: detail, control: control)
            .overlay(alignment: .bottom) { RowDivider() }
    }

    // MARK: Sections

    private var account: some View {
        group("Account", "person.crop.circle.fill", .sky) {
            row(model.access.account ?? "Not signed in",
                detail: model.access.account == nil
                ? "Quill uses your Grok subscription, or your own xAI API key, to turn speech into text."
                : nil) {
                HStack(spacing: 10) {
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

    private var missingPermissions: Bool {
        model.access.microphone != .authorized
            || !model.access.accessibility
            || (SystemAudioPermission.isSupported && model.access.systemAudio != .granted)
    }

    @ViewBuilder private var permissions: some View {
        group("Permissions", "checkmark.shield.fill", missingPermissions ? .amber : .green) {
            if !missingPermissions {
                row("Everything Quill needs is allowed") {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Palette.positive)
                }
            } else {
                if model.access.microphone != .authorized {
                    row("Microphone", detail: "So Quill can hear you.") {
                        Button("Allow") {
                            if model.access.microphone == .notDetermined {
                                Recorder.micAuthorization { _ in model.refreshAccess() }
                            } else {
                                Inserter.openPrivacyPane("Privacy_Microphone")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if !model.access.accessibility {
                    row("Accessibility", detail: "So the trigger key works and Quill can type into other apps.") {
                        Button("Open Settings") {
                            Inserter.requestTrust()
                            Inserter.openPrivacyPane("Privacy_Accessibility")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if SystemAudioPermission.isSupported, model.access.systemAudio != .granted {
                    row("System audio", detail: "To hear the other side of a call, and for live translation. Optional.") {
                        Button("Allow") {
                            if model.access.systemAudio == .unknown {
                                SystemAudioPermission.request { _ in model.refreshAccess() }
                            } else {
                                SystemAudioPermission.openSettings()
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var dictation: some View {
        group("Dictation", "mic.fill", .coral) {
            row("Language") {
                Picker("", selection: $language) {
                    ForEach(Languages.all, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().frame(width: 150)
            }
            row("Trigger key") {
                Picker("", selection: $trigger) {
                    ForEach(Trigger.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 150)
            }
            row("Finish when I stop talking") {
                Picker("", selection: $pause) {
                    Text("Never").tag(0.0)
                    Text("After 2 seconds").tag(2.0)
                    Text("After 3 seconds").tag(3.0)
                    Text("After 5 seconds").tag(5.0)
                    Text("After 8 seconds").tag(8.0)
                }
                .labelsHidden().frame(width: 150)
            }
            row("Clean up grammar", detail: "Adds punctuation and drops “um”s. Never changes your wording.") {
                toggle($polish)
            }
            row("Keep a history of dictations") {
                toggle($keepHistory)
            }
        }
    }

    private var meetings: some View {
        group("Meetings", "person.2.wave.2", .indigo) {
            row("Usually capture") {
                Picker("", selection: $meetingCapture) {
                    Text("A call on this Mac").tag(MeetingCapture.call.rawValue)
                    Text("People in the room").tag(MeetingCapture.room.rawValue)
                }
                .labelsHidden().frame(width: 190)
            }
            row("Language") {
                Picker("", selection: $meetingLanguage) {
                    ForEach(Languages.all, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().frame(width: 150)
            }
            row("Take notes while the meeting runs", detail: "A few short lines every minute or so.") {
                toggle($liveNotes)
            }
            row("Write the summary when a meeting ends") {
                toggle($autoSummarize)
            }
            row("Keep the sound of meetings", detail: "Saved on this Mac only. Tell people they're being recorded.") {
                toggle(Binding(get: { meetingKeepAudio }, set: { on in
                    if on { askAudioConsent = true } else { meetingKeepAudio = false }
                }))
            }
        }
    }

    private var general: some View {
        group("General", "gearshape.fill", .slate) {
            row("Start Quill at login") {
                toggle(Binding(get: { startAtLogin }, set: { on in
                    LoginItem.setEnabled(on)
                    startAtLogin = LoginItem.isEnabled
                }))
            }
            row("Tell me about updates") {
                HStack(spacing: 10) {
                    Button("Check now") { model.bridge.checkForUpdates() }.buttonStyle(GhostButtonStyle())
                    toggle($notifyUpdates)
                }
            }
            row("Setup guide") {
                Button("Open setup") { model.bridge.openSetup() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showAdvanced.toggle() } } label: {
                HStack(spacing: 9) {
                    heading("Advanced", "slider.horizontal.3", .slate)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAdvanced {
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    row("Single tap", detail: "A tap only counts if nothing else is pressed with it, so shortcuts like ⌃C never trigger it. Off means double-tap.") {
                        toggle($singleTap)
                    }
                    row("Stop when I say “that's it”", detail: "Say “that's it” or “that's all” to finish hands-free.") {
                        toggle($stopPhrase)
                    }
                    row("Click anywhere to insert", detail: "Click into a field while dictating and the words go there.") {
                        toggle($clickToInsert)
                    }
                    row("Insert at end of field", detail: "Add to what's already there instead of replacing the selection.") {
                        toggle($insertAtEnd)
                    }
                    row("Show the idle pill", detail: "The small button at the edge of the screen.") {
                        HStack(spacing: 10) {
                            if cornerButton { Button("Reset position") { model.bridge.resetPanelPosition() }.buttonStyle(GhostButtonStyle()) }
                            toggle($cornerButton)
                        }
                    }
                    row("Double-tap to translate", detail: singleTap ? "Double-tap the trigger key anywhere to start or stop live translation."
                        : "Needs Single tap. In double-tap mode a double tap is dictation.") {
                        toggle($liveDoubleTap).disabled(!singleTap)
                    }
                }
                .padding(.horizontal, 16)
            }
            }
        }
    }

    private var data: some View {
        group("Your data", "lock.fill", .teal) {
            row("Everything stays on this Mac",
                detail: "Only speech and text you choose to transcribe or summarise is sent to Grok.") {
                Button("Show in Finder") { model.revealDataFolder() }.buttonStyle(SecondaryButtonStyle())
            }
            row("Delete dictation history") {
                Button("Delete…") { confirmClear = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.entries.isEmpty)
            }
        }
    }
}
