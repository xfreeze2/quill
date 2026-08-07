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

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: "en",
            cornerButton: true,
            insertAtEnd: true,
            clickToInsert: true,
            trigger: Trigger.control.rawValue,
            singleTap: true,
            stopPhrase: true,
            pauseSeconds: 3.0,
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

// MARK: - App

final class QuillApp: NSObject, NSApplicationDelegate {

    private enum StopReason {
        case hotkey     // trigger key or the pill — focus has not moved
        case click      // you clicked into the target — give focus a beat to settle
        case voice      // you said "that's it" — focus has not moved either
    }

    private let hotkey = DoubleTapRightCommand()
    private let recorder = Recorder()
    private let hud = HUD()
    private var stt: STTClient?

    private var statusItem: NSStatusItem!
    private var isRecording = false
    private var pendingPCM: [Data] = []
    private var socketReady = false
    private var sawAnyText = false
    private var stopReason: StopReason = .hotkey
    private var didRunVoiceCommand = false
    private var finaliseStartedAt: Date?
    private var pendingVoiceStop: DispatchWorkItem?
    private var lastStopCandidate: String?
    private var pendingPauseStop: DispatchWorkItem?
    private var lastPauseCandidate: String?
    private var capturedSelection: Inserter.Selection?
    private var startedAt: Date?

    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?
    private var tickTimer: Timer?
    private var trustTimer: Timer?
    private var isTrusted = false

    /// QUILL_SELFTEST=<file.pcm> replaces the microphone with a 16 kHz mono PCM16
    /// file, so the socket → transcript → insert path can be verified headlessly.
    private let selfTestPath = ProcessInfo.processInfo.environment["QUILL_SELFTEST"]
    private var selfTestTimer: Timer?
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
        hotkey.onClickAnywhere = { [weak self] point in self?.handleClickAnywhere(at: point) }
        hotkey.onCancel = { [weak self] in self?.cancelSession() }

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

