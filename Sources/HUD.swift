import Cocoa

/// The corner surface. Always present, never takes focus.
///
/// Position is an anchor on the panel's bottom-right corner, stored and clamped
/// to the screen it lives on. It does not follow the mouse and it does not follow
/// the frontmost window — earlier it chased whichever screen the cursor was on,
/// which is what made it wander. Drag it anywhere; it stays put.
final class HUD {

    enum State {
        case idle
        case listening
        case thinking
        case delivered(String?)
        case notice(String)
    }

    private var panel: NSPanel?
    private let content = HUDView()
    private var collapseWork: DispatchWorkItem?
    private var state: State = .idle
    private var targetOverrideUntil: Date?

    private let compactSize = NSSize(width: 30, height: 30)
    private let expandedSize = NSSize(width: 396, height: 68)
    private let margin: CGFloat = 14


    var onClick: () -> Void = {}

    /// When off, the pill is gone entirely while idle — the session bar still
    /// appears for the duration of a dictation, and the menu-bar item and trigger
    /// key are untouched.
    var showsIdlePill = true {
        didSet {
            guard oldValue != showsIdlePill else { return }
            if case .idle = state { apply(.idle, animated: false) }
        }
    }

    func install() {
        let panel = ensurePanel()
        content.onClick = { [weak self] in self?.onClick() }
        content.onMoved = { [weak self] rect in self?.snapToEdge(from: rect) }
        apply(.idle, animated: false)
        panel.orderFrontRegardless()
    }

    /// Re-place the panel on the desktop that just became active.
    private func handleSpaceChange() {
        guard let panel else { return }
        if case .idle = state, !showsIdlePill {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame(compact: isCompactState), display: false)
        panel.orderFrontRegardless()
    }

    private var isCompactState: Bool {
        if case .idle = state { return true }
        return false
    }

    func setCornerButton(visible: Bool) {
        showsIdlePill = visible
    }

