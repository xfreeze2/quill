import Cocoa
import AVFoundation

/// First-run setup.
///
/// Everything Quill needs is a system permission that only the user can grant, and
/// each one fails silently in its own way: without Accessibility the keyboard
/// trigger is created but never fed, without the microphone the engine starts and
/// hears nothing, without a Grok session there is no token to transcribe with.
/// Left to discover on their own, people conclude the app is broken.
///
/// So: state every requirement up front, show live whether it is met, and put the
/// button that fixes it next to the thing that is wrong.
final class SetupWindow: NSObject, NSWindowDelegate {

    private let monitor = MicMonitor()
    private var window: NSWindow?
    private var refresh: Timer?
    private var rows: [Row] = []
    private let footer = NSTextField(labelWithString: "")

    /// Called when every requirement is satisfied.
    var onReady: () -> Void = {}

    // MARK: Requirements

    private enum Requirement: CaseIterable {
        case microphone
        case accessibility
        case grokSession

        var title: String {
            switch self {
            case .microphone:    return "Microphone"
            case .accessibility: return "Accessibility"
            case .grokSession:
                return Keychain.hasKey ? "xAI API key" : "Grok sign-in or API key"
            }
        }

        var detail: String {
            switch self {
            case .microphone:
                return "So Quill can hear you."
            case .accessibility:
                return "So the trigger key works, and so Quill can type into other apps."
            case .grokSession:
                return "Sign in to the grok command-line tool once, or use your own xAI API key."
            }
        }

        var actionTitle: String? {
            switch self {
            case .microphone:    return "Allow"
            case .accessibility: return "Open Settings"
            case .grokSession:   return "Use a key"
            }
        }

        var isSatisfied: Bool {
            switch self {
            case .microphone:
                return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .accessibility:
                return AXIsProcessTrusted()
            case .grokSession:
                return Auth.current() != nil
            }
        }

        /// Extra reassurance once it is met — e.g. which account is signed in.
        var satisfiedNote: String? {
            switch self {
            case .grokSession:
                guard let creds = Auth.current() else { return nil }
                switch creds.source {
                case .apiKey:    return "Your own key — \(Keychain.redacted ?? "stored in Keychain")"
                case .grokBuild: return creds.email ?? "Signed in"
                }
            default:
                return nil
            }
        }
    }

    // MARK: Presentation

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            update()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Set up Quill"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = buildContent()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        update()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refresh?.invalidate()
        refresh = nil
        monitor.stop()
    }

    private func buildContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 430))

        let title = NSTextField(labelWithString: "Quill")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Speak anywhere. The text lands where you point.  ·  v\(Build.version)")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for requirement in Requirement.allCases {
            let row = Row(requirement: requirement) { [weak self] in
                self?.perform(requirement)
            }
            rows.append(row)
            stack.addArrangedSubview(row.view)
            row.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 2
        footer.translatesAutoresizingMaskIntoConstraints = false

        [title, subtitle, stack, footer].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            stack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])

        return root
    }

    // MARK: Behaviour

    private func perform(_ requirement: Requirement) {
        switch requirement {
        case .microphone:
            // notDetermined shows the system prompt; denied can only be undone in Settings.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { self.update() }
                }
            } else {
                Inserter.openPrivacyPane("Privacy_Microphone")
            }
        case .accessibility:
            Inserter.requestTrust()
            Inserter.openPrivacyPane("Privacy_Accessibility")
        case .grokSession:
            APIKeyPrompt.show()
            update()
        }
    }

    private func update() {
        // A live meter answers "is my microphone actually working" before the user
        // has to find out the hard way, mid-sentence.
        if Requirement.microphone.isSatisfied {
            monitor.onLevel = { [weak self] level in
                self?.rows.first { $0.requirement == .microphone }?.showLevel(level)
            }
            monitor.start()
        } else {
            monitor.stop()
        }

        var allGood = true
        for row in rows {
            let satisfied = row.requirement.isSatisfied
            row.apply(satisfied: satisfied, note: satisfied ? row.requirement.satisfiedNote : nil)
            if !satisfied { allGood = false }
        }

        let gesture = Defaults.currentTrigger.gesture(singleTap: Defaults.bool(Defaults.singleTap))
        if allGood {
            footer.stringValue = "You're set. \(gesture) to start talking, then click where you want the words."
            footer.textColor = .secondaryLabelColor
            onReady()
        } else {
            footer.stringValue = "Quill can't work until the items above are green. Nothing else is needed."
            footer.textColor = .secondaryLabelColor
        }
    }

    // MARK: Row

    private final class Row {
        let requirement: Requirement
        let view = NSView()

        private let mark = NSTextField(labelWithString: "○")
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let button = NSButton()
        private let meter = NSLevelIndicator()
        private let action: () -> Void

        init(requirement: Requirement, action: @escaping () -> Void) {
            self.requirement = requirement
            self.action = action

            view.translatesAutoresizingMaskIntoConstraints = false

            mark.font = .systemFont(ofSize: 15, weight: .bold)
            mark.translatesAutoresizingMaskIntoConstraints = false

            title.stringValue = requirement.title
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.translatesAutoresizingMaskIntoConstraints = false

            detail.stringValue = requirement.detail
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            button.bezelStyle = .rounded
            button.title = requirement.actionTitle ?? ""
            button.isHidden = (requirement.actionTitle == nil)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = #selector(tapped)

            meter.levelIndicatorStyle = .continuousCapacity
            meter.minValue = 0
            meter.maxValue = 1
            meter.isHidden = true
            meter.translatesAutoresizingMaskIntoConstraints = false

            [mark, title, detail, button, meter].forEach(view.addSubview)

            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                mark.topAnchor.constraint(equalTo: view.topAnchor),
                mark.widthAnchor.constraint(equalToConstant: 18),

                title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
                title.topAnchor.constraint(equalTo: view.topAnchor),

                button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                button.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),

                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                detail.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                meter.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                meter.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
                meter.widthAnchor.constraint(equalToConstant: 90),
                meter.heightAnchor.constraint(equalToConstant: 10),
            ])
        }

        @objc private func tapped() { action() }

        func apply(satisfied: Bool, note: String?) {
            mark.stringValue = satisfied ? "✓" : "○"
            mark.textColor = satisfied ? .systemGreen : .tertiaryLabelColor
            button.isHidden = satisfied || requirement.actionTitle == nil
            if satisfied, let note {
                detail.stringValue = note
            } else if satisfied {
                detail.stringValue = requirement == .microphone
                    ? "Say something — the bar should move."
                    : "Granted."
            } else {
                detail.stringValue = requirement.detail
            }
            meter.isHidden = !(satisfied && requirement == .microphone)
        }

        func showLevel(_ level: Float) {
            guard !meter.isHidden else { return }
            meter.doubleValue = Double(min(1, level * 3))
        }
    }
}


// MARK: -

/// Input level only — nothing is recorded, streamed or kept. Runs solely while
/// the setup window is open.
private final class MicMonitor {

    private var engine: AVAudioEngine?
    var onLevel: (Float) -> Void = { _ in }

    var isRunning: Bool { engine != nil }

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += channels[0][i] * channels[0][i] }
            let rms = sqrt(sum / Float(n))
            DispatchQueue.main.async { self?.onLevel(rms) }
        }

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
