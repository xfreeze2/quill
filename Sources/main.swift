import Cocoa
import AVFoundation
import IOKit.hid

// MARK: - Settings

enum Build {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

enum Defaults {
    static let language = "language"
    static let history = "history"
    static let cornerButton = "cornerButton"
    static let insertAtEnd = "insertAtEnd"
    static let clickToInsert = "clickToInsert"
    static let trigger = "trigger"
    static let singleTap = "singleTap"
    static let didShowSetup = "didShowSetup"
    static let stopPhrase = "stopPhrase"
    static let pauseSeconds = "pauseSeconds"
    static let polish = "polish"
    static let keepHistory = "keepHistory"
    static let notifyUpdates = "notifyUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let availableUpdateVersion = "availableUpdateVersion"
    static let availableUpdateURL = "availableUpdateURL"
    static let notifiedUpdateVersion = "notifiedUpdateVersion"
    static let liveTarget = "liveTarget"
    static let liveSource = "liveSource"
    static let liveLayout = "liveLayout"
    static let liveDoubleTap = "liveDoubleTap"
    static let liveHideFromCapture = "liveHideFromCapture"

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: "en",
            cornerButton: true,
            insertAtEnd: true,
            clickToInsert: true,
            trigger: Trigger.control.rawValue,
            singleTap: true,
            stopPhrase: true,
            pauseSeconds: 5.0,
            polish: false,
            keepHistory: true,
            notifyUpdates: true,
            liveTarget: "en",
            liveSource: "system",
            liveLayout: "both",
            liveDoubleTap: true,
            liveHideFromCapture: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// Seconds of silence that end a dictation. 0 turns it off.
    static var pause: TimeInterval {
        UserDefaults.standard.double(forKey: pauseSeconds)
    }

    static var currentTrigger: Trigger {
        Trigger(rawValue: UserDefaults.standard.string(forKey: trigger) ?? "") ?? .rightCommand
    }
    static func flip(_ key: String) { UserDefaults.standard.set(!bool(key), forKey: key) }
}

// MARK: - Session

/// One dictation, from the trigger to the words landing.
///
/// Everything that belongs to a single recording lives here, so a new dictation
/// can begin while the previous one is still waiting for its last words without
/// the two trampling each other. That used to happen through shared fields on
/// the app: the older session's completion cleared the client the newer one
/// was recording into, so the newer one could never be told to finish — it sat
/// on "Transcribing" until the socket timed out a minute later, and the words
/// were lost.
private final class Session {

    enum Phase {
        case recording      // microphone open, audio streaming
        case finalising     // stopped; waiting for the transcript tail
        case delivering     // transcript final; writing it into the target
    }

    enum StopReason {
        case hotkey     // trigger key or the pill — focus has not moved
        case click      // you clicked into the target — give focus a beat to settle
        case voice      // you said "that's it" — focus has not moved either
    }

    var phase: Phase = .recording
    var client: STTClient
    var stopReason: StopReason = .hotkey
    let selection: Inserter.Selection?
    let startedAt = Date()
    var finaliseStartedAt: Date?

    /// The corner panel belongs to the newest session. An older one that is
    /// still finishing inserts its words quietly rather than flashing "Inserted"
    /// over the top of a recording in progress.
    var ownsHUD = true

    // Audio. Everything captured is kept for the life of the session, so the
    // socket can be handed the backlog when it opens — however long that takes —
    // and so a reconnect can replay the whole dictation from the start.
    var socketReady = false
    var audio: [Data] = []
    var audioBytes = 0
    var sentChunks = 0
    var didReconnect = false

    // Transcript.
    var sawAnyText = false
    var lastActivityText: String?
    var lastVoiceAt = Date()
    var noiseFloor: Float = 0.02
    var lastStopCandidate: String?
    var pendingVoiceStop: DispatchWorkItem?

    // Voice commands.
    var didRunVoiceCommand = false
    /// Once "open Grok" has launched a session, clicks are for using that
    /// session (select, copy), not for picking a Quill destination.
    var deliverToOpenedGrok = false

    init(client: STTClient, selection: Inserter.Selection?) {
        self.client = client
        self.selection = selection
    }

    var isRecording: Bool { phase == .recording }
}

// MARK: - App

final class QuillApp: NSObject, NSApplicationDelegate {

    private let hotkey = DoubleTapRightCommand()
    private let recorder = Recorder()
    private let hud = HUD()
    private let live = LiveTranslation()

    /// The newest dictation — recording, or finishing and still owning the panel.
    private var session: Session?
    /// Older dictations displaced by a newer one, kept alive until their words
    /// have landed.
    private var superseded: [Session] = []

    private var isRecording: Bool { session?.isRecording ?? false }

    /// Five minutes of 16 kHz PCM16 — the most a recording is allowed to run.
    private static let maxAudioBytes = 16_000 * 2 * 320

    private var statusItem: NSStatusItem!
    private var pauseTimer: Timer?
    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?
    private var tickTimer: Timer?
    private var trustTimer: Timer?
    private var isTrusted = false

    /// QUILL_SELFTEST=<file.pcm> replaces the microphone with a 16 kHz mono PCM16
    /// file, so the socket → transcript → insert path can be verified headlessly.
    private let selfTestPath = ProcessInfo.processInfo.environment["QUILL_SELFTEST"]
    private var selfTestTimer: Timer?
    private var selfTestOverlapPending = ProcessInfo.processInfo.environment["QUILL_SELFTEST_OVERLAP"] != nil
    private let setup = SetupWindow()