    func apply(_ newState: State, animated: Bool = true) {
        collapseWork?.cancel()
        state = newState

        let panel = ensurePanel()
        content.apply(state: newState)

        let compact: Bool
        if case .idle = newState { compact = true } else { compact = false }

        // While anything other than the idle pill is showing, the panel must be
        // completely transparent to the mouse. Otherwise it eats the very click
        // that is meant to choose where the words go — and it sits in the corner,
        // right on top of most apps' input boxes.
        panel.ignoresMouseEvents = !compact

        // Position it either way, so it is already in the right place the moment a
        // session starts — but stay hidden if the idle pill is switched off.
        let target = frame(compact: compact)
        if compact && !showsIdlePill {
            panel.setFrame(target, display: false)
            panel.orderOut(nil)
            return
        }
        panel.orderFrontRegardless()

        // No stretching across the screen. The docked edge is already fixed by
        // frame(), so the panel simply appears at its size and cross-fades — a
        // sweeping resize reads as a tail dragging over whatever is underneath.
        // A wide soft shadow makes a small faint pill read as a big grey blob;
        // the session panel earns one, the resting dot does not.
        panel.hasShadow = !compact
        panel.setFrame(target, display: true)

        // Fade toward whatever alpha this state actually wants. Animating to 1
        // unconditionally made the resting pill fully opaque instead of faint.
        let resting = content.restingAlpha
        if animated, panel.isVisible {
            content.alphaValue = max(0.25, resting * 0.45)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                content.animator().alphaValue = resting
            }
        } else {
            content.alphaValue = resting
        }
    }

    /// Amber pill = the keyboard trigger cannot work yet. Silent failure here is
    /// what makes a fresh install look broken.
    func setNeedsPermission(_ needed: Bool) {
        content.setNeedsPermission(needed)
        if case .idle = state { apply(.idle, animated: false) }
    }

    func update(text: String)      { content.setTranscript(text) }
    func update(level: Float)      { content.setLevel(level) }
    func update(elapsed: TimeInterval) { content.setElapsed(elapsed) }
    func update(target app: String?, icon: NSImage?) {
        guard Date() >= (targetOverrideUntil ?? .distantPast) else { return }
        content.setTarget(app, icon: icon)
    }

    /// Say something in the corner of the session bar for a moment, without
    /// leaving the listening state — the transcript keeps streaming underneath.
    func flashTarget(_ message: String, for seconds: TimeInterval = 2.5) {
        targetOverrideUntil = Date().addingTimeInterval(seconds)
        content.setTarget(message, icon: nil)
    }

    func collapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(.idle) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Is this CoreGraphics-global point on the panel? Used to tell a click on the
    /// pill apart from a click on the thing you want the text to land in.
    func contains(globalPoint: CGPoint) -> Bool {
        guard let panel, panel.isVisible, !panel.ignoresMouseEvents,
              let primary = NSScreen.screens.first else { return false }
        let flipped = NSPoint(x: globalPoint.x, y: primary.frame.maxY - globalPoint.y)
        return panel.frame.insetBy(dx: -6, dy: -6).contains(flipped)
    }

    // MARK: Geometry

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: compactSize),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content
        self.panel = panel

        // Follow the user to whatever desktop they switch to, rather than being
        // present on all of them at once. Joining every Space is what made it
        // visible on both sides of a four-finger swipe — it looked like a tail
        // stretched between desktops, and like the panel had never gone away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.handleSpaceChange()
            }
        return panel
    }

    /// Where the panel lives: an edge, plus how far down that edge.
    ///
    /// Docking to an edge rather than storing a free position is what stops it
    /// floating in the middle of the screen — and it fixes the expansion, which
    /// used to always grow leftwards regardless of where the pill was, sweeping a
    /// wide panel across whatever was underneath.
    enum Edge: String { case left, right }

    private static let edgeKey = "hudEdge"
    private static let offsetKey = "hudEdgeOffset"

    private var dockEdge: Edge {
        get { Edge(rawValue: UserDefaults.standard.string(forKey: Self.edgeKey) ?? "") ?? .right }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.edgeKey) }
    }

    /// Vertical centre of the panel, as a fraction of the screen's height.
    private var dockOffset: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: Self.offsetKey) as? Double
            return CGFloat(stored ?? 0.82)      // low, but clear of the dock
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.offsetKey) }
    }

    private static let screenKey = "hudScreen"

    /// The display the panel lives on. The one it was last dropped on wins, for
    /// as long as it is connected; otherwise wherever it was last drawn, then
    /// the main display. Before this was remembered, the panel came back on the
    /// main display after every relaunch, whatever you had chosen.
    private var homeScreen: NSScreen? {
        let chosen = UserDefaults.standard.object(forKey: Self.screenKey) as? UInt32
        let remembered = chosen.flatMap { id in NSScreen.screens.first { Self.displayID(of: $0) == id } }
        return remembered
            ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: lastCentreX, y: lastCentreY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }
    private var lastCentreX: CGFloat = 0
    private var lastCentreY: CGFloat = 0

    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.edgeKey)
        UserDefaults.standard.removeObject(forKey: Self.offsetKey)
        UserDefaults.standard.removeObject(forKey: Self.screenKey)
        UserDefaults.standard.removeObject(forKey: "hudAnchor")
        apply(state, animated: true)
    }

    /// Called when a drag finishes: pick the nearer edge and remember the height
    /// and the display.
    func snapToEdge(from frame: NSRect) {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        lastCentreX = centre.x
        lastCentreY = centre.y
        let screen = NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen, let id = Self.displayID(of: screen) else { return }
        let visible = screen.visibleFrame
        UserDefaults.standard.set(id, forKey: Self.screenKey)

        dockEdge = (centre.x - visible.minX) < (visible.maxX - centre.x) ? .left : .right
        let fraction = (visible.maxY - centre.y) / max(visible.height, 1)
        dockOffset = min(max(fraction, 0.04), 0.96)
        apply(state, animated: true)
    }

    private func frame(compact: Bool) -> NSRect {
        let size = compact ? compactSize : expandedSize
        guard let visible = homeScreen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }

        // The docked edge stays pinned; the panel only ever grows inward. That is
        // what keeps expanding from sweeping across the screen.
        let x = dockEdge == .left
            ? visible.minX + margin
            : visible.maxX - size.width - margin

        let centreY = visible.maxY - dockOffset * visible.height
        var rect = NSRect(x: x, y: centreY - size.height / 2, width: size.width, height: size.height)
        rect.origin.y = min(max(rect.origin.y, visible.minY + 6), visible.maxY - size.height - 6)

        lastCentreX = rect.midX
        lastCentreY = rect.midY
        if ProcessInfo.processInfo.environment["QUILL_TRACE_FRAME"] != nil {
            Log.write("  frame compact=\(compact) rect=\(NSStringFromRect(rect)) visible=\(NSStringFromRect(visible))")
        }
        return rect
    }

    /// Keeps a frame wholly inside one display — used while dragging.
    ///
    /// The display is the one under the pointer, not under the panel. Judging by
    /// the panel's own centre meant it was clamped inside the display it started
    /// on and its centre could never cross the boundary, so it could not be
    /// dragged to a second monitor at all (issue #5). Following the pointer, it
    /// hops across as soon as you do.
    static func confine(_ rect: NSRect, near pointer: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.min { a, b in
                distance(from: pointer, to: a.frame) < distance(from: pointer, to: b.frame)
            }
        guard let visible = screen?.visibleFrame else { return rect }
        var out = rect
        out.origin.x = min(max(out.origin.x, visible.minX + 4), visible.maxX - out.width - 4)
        out.origin.y = min(max(out.origin.y, visible.minY + 4), visible.maxY - out.height - 4)
        return out
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: -

private final class HUDView: NSView {

    var onClick: () -> Void = {}
    var onMoved: (NSRect) -> Void = { _ in }

    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let gloss = NSView()
    private let compact = NSView()
    private let expanded = NSView()

    private let glyph = NSImageView()

    private let dot = NSView()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let waveform = WaveformView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let targetIcon = NSImageView()
    private let transcriptLabel = NSTextField(labelWithString: "")

    private var hovering = false
    private var isIdle = true
    private var needsPermission = false

    /// What this view should settle at once any transition finishes. Deliberately
    /// faint while idle: the pill sits on screen all day and should read as
    /// something you can ignore, not something asking for attention.
    var restingAlpha: CGFloat {
        guard isIdle else { return 1 }
        if needsPermission { return hovering ? 1.0 : 0.85 }
        return hovering ? 0.9 : 0.20
    }
    private var dragOrigin: NSPoint?
    private var didDrag = false


    init() {
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        pin(blur, to: self)

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.90).cgColor
        tint.layer?.cornerCurve = .continuous
        tint.layer?.masksToBounds = true
        pin(tint, to: self)

        gloss.wantsLayer = true
        gloss.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        gloss.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gloss)
        NSLayoutConstraint.activate([
            gloss.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            gloss.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            gloss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            gloss.heightAnchor.constraint(equalToConstant: 1),
        ])

        // — compact —
        var config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        config = config.applying(.init(paletteColors: [.white]))
        glyph.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quill")?
            .withSymbolConfiguration(config)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        compact.addSubview(glyph)
        pin(compact, to: self)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: compact.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: compact.centerYAnchor),
        ])

        // — expanded —
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        waveform.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        targetLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        targetLabel.alignment = .right
        targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.translatesAutoresizingMaskIntoConstraints = false

        targetIcon.imageScaling = .scaleProportionallyDown
        targetIcon.translatesAutoresizingMaskIntoConstraints = false

        transcriptLabel.font = .systemFont(ofSize: 13, weight: .regular)
        transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        transcriptLabel.maximumNumberOfLines = 1
        transcriptLabel.lineBreakMode = .byTruncatingHead
        transcriptLabel.usesSingleLineMode = true
        transcriptLabel.wantsLayer = true
        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false

        // Labels must yield, always. A long transcript that resists compression
        // makes AppKit widen the window itself, which walked the panel off-screen.
        for label in [transcriptLabel, targetLabel, elapsedLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        [dot, elapsedLabel, waveform, targetIcon, targetLabel, transcriptLabel].forEach(expanded.addSubview)
        pin(expanded, to: self)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: expanded.leadingAnchor, constant: 16),
            dot.topAnchor.constraint(equalTo: expanded.topAnchor, constant: 15),

            elapsedLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            elapsedLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            waveform.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 12),
            waveform.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 14),
            waveform.trailingAnchor.constraint(lessThanOrEqualTo: targetIcon.leadingAnchor, constant: -12),
            waveform.widthAnchor.constraint(equalToConstant: 130),

            targetLabel.trailingAnchor.constraint(equalTo: expanded.trailingAnchor, constant: -16),
            targetLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            targetIcon.trailingAnchor.constraint(equalTo: targetLabel.leadingAnchor, constant: -6),
            targetIcon.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            targetIcon.widthAnchor.constraint(equalToConstant: 14),
            targetIcon.heightAnchor.constraint(equalToConstant: 14),

            transcriptLabel.leadingAnchor.constraint(equalTo: expanded.leadingAnchor, constant: 16),
            transcriptLabel.trailingAnchor.constraint(equalTo: expanded.trailingAnchor, constant: -16),
            transcriptLabel.bottomAnchor.constraint(equalTo: expanded.bottomAnchor, constant: -14),
            transcriptLabel.topAnchor.constraint(greaterThanOrEqualTo: dot.bottomAnchor, constant: 8),
        ])

    }

    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    override func layout() {
        super.layout()
        let radius = isIdle ? min(bounds.width, bounds.height) / 2 : 19
        blur.layer?.cornerRadius = radius
        tint.layer?.cornerRadius = radius
        gloss.isHidden = isIdle
        transcriptLabel.preferredMaxLayoutWidth = transcriptLabel.bounds.width
    }

    // MARK: State

    func apply(state: HUD.State) {
        switch state {
        case .idle:
            isIdle = true
            compact.isHidden = false
            expanded.isHidden = true
            stopPulse()
            waveform.reset()
            if needsPermission {
                glyph.contentTintColor = .systemOrange
                toolTip = "Quill needs Accessibility to use the keyboard trigger — click to fix"
            } else {
                glyph.contentTintColor = NSColor.white.withAlphaComponent(0.9)
                toolTip = "Tap the trigger key to dictate · drag to an edge"
            }

        case .listening:
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            startPulse()
            elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            elapsedLabel.stringValue = "0:00"
            elapsedLabel.isHidden = false
            waveform.isHidden = false
            transcriptLabel.stringValue = "Listening… click where the words should go"
            transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.38)

        case .thinking:
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopPulse()
            waveform.isHidden = true
            elapsedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            elapsedLabel.stringValue = "Transcribing"
            elapsedLabel.isHidden = false
            if transcriptLabel.stringValue.hasPrefix("Listening") {
                transcriptLabel.stringValue = ""
            }

        case .delivered(let app):
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            stopPulse()
            waveform.isHidden = true
            elapsedLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            elapsedLabel.stringValue = "Inserted"
            elapsedLabel.isHidden = false
            targetLabel.stringValue = app ?? ""
            targetIcon.isHidden = (targetIcon.image == nil)

        case .notice(let message):
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            stopPulse()
            waveform.isHidden = true
            elapsedLabel.isHidden = true
            targetLabel.stringValue = ""
            targetIcon.isHidden = true
            transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.78)
            transcriptLabel.stringValue = message
        }
        needsLayout = true
    }

    private func enterExpanded() {
        isIdle = false
        compact.isHidden = true
        expanded.isHidden = false
        alphaValue = 1
        toolTip = nil
    }

    func setNeedsPermission(_ needed: Bool) { needsPermission = needed }

    func setTranscript(_ text: String) {
        if ProcessInfo.processInfo.environment["QUILL_TRACE_FRAME"] != nil {
            Log.write("  setTranscript(\"\(text.prefix(40))\") idle=\(isIdle) "
                + "labelBounds=\(NSStringFromRect(transcriptLabel.bounds))")
        }
        guard !isIdle else { return }
        transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        transcriptLabel.stringValue = text
    }

    func setLevel(_ level: Float) { waveform.push(level) }

    func setElapsed(_ seconds: TimeInterval) {
        guard !isIdle else { return }
        let whole = Int(seconds)
        elapsedLabel.stringValue = String(format: "%d:%02d", whole / 60, whole % 60)
    }

    func setTarget(_ app: String?, icon: NSImage?) {
        guard !isIdle else { return }
        targetLabel.stringValue = app ?? ""
        targetIcon.image = icon
        targetIcon.isHidden = (icon == nil)
    }

    private func startPulse() {
        guard dot.layer?.animation(forKey: "pulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.2
        animation.duration = 0.72
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(animation, forKey: "pulse")
    }

    private func stopPulse() {
        dot.layer?.removeAnimation(forKey: "pulse")
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if isIdle { animator().alphaValue = restingAlpha }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if isIdle { animator().alphaValue = restingAlpha }
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - origin.x
        let dy = now.y - origin.y
        if !didDrag && (abs(dx) + abs(dy)) < 3 { return }
        didDrag = true

        var frame = window.frame
        frame.origin = NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy)
        window.setFrame(HUD.confine(frame, near: now), display: true)
        dragOrigin = now
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        if didDrag {
            onMoved(window?.frame ?? .zero)
        } else {
            onClick()
        }
        didDrag = false
    }
}

// MARK: -

/// A rolling, mirrored level meter. Smoothed so speech reads as a shape rather
/// than a flicker.
final class WaveformView: NSView {

    private var samples = [CGFloat](repeating: 0, count: 34)
    private var smoothed: CGFloat = 0

    func push(_ level: Float) {
        let value = max(0, min(1, CGFloat(level)))
        smoothed = smoothed * 0.62 + value * 0.38
        samples.removeFirst()
        samples.append(smoothed)
        needsDisplay = true
    }

    func reset() {
        samples = [CGFloat](repeating: 0, count: samples.count)
        smoothed = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 2.5
        let spacing = (bounds.width - CGFloat(samples.count) * barWidth) / CGFloat(samples.count - 1)
        let midY = bounds.midY

        for (index, sample) in samples.enumerated() {
            // Newest on the right; older samples recede rather than vanish.
            let recency = CGFloat(index) / CGFloat(samples.count - 1)
            let alpha = 0.14 + 0.66 * recency
            NSColor.white.withAlphaComponent(alpha).setFill()

            let height = max(barWidth, bounds.height * (0.10 + 0.90 * sample))
            let rect = NSRect(x: CGFloat(index) * (barWidth + spacing),
                              y: midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