        if selfTestPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.toggle() }
        } else {
            let firstRun = !Defaults.bool(Defaults.didShowSetup)
            let missingSomething = !Inserter.isTrusted || Auth.load() == nil
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
        let name = isRecording ? "waveform.circle.fill" : "waveform"
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

        let account = Auth.load()
        let headerTitle: String = {
            guard let account else { return "xAI · not signed in" }
            switch account.source {
            case .subscription: return "Grok Build · \(account.displayName)"
            case .apiKey:       return "xAI · \(account.displayName)"
            }
        }()
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
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

        let history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        if !history.isEmpty {
            let recent = NSMenu()
            for (index, entry) in history.prefix(8).enumerated() {
                let title = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
                let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                recent.addItem(item)
            }
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            menu.addItem(recentItem)
            menu.setSubmenu(recent, for: recentItem)
            menu.addItem(.separator())
        }

        addToggle(to: menu, title: "Click anywhere to insert", key: Defaults.clickToInsert,
                  action: #selector(toggleClickToInsert))
        addToggle(to: menu, title: "Insert at end of field", key: Defaults.insertAtEnd,
                  action: #selector(toggleInsertAtEnd))
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
            ("Off", 0), ("After 1.5 seconds", 1.5), ("After 3 seconds", 3.0), ("After 5 seconds", 5.0),
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

    private func addToggle(to menu: NSMenu, title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = Defaults.bool(key) ? .on : .off
        menu.addItem(item)
    }

    // MARK: Menu actions

    @objc private func toggleInsertAtEnd()   { Defaults.flip(Defaults.insertAtEnd) }
    @objc private func toggleStopPhrase()    { Defaults.flip(Defaults.stopPhrase) }

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

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Session

    @objc private func toggle() {
        isRecording ? stopSession(reason: .hotkey) : startSession()
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
        capturedSelection = Inserter.captureSelection()

        if selfTestPath != nil {
            beginCapture()
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
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard let creds = Auth.load() else {
            hud.apply(.notice("No xAI credentials — run `grok login`, or set XAI_API_KEY / ~/.config/xai/api_key"))
            hud.collapse(after: 4)
            return
        }

        let client = STTClient()
        stt = client
        pendingPCM = []
        socketReady = false
        sawAnyText = false
        stopReason = .hotkey
        didRunVoiceCommand = false
        lastStopCandidate = nil
        lastPauseCandidate = nil

        client.onReady = { [weak self] in
            guard let self else { return }
            self.socketReady = true
            for chunk in self.pendingPCM { client.send(pcm: chunk) }
            self.pendingPCM = []
        }
        client.onText = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.sawAnyText = true

            if !self.didRunVoiceCommand, VoiceCommands.containsOpenGrok(text) {
                self.didRunVoiceCommand = true
                self.runOpenGrok()
            }

            self.considerVoiceStop(after: text)
            self.armPauseStop(after: text)

            // Show what will actually be inserted, command phrases already removed.
            self.hud.update(text: VoiceCommands.stripAll(text))
        }
        client.onComplete = { [weak self] text in self?.finishSession(with: text) }
        client.onFailure = { [weak self] failure in self?.abortSession(message: failure.message) }

        client.connect(token: creds.token,
                       language: UserDefaults.standard.string(forKey: Defaults.language) ?? "en")

        recorder.onPCM = { [weak self] data in
            guard let self else { return }
            if self.socketReady { client.send(pcm: data) }
            else if self.pendingPCM.count < 200 { self.pendingPCM.append(data) }
        }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.update(level: level) }
        }

        if let selfTestPath {
            startSelfTest(path: selfTestPath, client: client)
            return
        }

        do {
            try recorder.start()
        } catch {
            stt?.cancel()
            stt = nil
            hud.apply(.notice(error.localizedDescription))
            hud.collapse(after: 3.5)
            return
        }

        enterRecordingState()
    }

    private func enterRecordingState() {
        isRecording = true
        startedAt = Date()
        refreshIcon()
        hud.apply(.listening)
        if let selection = capturedSelection {
            hud.flashTarget("replacing \(selection.range.length) selected characters", for: 3)
        }
        let front = Inserter.frontmostApp()
        hud.update(target: front.name, icon: front.icon)
        hotkey.watchClicks = Defaults.bool(Defaults.clickToInsert)
        hotkey.watchForCancel(true)
        Log.write("recording started — watchClicks=\(hotkey.watchClicks)")

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.hud.update(elapsed: Date().timeIntervalSince(startedAt))
            let front = Inserter.frontmostApp()
            self.hud.update(target: front.name, icon: front.icon)
        }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.isRecording, !self.sawAnyText else { return }
            self.logAudioState()
            self.abortSession(message: self.diagnosis())
        }
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.stopSession(reason: .hotkey)
        }
    }

    private func startSelfTest(path: String, client: STTClient) {
        guard let pcm = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("SELFTEST: cannot read \(path)\n".utf8))
            NSApp.terminate(nil)
            return
        }

        enterRecordingState()
        FileHandle.standardError.write(Data("SELFTEST: streaming \(pcm.count / 32000)s of audio\n".utf8))

        var offset = 0
        let chunk = 3200
        selfTestTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard offset < pcm.count else {
                timer.invalidate()
                self.stopSession(reason: .hotkey)
                return
            }
            let end = min(offset + chunk, pcm.count)
            let slice = pcm.subdata(in: offset..<end)
            if self.socketReady { client.send(pcm: slice) } else { self.pendingPCM.append(slice) }
            offset = end
        }
    }

    /// Why did nothing come back? "No speech detected" was covering four
    /// completely different failures, which made a broken microphone and a broken
    /// network indistinguishable.
    private func diagnosis() -> String {
        if recorder.framesCaptured == 0 {
            return "No audio from the microphone — check Sound ▸ Input"
        }
        if recorder.peakLevel < 0.004 {
            return "Microphone is silent — wrong input device, or muted"
        }
        if !socketReady {
            return "Couldn't reach speech-to-text — check your connection"
        }
        return "Heard you, but no transcript came back"
    }

    private func logAudioState() {
        Log.write("  audio: input=\(recorder.inputDescription) "
            + "frames=\(recorder.framesCaptured) peak=\(String(format: "%.4f", recorder.peakLevel)) "
            + "socketReady=\(socketReady) sawText=\(sawAnyText)")
    }

    /// Opens Grok Build without interrupting the recording — the mic keeps running
    /// so the rest of the sentence still becomes the prompt.
    private func runOpenGrok() {
        Log.write("voice command: open Grok")
        hud.flashTarget("opening Grok Build…", for: 8)
        GrokLauncher.open { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .opened(let terminal):
                self.hud.flashTarget("Grok Build opened in \(terminal)", for: 2)
            case .failed(let message):
                Log.write("  open Grok failed — \(message)")
                self.hud.flashTarget("couldn't open Grok Build", for: 4)
            }
        }
    }

    /// Stop when "that's it" is the last thing said — but only after a beat of
    /// silence, so a mid-sentence "that's it exactly" cannot cut someone off. Any
    /// further speech cancels the pending stop.
    private func considerVoiceStop(after text: String) {
        if ProcessInfo.processInfo.environment["QUILL_TRACE_STOP"] != nil {
            Log.write("  tail? \"…\(String(text.suffix(20)))\" ends=\(VoiceCommands.endsWithStopPhrase(text)) "
                + "pending=\(pendingVoiceStop != nil)")
        }

        guard Defaults.bool(Defaults.stopPhrase), isRecording,
              VoiceCommands.endsWithStopPhrase(text)
        else {
            // Speech continued past the phrase, or the feature is off — stand down.
            pendingVoiceStop?.cancel()
            pendingVoiceStop = nil
            lastStopCandidate = nil
            return
        }

        // Only a CHANGE in what was said restarts the countdown. The server
        // re-sends an unchanged partial every couple of hundred milliseconds while
        // it works through the audio, and treating those as new speech pushed the
        // deadline back forever, so the stop never fired at all.
        if text == lastStopCandidate, pendingVoiceStop != nil { return }
        lastStopCandidate = text

        pendingVoiceStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            Log.write("voice stop: heard the finish phrase")
            self.hud.flashTarget("finishing…", for: 2)
            self.stopSession(reason: .voice)
        }
        pendingVoiceStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Escape during a recording — throw it away, insert nothing.
    private func cancelSession() {
        guard isRecording else { return }
        Log.write("cancelled by Escape")
        isRecording = false
        pendingVoiceStop?.cancel()
        pendingVoiceStop = nil
        pendingPauseStop?.cancel()
        pendingPauseStop = nil
        hotkey.watchClicks = false
        hotkey.watchForCancel(false)
        invalidateTimers()
        recorder.stop()
        stt?.cancel()
        stt = nil
        refreshIcon()
        hud.apply(.notice("Cancelled"))
        hud.collapse(after: 0.9)
    }

    /// Finish once the words stop arriving.
    ///
    /// Silence is judged by the transcript going quiet rather than by microphone
    /// level, because a noisy room keeps the level up while nobody is speaking.
    /// The timer only restarts when the words actually change, so a server
    /// re-sending an unchanged partial cannot hold the session open forever.
    private func armPauseStop(after text: String) {
        let window = Defaults.pause
        guard window > 0, isRecording, !text.isEmpty, text != lastPauseCandidate else { return }
        lastPauseCandidate = text

        pendingPauseStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            Log.write("pause stop: \(String(format: "%.1f", window))s without new speech")
            self.hud.flashTarget("finishing…", for: 2)
            self.stopSession(reason: .voice)
        }
        pendingPauseStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
    }

    private func stopSession(reason: StopReason) {
        guard isRecording else { return }
        isRecording = false
        stopReason = reason
        pendingVoiceStop?.cancel()
        pendingVoiceStop = nil
        pendingPauseStop?.cancel()
        pendingPauseStop = nil
        hotkey.watchClicks = false
        hotkey.watchForCancel(false)
        invalidateTimers()
        recorder.stop()
        refreshIcon()

        // Never discard the session just because no partial has arrived yet — on
        // the first recording the socket is often still connecting. Let it finish
        // and decide on the actual transcript instead.
        Log.write("stop (\(reason == .click ? "click" : (reason == .voice ? "voice" : "hotkey/pill"))) — finalising, sawText=\(sawAnyText)")
        finaliseStartedAt = Date()
        logAudioState()
        hud.apply(.thinking)
        stt?.finish()
    }

    private func finishSession(with text: String) {
        stt = nil
        // The command phrase must never reach the target app.
        let trimmed = VoiceCommands.stripAll(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if didRunVoiceCommand {
                hud.apply(.notice("Opened Grok Build"))
                hud.collapse(after: 1.6)
            } else {
                hud.apply(.notice(diagnosis()))
                hud.collapse(after: 4)
            }
            return
        }

        remember(trimmed)
        hud.update(text: trimmed)

        if selfTestPath != nil {
            FileHandle.standardError.write(Data("SELFTEST RESULT: \(trimmed)\n".utf8))
            // Lets a test wait for background work (e.g. launching Grok) to finish.
            let hold = Double(ProcessInfo.processInfo.environment["QUILL_SELFTEST_HOLD"] ?? "") ?? 0
            guard ProcessInfo.processInfo.environment["QUILL_SELFTEST_INSERT"] != nil else {
                hud.apply(.delivered(nil))
                hud.collapse(after: 0.7)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + hold) { NSApp.terminate(nil) }
                return
            }
            FileHandle.standardError.write(Data("SELFTEST FOCUS: \(Inserter.describeFocus())\n".utf8))
            let testSelection = self.capturedSelection
            self.capturedSelection = nil
            Inserter.insert(trimmed,
                            atEndOfField: Defaults.bool(Defaults.insertAtEnd),
                            replacing: testSelection) { outcome in
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { NSApp.terminate(nil) }
            }
            return
        }

        // After a click we wait a beat: the click still has to land, focus has to
        // settle, and the app has to place its caret before we write into it.
        let settle: TimeInterval = (stopReason == .click) ? 0.22 : 0.16

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            let selection = self.capturedSelection
            self.capturedSelection = nil
            Inserter.insert(trimmed,
                            atEndOfField: Defaults.bool(Defaults.insertAtEnd),
                            replacing: selection) { outcome in
                switch outcome.method {
                case .accessibility, .clipboard:
                    if let started = self.finaliseStartedAt {
                        Log.write("  tail: stop → inserted in "
                            + String(format: "%.2fs", Date().timeIntervalSince(started)))
                    }
                    self.hud.apply(.delivered(outcome.app))
                    self.hud.update(text: trimmed)
                    self.hud.collapse(after: 0.7)
                case .blocked:
                    self.hud.apply(.notice("Grant Accessibility to Quill so it can write into apps"))
                    self.hud.collapse(after: 4)
                    Inserter.requestTrust()
                }
            }
        }
    }

    private func abortSession(message: String) {
        Log.write("aborted — \(message)")
        isRecording = false
        pendingVoiceStop?.cancel()
        pendingVoiceStop = nil
        pendingPauseStop?.cancel()
        pendingPauseStop = nil
        hotkey.watchClicks = false
        hotkey.watchForCancel(false)
        invalidateTimers()
        recorder.stop()
        stt?.cancel()
        stt = nil
        refreshIcon()
        hud.apply(.notice(message))
        hud.collapse(after: 4)
    }

    private func invalidateTimers() {
        [silenceTimer, maxDurationTimer, tickTimer, selfTestTimer].forEach { $0?.invalidate() }
        silenceTimer = nil
        maxDurationTimer = nil
        tickTimer = nil
        selfTestTimer = nil
    }

    private func remember(_ text: String) {
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