    /// Grok STT's own list, plus Chinese.
    ///
    /// Chinese is absent from the language table inside the grok CLI, but the
    /// service transcribes it correctly — verified against the live endpoint with
    /// `language=zh`, with the parameter omitted, and even with `language=en`.
    /// The underlying model is evidently multilingual and that table is a UI
    /// subset, so leaving Chinese out would have been an artificial limit.
    private let languages: [(String, String)] = [
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()

        hud.onClick = { [weak self] in
            guard let self else { return }
            // Without Accessibility the keyboard trigger is dead and only this pill
            // works — which reads as "the shortcut is broken". Make the pill the
            // route to fixing it rather than a dead end.
            guard Inserter.isTrusted else {
                self.setup.show()
                return
            }
            self.toggle()
        }
        hud.showsIdlePill = Defaults.bool(Defaults.cornerButton)
        hud.install()

        hotkey.trigger = Defaults.currentTrigger
        applyTapMode()
        hotkey.onTrigger = { [weak self] in self?.toggle() }
        hotkey.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        hotkey.onClickAnywhere = { [weak self] point in self?.handleClickAnywhere(at: point) }
        hotkey.onCancel = { [weak self] in self?.handleEscape() }

        live.languages = languages.filter { $0.1 != "auto" }
        live.onStateChange = { [weak self] in
            self?.refreshIcon()
            self?.updateCancelWatch()
        }

        isTrusted = Inserter.isTrusted
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.write("launch — Quill \(Build.version) — AXIsProcessTrusted=\(isTrusted) inputMonitoring=\(inputMonitoring.rawValue) "
            + "trigger=\(Defaults.currentTrigger.gesture(singleTap: Defaults.bool(Defaults.singleTap))) "
            + "bundle=\(Bundle.main.bundlePath)")

        hotkey.onFirstEvent = { Log.write("event tap is LIVE — first event delivered") }
        hotkey.start()

        hud.setNeedsPermission(!isTrusted)

        if !isTrusted {
            // macOS happily creates a keyboard tap without Accessibility and then
            // never delivers an event to it — so tap creation succeeding proves
            // nothing. Ask, then watch for the grant and re-arm.
            Inserter.requestTrust()
            hud.apply(.notice("Turn on Quill in Privacy & Security ▸ Accessibility"))
            hud.collapse(after: 6)
        }

        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.applyTapMode()
            let now = Inserter.isTrusted
            guard now != self.isTrusted else { return }
            self.isTrusted = now
            self.hud.setNeedsPermission(!now)
            Log.write("Accessibility trust changed → \(now); re-arming event tap")
            self.hotkey.stop()
            self.hotkey.start()
            if now {
                self.hud.apply(.notice("Accessibility granted — \(Defaults.currentTrigger.gesture(singleTap: self.hotkey.singleTap)) is live"))
                self.hud.collapse(after: 2.5)
            }
        }
        refreshIcon()

