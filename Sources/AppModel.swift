import SwiftUI
import AVFoundation

/// Everything the Quill window shows, and the actions behind it.
///
/// The menu-bar app, the dictation hotkey and the translator keep working exactly
/// as before; this is the layer that remembers what they did and lets you look
/// back at it, plus the meeting notes.
final class AppModel: ObservableObject {

    static let shared = AppModel()

    enum Section: String, CaseIterable, Identifiable {
        case home, history, meetings, vocabulary, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home:       return "Home"
            case .history:    return "Dictations"
            case .meetings:   return "Meetings"
            case .vocabulary: return "Vocabulary"
            case .settings:   return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .home:       return "house"
            case .history:    return "text.quote"
            case .meetings:   return "person.2.wave.2"
            case .vocabulary: return "character.book.closed"
            case .settings:   return "gearshape"
            }
        }

        var shortcut: Character {
            switch self {
            case .home: return "1"
            case .history: return "2"
            case .meetings: return "3"
            case .vocabulary: return "4"
            case .settings: return ","
            }
        }
    }

    /// What the Mac currently allows, and who is signed in.
    struct Access: Equatable {
        var accessibility = true
        var microphone: AVAuthorizationStatus = .authorized
        var systemAudio: SystemAudioPermission.Status = .granted
        var account: String? = "Signed in"
        var updateVersion: String?

        var isComplete: Bool { accessibility && microphone == .authorized && account != nil }
    }

    // MARK: State

    @Published var section: Section = .home
    @Published private(set) var entries: [DictationEntry] = []
    @Published private(set) var stats = DictationStats()
    @Published private(set) var meetings: [Meeting] = []
    @Published var selectedMeetingID: UUID?
    /// The "new meeting" screen is showing, rather than a meeting.
    @Published var composingMeeting = false
    @Published private(set) var session: MeetingSession?
    @Published private(set) var summarizing: Set<UUID> = []
    @Published var snippets: [Snippet] = Snippets.load()
    @Published private(set) var access = Access()
    @Published private(set) var tick = 0
    @Published var toast: String?

    let history: DictationHistory
    let store: MeetingStore

    /// Called when a meeting starts or stops, so the menu-bar icon can follow.
    var onRecordingChange: () -> Void = {}

    /// What the window asks of the rest of the app — the parts that live with the
    /// menu bar, the hotkey and the translator.
    struct Bridge {
        var toggleLive: () -> Void = {}
        var openSetup: () -> Void = {}
        var editAPIKey: () -> Void = {}
        var checkForUpdates: () -> Void = {}
        var openUpdatePage: () -> Void = {}
        var resetPanelPosition: () -> Void = {}
        var toggleDictation: () -> Void = {}
    }
    var bridge = Bridge()
    @Published var liveRunning = false

    private(set) var isQuitting = false
    private var pollTimer: Timer?
    private var secondTimer: Timer?
    private var toastWork: DispatchWorkItem?

    init(historyURL: URL = DictationHistory.defaultURL(), meetingsDirectory: URL = MeetingStore.defaultDirectory()) {
        history = DictationHistory(url: historyURL)
        store = MeetingStore(directory: meetingsDirectory)
    }

    // MARK: Launch

    /// Once, at launch, before anything records: bring old data forward and close
    /// whatever a crash left open.
    func prepare() {
        importOldRecents()
        for meeting in store.closeInterrupted() {
            AudioArchive.recover(folder: store.folder(for: meeting.id))
            if store.hasAudio(meeting.id), !meeting.hasAudio {
                var fixed = meeting
                fixed.hasAudio = true
                store.save(fixed)
            }
            Log.write("meeting \(meeting.id) was cut short — kept \(meeting.utterances.count) remarks")
        }
        for var meeting in store.all() {
            var changed = false
            // A summary that was being written when Quill quit is not still being written.
            if meeting.summaryState == .working {
                meeting.summaryState = .failed
                meeting.summaryError = "The summary was interrupted. Try again."
                changed = true
            }
            // A recording that couldn't be finished last time gets another go.
            let folder = store.folder(for: meeting.id)
            if AudioArchive.hasLeftovers(folder: folder), AudioArchive.recover(folder: folder), !meeting.hasAudio {
                meeting.hasAudio = true
                changed = true
            }
            if changed { store.save(meeting) }
        }
        reloadHistory()
        reloadMeetings()
        refreshAccess()
    }

    /// Before the History screen, the last twenty dictations lived in preferences.
    private func importOldRecents() {
        let defaults = UserDefaults.standard
        guard let old = defaults.stringArray(forKey: Defaults.history) else { return }
        defer { defaults.removeObject(forKey: Defaults.history) }
        guard history.entries.isEmpty else { return }
        let now = Date()
        // Oldest first, so the newest ends up on top.
        for (index, text) in old.enumerated().reversed() {
            history.add(text: text, date: now.addingTimeInterval(-Double(index + 1)))
        }
        Log.write("moved \(old.count) recent dictations into the history")
    }

    // MARK: Dictation history

    func reloadHistory() {
        entries = history.entries
        stats = history.stats()
    }

    /// Returns an id so the app it landed in can be added once known.
    @discardableResult
    func recordDictation(_ text: String, seconds: Double?) -> UUID? {
        guard Defaults.bool(Defaults.keepHistory) else { return nil }
        let id = history.add(text: text, seconds: seconds)
        reloadHistory()
        return id
    }

    func noteApp(_ id: UUID?, _ app: String?) {
        guard let id, let app, !app.isEmpty else { return }
        history.setApp(id, app)
        reloadHistory()
    }

    func deleteEntry(_ id: UUID) {
        history.remove(id)
        reloadHistory()
    }

    func clearHistory() {
        history.clear()
        reloadHistory()
    }

    func copy(_ text: String, message: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(toast: message)
    }

    // MARK: Snippets

    func setSnippets(_ list: [Snippet]) {
        snippets = list
        Snippets.save(list)
    }

    // MARK: Meetings

    func reloadMeetings() {
        meetings = store.all()
        if let selected = selectedMeetingID, !meetings.contains(where: { $0.id == selected }), session?.meeting.id != selected {
            selectedMeetingID = nil
        }
    }

    func meeting(_ id: UUID) -> Meeting? {
        if let session, session.meeting.id == id { return session.meeting }
        return meetings.first { $0.id == id }
    }

    var isRecordingMeeting: Bool { session?.isActive ?? false }
    /// A meeting that is recording, or still finishing after Stop.
    var hasMeetingSession: Bool { session != nil }

    func startMeeting(capture: MeetingCapture, keepAudio: Bool, language: String,
                      testSources: MeetingSession.Sources? = nil) {
        guard session == nil else {
            if let id = session?.meeting.id { openMeeting(id) }
            show(toast: isRecordingMeeting ? "A meeting is already being recorded." : "Finishing the last meeting — one moment.")
            return
        }
        if testSources == nil, Auth.current() == nil {
            show(toast: "Sign in to Grok, or add an xAI API key in Settings, before taking notes.", seconds: 6)
            return
        }
        let new = MeetingSession(store: store, capture: capture, keepAudio: keepAudio, language: language,
                                 testSources: testSources)
        new.onChange = { [weak self] in self?.sessionChanged() }
        new.onFinished = { [weak self] meeting in self?.sessionFinished(meeting) }
        session = new
        composingMeeting = false
        selectedMeetingID = new.meeting.id
        section = .meetings
        startSecondTimer()
        new.start()
        onRecordingChange()
    }

    func stopMeeting() {
        session?.stop()
    }

    /// Quitting mid-meeting: close the recording properly and keep what was said,
    /// but leave the summary for next time, when there's no rush.
    func finishBeforeQuit(_ done: @escaping () -> Void) {
        guard let session else { done(); return }
        isQuitting = true
        if session.phase == .starting {
            session.stop()
            done()
            return
        }
        let previous = session.onFinished
        session.onFinished = { meeting in
            previous(meeting)
            done()
        }
        if session.isActive { session.stop() }
    }

    private func sessionChanged() {
        objectWillChange.send()
        if case .failed(let message) = session?.phase {
            let id = session?.meeting.id
            session = nil
            if let id { store.delete(id) }
            selectedMeetingID = nil
            composingMeeting = true
            show(toast: message, seconds: 8)
            onRecordingChange()
        }
    }

    private func sessionFinished(_ meeting: Meeting) {
        session = nil
        reloadMeetings()
        selectedMeetingID = meeting.id
        onRecordingChange()
        stopSecondTimerIfIdle()
        if isQuitting { return }
        if meeting.wordCount >= 8, Defaults.bool(Defaults.meetingAutoSummarize), Auth.current() != nil {
            summarize(meeting.id)
        } else if meeting.wordCount < 8 {
            show(toast: "Not much was said, so there's no summary.")
        }
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var current = meetings.first(where: { $0.id == id }) else { return }
        let before = current
        change(&current)
        guard current != before else { return }
        store.save(current)
        if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = current }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if session?.meeting.id == id { session?.rename(trimmed); objectWillChange.send(); return }
        update(id) { $0.title = trimmed; $0.titleIsAutomatic = false }
    }

    func setNotes(_ id: UUID, _ text: String) {
        if session?.meeting.id == id { session?.setNotes(text); return }
        update(id) { $0.userNotes = text }
    }

    func nameSpeaker(_ id: UUID, voice: String, as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { meeting in
            if trimmed.isEmpty { meeting.speakerNames.removeValue(forKey: voice) } else { meeting.speakerNames[voice] = trimmed }
            meeting.suggestedNames.removeValue(forKey: voice)
        }
    }

    func acceptSuggestions(_ id: UUID) {
        update(id) { meeting in
            for (voice, name) in meeting.suggestedNames { meeting.speakerNames[voice] = name }
            meeting.suggestedNames = [:]
        }
    }

    func dismissSuggestions(_ id: UUID) {
        update(id) { $0.suggestedNames = [:] }
    }

    func toggleAction(_ meetingID: UUID, _ itemID: UUID) {
        update(meetingID) { meeting in
            guard var summary = meeting.summary, let index = summary.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            summary.actionItems[index].done.toggle()
            meeting.summary = summary
        }
    }

    func deleteMeeting(_ id: UUID) {
        store.delete(id)
        if selectedMeetingID == id { selectedMeetingID = nil }
        reloadMeetings()
    }

    func deleteRecording(_ id: UUID) {
        try? FileManager.default.removeItem(at: store.audioURL(for: id))
        update(id) { $0.hasAudio = false }
        show(toast: "Recording deleted. The transcript is kept.")
    }

    func summarize(_ id: UUID) {
        guard !summarizing.contains(id), let current = meetings.first(where: { $0.id == id }) else { return }
        guard Auth.current() != nil else {
            update(id) { $0.summaryState = .failed; $0.summaryError = "Sign in to Grok or add an API key in Settings to get a summary." }
            return
        }
        update(id) { $0.summaryState = .working; $0.summaryError = nil }
        summarizing.insert(id)
        MeetingSummarizer.summarize(current) { [weak self] result in
            guard let self else { return }
            self.summarizing.remove(id)
            self.update(id) { meeting in
                switch result {
                case .success(let parsed):
                    meeting.summary = parsed.summary
                    meeting.summaryState = .ready
                    meeting.summaryError = nil
                    if let title = parsed.title, meeting.titleIsAutomatic { meeting.title = title }
                    meeting.suggestedNames = SummaryParser.suggestions(parsed.speakers, for: meeting)
                case .failure(let failure):
                    meeting.summaryState = failure == .tooShort ? .none : .failed
                    meeting.summaryError = failure.message
                }
            }
        }
    }

    // MARK: Exporting

    func markdown(for id: UUID) -> String? {
        meeting(id).map { MeetingMarkdown.render($0) }
    }

    func revealDataFolder() {
        NSWorkspace.shared.open(AppSupport.directory)
    }

    // MARK: Toasts and timers

    func show(toast message: String, seconds: Double = 2.2) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func startSecondTimer() {
        guard secondTimer == nil else { return }
        secondTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick &+= 1
            if !self.isRecordingMeeting { self.stopSecondTimerIfIdle() }
        }
    }

    private func stopSecondTimerIfIdle() {
        guard !isRecordingMeeting else { return }
        secondTimer?.invalidate()
        secondTimer = nil
    }

    // MARK: Permissions

    /// While the window is on screen, noticing a permission granted in System
    /// Settings should not need a restart.
    func startMonitoring() {
        refreshAccess()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAccess() }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refreshAccess() {
        var next = Access()
        next.accessibility = Inserter.isTrusted
        next.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        next.systemAudio = SystemAudioPermission.isSupported ? SystemAudioPermission.status : .denied
        if let creds = Auth.current() {
            switch creds.source {
            case .apiKey:    next.account = "xAI API key · \(Keychain.redacted ?? "set")"
            case .grokBuild: next.account = creds.email ?? "Grok subscription"
            }
        } else {
            next.account = nil
        }
        next.updateVersion = Updater.cachedUpdate()?.version
        if next != access { access = next }
    }
}

// MARK: - Navigation helpers

extension AppModel {

    func open(_ section: Section) {
        self.section = section
    }

    func openMeeting(_ id: UUID) {
        selectedMeetingID = id
        composingMeeting = false
        section = .meetings
    }

    func newMeeting() {
        if let id = session?.meeting.id {
            openMeeting(id)
        } else {
            selectedMeetingID = nil
            composingMeeting = true
            section = .meetings
        }
    }
}