        if let checkOnly = ProcessInfo.processInfo.environment["QUILL_TEST_UPDATE_CHECK"] {
            let force = checkOnly == "force"
            Updater.checkForUpdate(force: force) { result in
                switch result {
                case .success(let update):
                    FileHandle.standardError.write(Data("UPDATE RESULT: success update=\(String(describing: update.map { ($0.version, $0.url.absoluteString) }))\n".utf8))
                case .failure(let err):
                    FileHandle.standardError.write(Data("UPDATE RESULT: failure raw=\"\(err.message)\" display=\"\(err.displayMessage)\" isRateLimit=\(err.isRateLimit)\n".utf8))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        } else if let liveTest = ProcessInfo.processInfo.environment["QUILL_SELFTEST_LIVE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startLiveSelfTest(liveTest) }
        } else if selfTestPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.toggle() }
        } else {
            if Defaults.bool(Defaults.notifyUpdates) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.checkForUpdate(announce: true)
                }
            }
            let firstRun = !Defaults.bool(Defaults.didShowSetup)
            let missingSomething = !Inserter.isTrusted || Auth.current() == nil
                || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            if firstRun || missingSomething {
                UserDefaults.standard.set(true, forKey: Defaults.didShowSetup)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.setup.show()
                }
            }
        }
    }

    /// Single-tap needs Input Monitoring, and it is not optional.
    ///
    /// Without it the event tap receives modifier changes but NOT key presses, so
    /// there is no way to tell a bare ⌃ tap from ⌃C — and dictation would fire on
    /// every shortcut you press in a terminal. Measured, not assumed. Until it is
    /// granted, single-tap silently degrades to double-tap rather than misfiring.
    private var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private var loggedTapMode: Bool?

    private func applyTapMode() {
        let wanted = Defaults.bool(Defaults.singleTap)
        // Chords are now detected from the system's key-press counters, which are
        // not permission-gated, so single tap no longer depends on Input Monitoring.
        let safe = wanted
        hotkey.singleTap = safe
        hotkey.doubleTapEnabled = Defaults.bool(Defaults.liveDoubleTap)
        guard loggedTapMode != safe else { return }      // only on change, not every tick
        loggedTapMode = safe
        if wanted && !safe {
            Log.write("single-tap requested but Input Monitoring denied — using double-tap")
        } else if safe {
            Log.write("single tap is live")
        }
    }

    private func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quill")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Quill — double-tap right ⌘ to dictate"
    }

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        rightClick ? showMenu() : toggle()
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let name = isRecording ? "waveform.circle.fill" : (live.isRunning ? "translate" : "waveform")
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Quill")
        button.image?.isTemplate = !isRecording
        button.contentTintColor = isRecording ? .systemRed : nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let versionItem = NSMenuItem(title: "Quill \(Build.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        if let update = Updater.cachedUpdate() {
            let updateItem = NSMenuItem(title: "⬆︎ Update to \(update.version) available…",
                                        action: #selector(openUpdatePage), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let account = Auth.current()
        let headerText: String
        switch account?.source {
        case .apiKey:    headerText = "xAI API key · \(Keychain.redacted ?? "set")"
        case .grokBuild: headerText = "Grok Build · \(account?.email ?? "signed in")"
        case nil:        headerText = "Not signed in"
        }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: isRecording ? "Stop dictation" : "Start dictation",
                                    action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let hint = NSMenuItem(title: "\(Defaults.currentTrigger.gesture(singleTap: Defaults.bool(Defaults.singleTap))) anywhere",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        addLiveTranslationItems(to: menu)
        menu.addItem(.separator())

        let history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        do {
            let recent = NSMenu()
            recent.autoenablesItems = false
            for (index, entry) in history.prefix(8).enumerated() {
                let title = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
                let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                recent.addItem(item)
            }
            recent.addItem(.separator())
            let clear = NSMenuItem(title: "Clear recent", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            recent.addItem(clear)
            let keep = NSMenuItem(title: "Keep recent transcripts",
                                  action: #selector(toggleKeepHistory), keyEquivalent: "")
            keep.target = self
            keep.state = Defaults.bool(Defaults.keepHistory) ? .on : .off
            keep.toolTip = "Stored in preferences as plain text. Turn off if you dictate anything private."
            recent.addItem(keep)

            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            menu.addItem(recentItem)
            menu.setSubmenu(recent, for: recentItem)
            menu.addItem(.separator())
        }

        addToggle(to: menu, title: "Click anywhere to insert", key: Defaults.clickToInsert,
                  action: #selector(toggleClickToInsert))
        addToggle(to: menu, title: "Insert at end of field", key: Defaults.insertAtEnd,
                  action: #selector(toggleInsertAtEnd))
        addToggle(to: menu, title: "Clean up grammar", key: Defaults.polish,
                  action: #selector(togglePolish))
        addToggle(to: menu, title: "Stop when I say \u{201C}that\u{2019}s it\u{201D} or \u{201C}that\u{2019}s all\u{201D}", key: Defaults.stopPhrase,
                  action: #selector(toggleStopPhrase))

        let appearanceMenu = NSMenu()
        appearanceMenu.autoenablesItems = false
        addToggle(to: appearanceMenu, title: "Show idle pill", key: Defaults.cornerButton,
                  action: #selector(toggleCornerButton))
        let resetItem = NSMenuItem(title: "Reset panel position",
                                   action: #selector(resetPanelPosition), keyEquivalent: "")
        resetItem.target = self
        appearanceMenu.addItem(resetItem)
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        menu.addItem(appearanceItem)
        menu.setSubmenu(appearanceMenu, for: appearanceItem)

        let pauseMenu = NSMenu()
        pauseMenu.autoenablesItems = false
        let pauseOptions: [(String, Double)] = [
            ("Off", 0), ("After 2 seconds", 2.0), ("After 3 seconds", 3.0),
            ("After 5 seconds", 5.0), ("After 8 seconds", 8.0),
        ]
        let currentPause = Defaults.pause
        for (label, seconds) in pauseOptions {
            let item = NSMenuItem(title: label, action: #selector(setPause(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (abs(seconds - currentPause) < 0.01) ? .on : .off
            pauseMenu.addItem(item)
        }
        let pauseItem = NSMenuItem(title: "Finish when I stop talking", action: nil, keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.setSubmenu(pauseMenu, for: pauseItem)

        let triggerMenu = NSMenu()
        let activeTrigger = Defaults.currentTrigger
        for option in Trigger.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(setTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (option == activeTrigger) ? .on : .off
            if option == .f5 {
                item.toolTip = "F5 is the system Dictation key. It only reaches Quill if "
                    + "\"Use F1, F2 as standard function keys\" is on in Keyboard settings."
            }
            triggerMenu.addItem(item)
        }
        triggerMenu.addItem(.separator())
        let single = NSMenuItem(title: "Single tap (instead of double)",
                                action: #selector(toggleSingleTap), keyEquivalent: "")
        single.target = self
        single.state = Defaults.bool(Defaults.singleTap) ? .on : .off
        single.toolTip = "A tap only counts if nothing else is pressed while the key is held, "
            + "so ⌃C and friends never trigger it."
        triggerMenu.addItem(single)

        let triggerItem = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        menu.addItem(triggerItem)
        menu.setSubmenu(triggerMenu, for: triggerItem)

        let languageMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: Defaults.language) ?? "en"
        for (index, entry) in languages.enumerated() {
            let item = NSMenuItem(title: entry.0, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.1
            item.state = (entry.1 == current) ? .on : .off
            languageMenu.addItem(item)
            if index == 1 { languageMenu.addItem(.separator()) }
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.addItem(languageItem)
        menu.setSubmenu(languageMenu, for: languageItem)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let keyItem = NSMenuItem(title: Keychain.hasKey ? "Change xAI API key…" : "Use my own xAI API key…",
                                 action: #selector(editAPIKey), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)

        addToggle(to: menu, title: "Notify about updates", key: Defaults.notifyUpdates,
                  action: #selector(toggleNotifyUpdates))
        let checkItem = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdateNow), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)

        let setupItem = NSMenuItem(title: Inserter.isTrusted ? "Setup…" : "Finish setup…",
                                   action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let quit = NSMenuItem(title: "Quit Quill", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Double-tapping only exists as a separate gesture while the trigger is a
    /// single tap; in double-tap mode it already means "dictate".
    private var liveGestureAvailable: Bool {
        Defaults.bool(Defaults.singleTap) && Defaults.currentTrigger != .f5
    }

    private func addLiveTranslationItems(to menu: NSMenu) {
        let toggleItem = NSMenuItem(title: live.isRunning ? "Stop live translation" : "Start live translation",
                                    action: #selector(toggleLive), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        if liveGestureAvailable, Defaults.bool(Defaults.liveDoubleTap) {
            let hint = NSMenuItem(title: "Double-tap \(Defaults.currentTrigger.title) anywhere",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let liveMenu = NSMenu()
        liveMenu.autoenablesItems = false

        let targetItem = NSMenuItem(title: "Translate into", action: nil, keyEquivalent: "")
        liveMenu.addItem(targetItem)
        liveMenu.setSubmenu(live.targetMenu(), for: targetItem)

        let sourceItem = NSMenuItem(title: "Listen to", action: nil, keyEquivalent: "")
        liveMenu.addItem(sourceItem)
        liveMenu.setSubmenu(live.sourceMenu(), for: sourceItem)
        liveMenu.addItem(.separator())

        let only = NSMenuItem(title: "Show only the translation", action: #selector(toggleLiveLayout), keyEquivalent: "")
        only.target = self
        only.state = UserDefaults.standard.string(forKey: Defaults.liveLayout) == TranslatorPanel.Layout.translationOnly.rawValue ? .on : .off
        liveMenu.addItem(only)

        addToggle(to: liveMenu, title: "Hide from screen sharing", key: Defaults.liveHideFromCapture,
                  action: #selector(toggleLiveHidden))
        liveMenu.items.last?.toolTip = "Keeps the translation window out of screen shares and recordings."

        addToggle(to: liveMenu, title: "Double-tap \(Defaults.currentTrigger.title) to open", key: Defaults.liveDoubleTap,
                  action: #selector(toggleLiveDoubleTap))
        if !liveGestureAvailable {
            liveMenu.items.last?.isEnabled = false
            liveMenu.items.last?.toolTip = "Needs Trigger ▸ Single tap — in double-tap mode, a double tap is dictation."
        }
        liveMenu.addItem(.separator())

        let copy = NSMenuItem(title: "Copy last session", action: #selector(copyLiveSession), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = live.isRunning || live.lastSessionText != nil
        liveMenu.addItem(copy)

        let liveItem = NSMenuItem(title: "Live translation", action: nil, keyEquivalent: "")
        menu.addItem(liveItem)
        menu.setSubmenu(liveMenu, for: liveItem)
    }

    @objc private func toggleLive() { live.toggle() }
    @objc private func toggleLiveLayout() { live.toggleLayout() }

    @objc private func toggleLiveHidden() {
        Defaults.flip(Defaults.liveHideFromCapture)
        live.applyCapturePrivacy()
    }

    @objc private func toggleLiveDoubleTap() {
        Defaults.flip(Defaults.liveDoubleTap)
        applyTapMode()
    }

    @objc private func copyLiveSession() {
        live.copyLastSession()
        hud.apply(.notice("Live translation copied"))
        hud.collapse(after: 1.2)
    }

    func applicationWillTerminate(_ notification: Notification) {
        live.stop()
    }

    private func addToggle(to menu: NSMenu, title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = Defaults.bool(key) ? .on : .off
        menu.addItem(item)
    }

    // MARK: Menu actions

    @objc private func toggleInsertAtEnd()   { Defaults.flip(Defaults.insertAtEnd) }
    @objc private func toggleStopPhrase()    { Defaults.flip(Defaults.stopPhrase) }

    @objc private func togglePolish() {
        Defaults.flip(Defaults.polish)
        let on = Defaults.bool(Defaults.polish)
        Log.write("grammar cleanup \(on ? "on" : "off")")
        hud.apply(.notice(on
            ? "Grammar cleanup on — adds about a second, and never changes your wording"
            : "Grammar cleanup off"))
        hud.collapse(after: 3)
    }

    @objc private func setPause(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(seconds, forKey: Defaults.pauseSeconds)
        Log.write("pause-to-finish set to \(seconds)s")
        hud.apply(.notice(seconds == 0
            ? "Won't finish on its own — stop it yourself"
            : "Finishes after \(seconds == 1.5 ? "1.5" : String(Int(seconds))) seconds of silence"))
        hud.collapse(after: 2.5)
    }
    @objc private func toggleClickToInsert() { Defaults.flip(Defaults.clickToInsert) }
    @objc private func toggleLoginItem()     { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func setTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Trigger(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: Defaults.trigger)
        hotkey.trigger = option
        Log.write("trigger set to \(option.rawValue)")

        if option == .fnGlobe {
            // A bare 🌐 press normally shows emoji or switches input source; that
            // would fire twice on a double-tap. Point it at nothing.
            UserDefaults.standard.set(0, forKey: "AppleFnUsageType")
            let task = Process()
            task.launchPath = "/usr/bin/defaults"
            task.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
            try? task.run()
        }

        hud.apply(.notice("Trigger: \(option.gesture(singleTap: Defaults.bool(Defaults.singleTap)))"))
        hud.collapse(after: 2.5)
    }

    @objc private func toggleSingleTap() {
        Defaults.flip(Defaults.singleTap)
        let on = Defaults.bool(Defaults.singleTap)
        applyTapMode()
        Log.write("singleTap requested = \(on), effective = \(hotkey.singleTap)")

        hud.apply(.notice(Defaults.currentTrigger.gesture(singleTap: hotkey.singleTap)))
        hud.collapse(after: 2.5)
    }

    @objc private func resetPanelPosition() {
        hud.resetPosition()
    }

    @objc private func toggleCornerButton() {
        Defaults.flip(Defaults.cornerButton)
        let showing = Defaults.bool(Defaults.cornerButton)
        hud.showsIdlePill = showing
        Log.write("idle pill \(showing ? "shown" : "hidden")")

        if !showing {
            // With the pill gone there may be no visible affordance left — this
            // Mac's menu bar is often too full to show another item — so say how
            // to get it back before it disappears.
            hud.apply(.notice("Idle pill hidden. \(Defaults.currentTrigger.gesture(singleTap: hotkey.singleTap)) still works; the menu-bar icon brings it back."))
            hud.collapse(after: 6)
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: Defaults.language)
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        let history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        guard sender.tag < history.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history[sender.tag], forType: .string)
        hud.apply(.notice("Copied to clipboard"))
        hud.collapse(after: 1.2)
    }

    @objc private func openSetup() { setup.show() }

    @objc private func editAPIKey() { APIKeyPrompt.show() }

    /// `announce` shows a one-time toast the first time a given version is
    /// found, and only while nothing is being dictated — an update notice has
    /// no business interrupting a recording in progress.
    private func checkForUpdate(force: Bool = false, announce: Bool = false) {
        Updater.checkForUpdate(force: force) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if force {
                    self.hud.apply(.notice("Couldn't check for updates — \(error.displayMessage)"))
                    self.hud.collapse(after: 3)
                }
            case .success(let update):
                if force {
                    let text = update.map { "Quill \($0.version) is available" } ?? "You're on the latest version"
                    self.hud.apply(.notice(text))
                    self.hud.collapse(after: update == nil ? 2 : 5)
                }
                guard announce, let update, !self.isRecording else { return }
                let alreadyNotified = UserDefaults.standard.string(forKey: Defaults.notifiedUpdateVersion)
                guard alreadyNotified != update.version else { return }
                UserDefaults.standard.set(update.version, forKey: Defaults.notifiedUpdateVersion)
                self.hud.apply(.notice("Quill \(update.version) is available — see the menu"))
                self.hud.collapse(after: 5)
            }
        }
    }

    @objc private func checkForUpdateNow() { checkForUpdate(force: true) }

    @objc private func openUpdatePage() {
        guard let url = Updater.cachedUpdate()?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleNotifyUpdates() { Defaults.flip(Defaults.notifyUpdates) }

    @objc private func clearHistory() {
        UserDefaults.standard.removeObject(forKey: Defaults.history)
        Log.write("recent transcripts cleared")
        hud.apply(.notice("Recent transcripts cleared"))
        hud.collapse(after: 2)
    }

    @objc private func toggleKeepHistory() {
        Defaults.flip(Defaults.keepHistory)
        let on = Defaults.bool(Defaults.keepHistory)
        if !on { UserDefaults.standard.removeObject(forKey: Defaults.history) }
        Log.write("keep recent transcripts = \(on)")
        hud.apply(.notice(on ? "Keeping recent transcripts"
                             : "Not keeping transcripts — existing ones cleared"))
        hud.collapse(after: 2.5)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Session

    @objc private func toggle() {
        isRecording ? stopSession(reason: .hotkey) : startSession()
    }

    /// Two quick taps. The first already started a dictation — dictation never
    /// waits to see whether a second tap follows — so that recording was never
    /// meant, and is dropped without a trace before the translator opens.
    private func handleDoubleTap() {
        if let session, session.isRecording, Date().timeIntervalSince(session.startedAt) < 1.5 {
            Log.write("double tap — dropping the dictation its first tap began")
            leaveRecordingState(session, reason: .hotkey)
            session.client.cancel()
            release(session)
            hud.apply(.idle, animated: false)
        }
        Log.write("double tap — live translation \(live.isRunning ? "off" : "on")")
        live.toggle()
    }

    /// QUILL_SELFTEST_LIVE=<file.pcm> plays a 16 kHz mono PCM16 file through
    /// live translation; QUILL_SELFTEST_LIVE=system listens to what the Mac is
    /// playing for QUILL_SELFTEST_LIVE_SECONDS (default 30). Every translated
    /// sentence is printed, then a summary, then Quill quits. Saved settings are
    /// put back as they were.
    private func startLiveSelfTest(_ spec: String) {
        func out(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        let env = ProcessInfo.processInfo.environment
        // From the persistent domain, not object(forKey:) — that also answers
        // with registered defaults, and restoring those would pin them.
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let saved = [Defaults.liveTarget, Defaults.liveSource].map { ($0, stored[$0]) }

        if let target = env["QUILL_SELFTEST_LIVE_TARGET"] {
            UserDefaults.standard.set(target, forKey: Defaults.liveTarget)
        }
        var duration: TimeInterval
        if spec == "system" {
            UserDefaults.standard.set(LiveTranslation.Source.system.rawValue, forKey: Defaults.liveSource)
            duration = Double(env["QUILL_SELFTEST_LIVE_SECONDS"] ?? "") ?? 30
            out("LIVE SELFTEST: listening to system audio for \(Int(duration))s")
        } else {
            guard let file = PCMFileSource(path: spec) else {
                out("LIVE SELFTEST: cannot read \(spec)")
                NSApp.terminate(nil)
                return
            }
            live.sourceOverride = { file }
            duration = Double(file.seconds) + 8
            out("LIVE SELFTEST: playing \(file.seconds)s of audio from \(spec)")
        }

        live.capturableForTest = env["QUILL_SELFTEST_LIVE_CAPTURABLE"] != nil
        out("LIVE SELFTEST: system audio permission = \(SystemAudioPermission.status)")

        let began = Date()
        live.onSegmentTranslated = { segment in
            let at = String(format: "%5.1fs", Date().timeIntervalSince(began))
            out("LIVE \(at) [\(segment.language ?? "?")] \(segment.original)")
            out("              → \(segment.sameLanguage ? "(already in the target language)" : segment.translation)")
        }
        live.start()
        if let number = live.panelWindowNumber { out("LIVE PANEL WINDOW: \(number)") }

        // QUILL_SELFTEST_LIVE_SNAPSHOT=<dir>: the panel's pixels mid-sentence,
        // at the end, and at the end with only the translation showing.
        if let dir = env["QUILL_SELFTEST_LIVE_SNAPSHOT"] {
            let shots: [(TimeInterval, String, TranslatorPanel.Layout?)] = [
                (1.0, "empty", nil), (duration * 0.45, "mid", nil),
                (duration - 3.0, "both", nil), (duration - 2.0, "translation-only", .translationOnly),
            ]
            for (delay, name, layout) in shots {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let layout { self.live.setLayoutForTest(layout) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let path = (dir as NSString).appendingPathComponent("panel-\(name).png")
                        if let png = self.live.panelSnapshot(), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                            out("LIVE SNAPSHOT: \(path)")
                        } else {
                            out("LIVE SNAPSHOT FAILED: \(name)")
                        }
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            out("LIVE SUMMARY: segments=\(self.live.segmentCount) translated=\(self.live.translatedCount)")
            for (index, line) in self.live.shownLines.enumerated() {
                out("  \(index + 1). \(line.original)\n     → \(line.translation)")
            }
            if env["QUILL_SELFTEST_LIVE_HOLD"] == nil { self.live.stop() }
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            let hold = Double(env["QUILL_SELFTEST_LIVE_HOLD"] ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + hold) {
                self.live.stop()
                NSApp.terminate(nil)
            }
        }
    }

    private func handleClickAnywhere(at point: CGPoint) {
        let onPill = hud.contains(globalPoint: point)
        Log.write("click seen at \(Int(point.x)),\(Int(point.y)) — recording=\(isRecording) onPill=\(onPill)")
        guard isRecording, Defaults.bool(Defaults.clickToInsert) else { return }
        // A click on the pill is the pill's own business.
        guard !onPill else { return }
        stopSession(reason: .click)
    }

    private func startSession() {
        guard !isRecording else { return }

        // Grab the highlighted text now — clicking a destination later would
        // destroy it, and this is the only moment it is reliably present.
        let selection = Inserter.captureSelection()

        if selfTestPath != nil {
            beginCapture(replacing: selection)
            return
        }

        Recorder.micAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.hud.apply(.notice("Microphone access denied — enable Quill in Privacy & Security ▸ Microphone"))
                self.hud.collapse(after: 4)
                Inserter.openPrivacyPane("Privacy_Microphone")
                return
            }
            self.beginCapture(replacing: selection)
        }
    }

    private func beginCapture(replacing selection: Inserter.Selection?) {
        guard let creds = Auth.current() else {
            hud.apply(.notice("No Grok Build session found — run `grok` once to sign in"))
            hud.collapse(after: 4)
            return
        }

        let session = Session(client: STTClient(), selection: selection)

        // The previous dictation may still be waiting for its last words. It
        // keeps them and inserts them on its own; only the panel changes hands.
        if let previous = self.session {
            previous.ownsHUD = false
            superseded.append(previous)
            Log.write("previous dictation still \(previous.phase == .finalising ? "finalising" : "inserting") — it will land on its own")
        }
        self.session = session
        attach(session.client, to: session)

        // Open the connection while they are still talking: a cold request
        // measured ~1.9s against ~0.8s warm, which is the whole difference
        // between this feeling instant and feeling like a wait.
        if Defaults.bool(Defaults.polish) { Polisher.warm(token: creds.token) }

        session.client.connect(token: creds.token, language: currentLanguage)

        // Audio arrives on the capture thread. Everything that touches the
        // session happens on the main queue, so the flush-on-open and the live
        // stream can never race each other over the same buffer.
        recorder.onPCM = { [weak self, weak session] data in
            DispatchQueue.main.async {
                guard let self, let session, session.isRecording, session === self.session else { return }
                self.capture(data, for: session)
            }
        }
        recorder.onLevel = { [weak self, weak session] level in
            DispatchQueue.main.async {
                guard let self, let session, session.isRecording, session === self.session else { return }
                self.observe(level: level, for: session)
                self.hud.update(level: level)
            }
        }

        if let selfTestPath {
            startSelfTest(path: selfTestPath, for: session)
            return
        }

        do {
            try recorder.start()
        } catch {
            session.client.cancel()
            release(session)
            hud.apply(.notice(error.localizedDescription))
            hud.collapse(after: 3.5)
            return
        }

        enterRecordingState(session)
    }

    private var currentLanguage: String {
        UserDefaults.standard.string(forKey: Defaults.language) ?? "en"
    }

    /// Wires a socket to its session. Every callback checks that the socket is
    /// still the one the session is using — after a reconnect the old one may
    /// still have a message in flight — and that the session is still current
    /// before touching anything shared, like the panel.
    private func attach(_ client: STTClient, to session: Session) {
        client.onReady = { [weak self, weak session, weak client] in
            guard let self, let session, let client, client === session.client else { return }
            session.socketReady = true
            // Hand over everything this socket has not seen: the backlog that
            // piled up while it was connecting, or the whole dictation after a
            // reconnect.
            let backlog = session.audio[session.sentChunks...]
            for chunk in backlog { client.send(pcm: chunk) }
            session.sentChunks = session.audio.count
            if !backlog.isEmpty {
                Log.write("  flushed \(backlog.count) buffered chunks (\(backlog.reduce(0) { $0 + $1.count } / 32000)s)")
            }
            if session.didReconnect, session.ownsHUD, session.isRecording {
                self.hud.flashTarget("reconnected", for: 1.5)
            }
        }
        client.onText = { [weak self, weak session, weak client] text in
            guard let self, let session, let client, client === session.client, !text.isEmpty else { return }
            session.sawAnyText = true

            if session.isRecording {
                if !session.didRunVoiceCommand, VoiceCommands.containsOpenGrok(text) {
                    session.didRunVoiceCommand = true
                    self.runOpenGrok(for: session)
                }
                self.considerVoiceStop(session, after: text)
            }
            // Only NEW words count as activity. The server re-sends an unchanged
            // partial every couple of hundred milliseconds, so treating every
            // callback as speech kept the session alive forever.
            if text != session.lastActivityText {
                session.lastActivityText = text
                session.lastVoiceAt = Date()
            }

            // Show what will actually be inserted, command phrases already removed.
            if session.ownsHUD { self.hud.update(text: VoiceCommands.stripAll(text)) }
        }
        client.onComplete = { [weak self, weak session, weak client] text in
            guard let self, let session, let client, client === session.client else { return }
            self.finishSession(session, with: text)
        }
        client.onFailure = { [weak self, weak session, weak client] failure in
            guard let self, let session, let client, client === session.client else { return }
            self.handleFailure(session, failure)
        }
    }

    /// One chunk of 16 kHz PCM16 from the microphone (or the self-test file).
    private func capture(_ data: Data, for session: Session) {
        guard session.audioBytes < Self.maxAudioBytes else { return }
        session.audio.append(data)
        session.audioBytes += data.count
        if session.socketReady {
            session.client.send(pcm: data)
            session.sentChunks = session.audio.count
        }
    }

    private func enterRecordingState(_ session: Session) {
        refreshIcon()
        hud.apply(.listening)
        if let selection = session.selection {
            hud.flashTarget("replacing \(selection.range.length) selected characters", for: 3)
        }
        let front = Inserter.frontmostApp()
        hud.update(target: front.name, icon: front.icon)
        hotkey.watchClicks = Defaults.bool(Defaults.clickToInsert)
        hotkey.watchForCancel(true)
        startPauseWatch(session)
        Log.write("recording started — watchClicks=\(hotkey.watchClicks)")

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak session] _ in
            guard let self, let session, session.isRecording else { return }
            self.hud.update(elapsed: Date().timeIntervalSince(session.startedAt))
            let front = Inserter.frontmostApp()
            self.hud.update(target: front.name, icon: front.icon)
        }
        armSilenceWatch(session)
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, session.isRecording, session === self.session else { return }
            self.stopSession(reason: .hotkey)
        }
    }

    /// Nothing heard back after ten seconds. Which of four different failures
    /// that is matters: a dead microphone and a dead network used to be
    /// indistinguishable. If the audio side is healthy the socket gets one more
    /// chance — a fresh connection with the whole dictation replayed into it —
    /// before the session is given up on.
    private func armSilenceWatch(_ session: Session) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, session.isRecording, session === self.session, !session.sawAnyText else { return }
            self.logAudioState(session)
            if self.microphoneLooksHealthy, self.reconnect(session, why: "no transcript after 10s") {
                self.armSilenceWatch(session)
            } else {
                self.abortSession(session, message: self.diagnosis(session))
            }
        }
    }

    private var microphoneLooksHealthy: Bool {
        recorder.framesCaptured > 0 && recorder.peakLevel >= 0.004
    }

    /// Replace the socket without interrupting the recording. Once per session:
    /// if a second connection also fails, the problem is not transient.
    private func reconnect(_ session: Session, why: String) -> Bool {
        guard session.isRecording, !session.didReconnect, let creds = Auth.current() else { return false }
        session.didReconnect = true
        Log.write("reconnecting speech-to-text — \(why); replaying \(session.audioBytes / 32000)s of audio")

        session.client.cancel()
        let client = STTClient()
        session.client = client
        session.socketReady = false
        session.sentChunks = 0
        attach(client, to: session)
        client.connect(token: creds.token, language: currentLanguage)
        if session.ownsHUD { hud.flashTarget("reconnecting…", for: 4) }
        return true
    }

    private func startSelfTest(path: String, for session: Session) {
        guard let pcm = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("SELFTEST: cannot read \(path)\n".utf8))
            NSApp.terminate(nil)
            return
        }

        enterRecordingState(session)
        FileHandle.standardError.write(Data("SELFTEST: streaming \(pcm.count / 32000)s of audio\n".utf8))

        var offset = 0
        let chunk = 3200
        selfTestTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self, weak session] timer in
            guard let self, let session, session.isRecording else { timer.invalidate(); return }
            guard offset < pcm.count else {
                timer.invalidate()
                self.stopSession(reason: .hotkey)
                // QUILL_SELFTEST_OVERLAP: start the next dictation the instant
                // this one stops, while its transcript is still in flight — the
                // situation that used to strand both.
                if self.selfTestOverlapPending {
                    self.selfTestOverlapPending = false
                    FileHandle.standardError.write(Data("SELFTEST: starting a second dictation while the first finalises\n".utf8))
                    self.startSession()
                }
                return
            }
            let end = min(offset + chunk, pcm.count)
            self.capture(pcm.subdata(in: offset..<end), for: session)
            offset = end
        }
    }

    /// Why did nothing come back? "No speech detected" was covering four
    /// completely different failures, which made a broken microphone and a broken
    /// network indistinguishable.
    private func diagnosis(_ session: Session) -> String {
        if recorder.framesCaptured == 0 {
            return "No audio from the microphone — check Sound ▸ Input"
        }
        if recorder.peakLevel < 0.004 {
            return "Microphone is silent — wrong input device, or muted"
        }
        if !session.socketReady {
            return "Couldn't reach speech-to-text — check your connection"
        }
        return "Heard you, but no transcript came back"
    }

    private func logAudioState(_ session: Session) {
        Log.write("  audio: input=\(recorder.inputDescription) "
            + "frames=\(recorder.framesCaptured) peak=\(String(format: "%.4f", recorder.peakLevel)) "
            + "buffered=\(session.audioBytes / 32000)s socketReady=\(session.socketReady) sawText=\(session.sawAnyText)")
    }

    /// Opens Grok Build without interrupting the recording. Only fired when the
    /// transcript *starts* with the command, so the rest of that opening
    /// sentence can still become the prompt.
    private func runOpenGrok(for session: Session) {
        Log.write("voice command: open Grok")
        if session.ownsHUD { hud.flashTarget("opening Grok Build…", for: 8) }
        GrokLauncher.open { [weak self, weak session] outcome in
            guard let self, let session else { return }
            switch outcome {
            case .opened(let terminal):
                // A click in the new Grok window used to be treated as
                // "insert here", which posted ⌘V into the TUI and made
                // select/copy impossible. The destination is already Grok.
                session.deliverToOpenedGrok = true
                if session === self.session, session.isRecording { self.hotkey.watchClicks = false }
                Log.write("  click-to-insert off — Grok is the destination")
                if session.ownsHUD { self.hud.flashTarget("Grok Build opened in \(terminal)", for: 2) }
            case .failed(let message):
                Log.write("  open Grok failed — \(message)")
                if session.ownsHUD { self.hud.flashTarget("couldn't open Grok Build", for: 4) }
            }
        }
    }

    /// Stop when "that's it" is the last thing said — but only after a beat of
    /// silence, so a mid-sentence "that's it exactly" cannot cut someone off. Any
    /// further speech cancels the pending stop.
    private func considerVoiceStop(_ session: Session, after text: String) {
        if ProcessInfo.processInfo.environment["QUILL_TRACE_STOP"] != nil {
            Log.write("  tail? \"…\(String(text.suffix(20)))\" ends=\(VoiceCommands.endsWithStopPhrase(text)) "
                + "pending=\(session.pendingVoiceStop != nil)")
        }

        guard Defaults.bool(Defaults.stopPhrase), session.isRecording,
              VoiceCommands.endsWithStopPhrase(text)
        else {
            // Speech continued past the phrase, or the feature is off — stand down.
            session.pendingVoiceStop?.cancel()
            session.pendingVoiceStop = nil
            session.lastStopCandidate = nil
            return
        }

        // Only a CHANGE in what was said restarts the countdown. The server
        // re-sends an unchanged partial every couple of hundred milliseconds while
        // it works through the audio, and treating those as new speech pushed the
        // deadline back forever, so the stop never fired at all.
        if text == session.lastStopCandidate, session.pendingVoiceStop != nil { return }
        session.lastStopCandidate = text

        session.pendingVoiceStop?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, session.isRecording, session === self.session else { return }
            Log.write("voice stop: heard the finish phrase")
            self.hud.flashTarget("finishing…", for: 2)
            self.stopSession(reason: .voice)
        }
        session.pendingVoiceStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Escape is watched while there is something for it to close. It is never
    /// swallowed: the app underneath still gets it.
    private func updateCancelWatch() {
        hotkey.watchForCancel(isRecording || live.isRunning)
    }

    /// The newest thing goes first: a dictation in progress is thrown away, and
    /// only a later press closes the translator behind it.
    private func handleEscape() {
        if isRecording {
            cancelSession()
        } else if live.isRunning {
            Log.write("live translation closed by Escape")
            live.stop()
        }
    }

    /// Escape during a recording — throw it away, insert nothing.
    private func cancelSession() {
        guard let session, session.isRecording else { return }
        Log.write("cancelled by Escape")
        leaveRecordingState(session, reason: .hotkey)
        session.client.cancel()
        release(session)
        hud.apply(.notice("Cancelled"))
        hud.collapse(after: 0.9)
    }

    /// Finish once the microphone actually goes quiet.
    ///
    /// This used to watch the transcript instead, which was wrong: transcript
    /// updates lag speech and gap between segments, so after the server finalised
    /// one sentence no new text arrived for several seconds while the user was
    /// still mid-sentence — and the session ended under them.
    ///
    /// Silence now means both signals are quiet: nothing above the noise floor on
    /// the microphone, and no new words. Either one alone keeps the session open.
    /// Level is judged against a floor that adapts to the room, so a noisy
    /// environment does not read as constant speech and block the stop forever.
    private func observe(level: Float, for session: Session) {
        if level < session.noiseFloor {
            session.noiseFloor = session.noiseFloor * 0.90 + level * 0.10      // settle downward quickly
        } else {
            session.noiseFloor = session.noiseFloor * 0.995 + level * 0.005    // rise only slowly
        }
        if level > max(0.07, session.noiseFloor * 2.5) { session.lastVoiceAt = Date() }
    }

    private func startPauseWatch(_ session: Session) {
        pauseTimer?.invalidate()
        guard Defaults.pause > 0 else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak session] _ in
            guard let self, let session else { return }
            let quiet = Date().timeIntervalSince(session.lastVoiceAt)
            let window = Defaults.pause
            if ProcessInfo.processInfo.environment["QUILL_TRACE_STOP"] != nil {
                Log.write("  tick rec=\(session.isRecording) sawText=\(session.sawAnyText) "
                    + "quiet=\(String(format: "%.1f", quiet)) window=\(window)")
            }
            guard session.isRecording, session === self.session, session.sawAnyText, window > 0, quiet >= window else { return }
            Log.write("pause stop: \(String(format: "%.1f", quiet))s of silence")
            self.hud.flashTarget("finishing…", for: 2)
            self.stopSession(reason: .voice)
        }
    }

    /// Microphone off, timers down, clicks and Escape no longer watched. The
    /// session moves on to waiting for its transcript.
    private func leaveRecordingState(_ session: Session, reason: Session.StopReason) {
        session.phase = .finalising
        session.stopReason = reason
        session.finaliseStartedAt = Date()
        session.pendingVoiceStop?.cancel()
        session.pendingVoiceStop = nil
        hotkey.watchClicks = false
        updateCancelWatch()
        invalidateTimers()
        recorder.stop()
        refreshIcon()
    }

    private func stopSession(reason: Session.StopReason) {
        guard let session, session.isRecording else { return }
        leaveRecordingState(session, reason: reason)

        // Never discard the session just because no partial has arrived yet — on
        // the first recording the socket is often still connecting. Let it finish
        // and decide on the actual transcript instead.
        Log.write("stop (\(reason == .click ? "click" : (reason == .voice ? "voice" : "hotkey/pill"))) — finalising, sawText=\(session.sawAnyText)")
        logAudioState(session)
        hud.apply(.thinking)
        session.client.finish()
    }

    /// The stream died. While still recording, the first failure gets a fresh
    /// socket with the audio replayed; a second one ends the recording but keeps
    /// whatever words made it through rather than throwing them away.
    private func handleFailure(_ session: Session, _ failure: STTClient.Failure) {
        let heard = session.client.transcript
        Log.write("speech-to-text failed — \(failure.message) (phase=\(session.phase), heard \(heard.count) chars)")

        if session.isRecording {
            if failure != .unauthorized, reconnect(session, why: failure.message) { return }
            leaveRecordingState(session, reason: .hotkey)
            if !heard.isEmpty {
                if session.ownsHUD { hud.apply(.thinking) }
                finishSession(session, with: heard)
                return
            }
            abortSession(session, message: failure.message)
            return
        }

        // Already stopped: the words are final as far as the user is concerned.
        if !heard.isEmpty {
            finishSession(session, with: heard)
        } else {
            abortSession(session, message: failure.message)
        }
    }

    private func finishSession(_ session: Session, with text: String) {
        // A socket that dies mid-dictation completes with what it has; make sure
        // the microphone and the timers are not left running behind it.
        if session.isRecording { leaveRecordingState(session, reason: .hotkey) }
        session.phase = .delivering

        // The command phrase must never reach the target app.
        let trimmed = VoiceCommands.stripAll(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            release(session)
            if selfTestPath != nil {
                FileHandle.standardError.write(Data("SELFTEST RESULT: <empty> — \(diagnosis(session))\n".utf8))
                endSelfTestWhenIdle(after: 0.5)
            }
            guard session.ownsHUD else { return }
            if session.didRunVoiceCommand {
                hud.apply(.notice("Opened Grok Build"))
                hud.collapse(after: 1.6)
            } else {
                hud.apply(.notice(diagnosis(session)))
                hud.collapse(after: 4)
            }
            return
        }

        remember(trimmed)
        if session.ownsHUD { hud.update(text: trimmed) }

        guard Defaults.bool(Defaults.polish), let creds = Auth.current() else {
            completeSession(session, with: trimmed)
            return
        }

        // Show the raw words while the cleanup runs, so nothing appears to stall.
        if session.ownsHUD {
            hud.apply(.thinking)
            hud.update(text: trimmed)
        }
        Polisher.polish(trimmed, token: creds.token) { [weak self] result in
            self?.completeSession(session, with: result)
        }
    }

    /// Everything after the text is final, whichever way it got there. The
    /// self-test lives on this path too — routing it around the real one is how
    /// three separate features ended up appearing to pass while untested.
    private func completeSession(_ session: Session, with trimmed: String) {
        if selfTestPath != nil {
            FileHandle.standardError.write(Data("SELFTEST RESULT: \(trimmed)\n".utf8))
            // Lets a test wait for background work (e.g. launching Grok) to finish.
            let hold = Double(ProcessInfo.processInfo.environment["QUILL_SELFTEST_HOLD"] ?? "") ?? 0
            guard ProcessInfo.processInfo.environment["QUILL_SELFTEST_INSERT"] != nil else {
                if session.ownsHUD {
                    hud.apply(.delivered(nil))
                    hud.collapse(after: 0.7)
                }
                release(session)
                endSelfTestWhenIdle(after: 0.2 + hold)
                return
            }
            FileHandle.standardError.write(Data("SELFTEST FOCUS: \(Inserter.describeFocus())\n".utf8))
            Inserter.insert(trimmed,
                            atEndOfField: Defaults.bool(Defaults.insertAtEnd),
                            replacing: session.selection,
                            language: currentLanguage) { outcome in
                let method: String
                switch outcome.method {
                case .accessibility: method = "accessibility"
                case .clipboard:     method = "clipboard-fallback"
                case .blocked:       method = "BLOCKED (no Accessibility)"
                }
                self.hud.apply(.delivered(outcome.app))
                self.hud.update(text: trimmed)
                // Success is reported as soon as ⌘V is posted, so give the target
                // app a moment to actually apply it before reading back.
                Thread.sleep(forTimeInterval: 0.6)
                self.hud.collapse(after: 0.7)
                let readback = Inserter.focusedFieldValue() ?? "<field not readable>"
                FileHandle.standardError.write(Data("""
                SELFTEST METHOD: \(method) → \(outcome.app ?? "unknown app")
                SELFTEST FIELD NOW: \(readback)

                """.utf8))
                self.release(session)
                self.endSelfTestWhenIdle(after: 2.2)
            }
            return
        }

        deliver(session, trimmed)
    }

    /// The self-test quits once every dictation it started has finished — with
    /// QUILL_SELFTEST_OVERLAP there are two, and the first must not take the
    /// process down while the second is still waiting for its words.
    private func endSelfTestWhenIdle(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.session == nil, self.superseded.isEmpty else { return }
            NSApp.terminate(nil)
        }
    }

    /// Put the finished text into the focused app.
    private func deliver(_ session: Session, _ trimmed: String) {
        // After a click we wait a beat: the click still has to land, focus has to
        // settle, and the app has to place its caret before we write into it.
        let settle: TimeInterval = (session.stopReason == .click) ? 0.22 : 0.16
        if session.deliverToOpenedGrok {
            GrokLauncher.bringToFront()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            if session.deliverToOpenedGrok {
                GrokLauncher.bringToFront()
            }
            Inserter.insert(trimmed,
                            atEndOfField: Defaults.bool(Defaults.insertAtEnd),
                            replacing: session.selection,
                            language: self.currentLanguage) { outcome in
                switch outcome.method {
                case .accessibility, .clipboard:
                    if let started = session.finaliseStartedAt {
                        Log.write("  tail: stop → inserted in "
                            + String(format: "%.2fs", Date().timeIntervalSince(started)))
                    }
                    if session.ownsHUD {
                        self.hud.apply(.delivered(outcome.app))
                        self.hud.update(text: trimmed)
                        self.hud.collapse(after: 0.7)
                    } else if self.isRecording {
                        // A newer dictation is on screen; do not collapse it.
                        self.hud.flashTarget("previous dictation inserted", for: 1.5)
                    }
                case .blocked:
                    if session.ownsHUD {
                        self.hud.apply(.notice("Grant Accessibility to Quill so it can write into apps"))
                        self.hud.collapse(after: 4)
                    }
                    Inserter.requestTrust()
                }
                self.release(session)
            }
        }
    }

    private func abortSession(_ session: Session, message: String) {
        Log.write("aborted — \(message)")
        if session.isRecording { leaveRecordingState(session, reason: .hotkey) }
        session.client.cancel()
        release(session)
        if selfTestPath != nil {
            FileHandle.standardError.write(Data("SELFTEST ABORTED: \(message)\n".utf8))
            endSelfTestWhenIdle(after: 0.5)
        }
        guard session.ownsHUD else { return }
        hud.apply(.notice(message))
        hud.collapse(after: 4)
    }

    /// The session is over, one way or another. Forget it.
    private func release(_ session: Session) {
        if self.session === session { self.session = nil }
        superseded.removeAll { $0 === session }
    }

    private func invalidateTimers() {
        [silenceTimer, maxDurationTimer, tickTimer, selfTestTimer, pauseTimer].forEach { $0?.invalidate() }
        silenceTimer = nil
        maxDurationTimer = nil
        tickTimer = nil
        selfTestTimer = nil
        pauseTimer = nil
    }

    /// Recent dictations, for re-copying from the menu.
    ///
    /// These live in preferences, which is a plaintext plist — fine for a shopping
    /// list, less so if someone dictates something private. Hence the switch, and
    /// a way to wipe them.
    private func remember(_ text: String) {
        guard Defaults.bool(Defaults.keepHistory) else { return }
        var history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        history.insert(text, at: 0)
        UserDefaults.standard.set(Array(history.prefix(20)), forKey: Defaults.history)
    }
}

// MARK: - Login item

enum LoginItem {
    static let label = "com.freeze.quill"
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try? data?.write(to: URL(fileURLWithPath: plistPath))
        } else {
            try? fm.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = QuillApp()
app.delegate = delegate
app.run()
