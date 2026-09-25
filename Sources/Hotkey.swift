import Cocoa
import QuartzCore

/// The global trigger. Bare modifier taps are used deliberately: a modifier
/// pressed on its own means nothing to macOS or to any app, so a double-tap can
/// never shadow a shortcut in whatever you are typing into — including Grok
/// Build's own Ctrl+Space.
enum Trigger: String, CaseIterable {
    case rightCommand
    case rightOption
    case control
    case fnGlobe
    case f5

    var title: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .rightOption:  return "Right ⌥"
        case .control:      return "Control ⌃"
        case .fnGlobe:      return "🌐 (fn)"
        case .f5:           return "F5"
        }
    }

    /// How to describe the gesture, given the single/double setting.
    func gesture(singleTap: Bool) -> String {
        guard self != .f5 else { return "Press F5" }
        return (singleTap ? "Tap " : "Double-tap ") + title
    }

    var shortTitle: String {
        switch self {
        case .rightCommand: return "⌘⌘"
        case .rightOption:  return "⌥⌥"
        case .control:      return "⌃"
        case .fnGlobe:      return "🌐"
        case .f5:           return "F5"
        }
    }

    /// Accepted keyCodes + the flag that means "this key is down".
    /// Control matches BOTH controls: MacBook keyboards have no right Control at
    /// all, so a right-only match would simply never fire on this machine.
    var modifier: (keyCodes: Set<Int64>, flag: CGEventFlags)? {
        switch self {
        case .rightCommand: return ([54], .maskCommand)
        case .rightOption:  return ([61], .maskAlternate)
        case .control:      return ([59, 62], .maskControl)
        case .fnGlobe:      return ([63], .maskSecondaryFn)
        case .f5:           return nil
        }
    }
}

/// Watches the whole system for the trigger, and for the click that ends a
/// recording.
///
/// This is an ACTIVE tap that returns events untouched, not a listen-only one.
/// Behaviourally identical, but the permission differs: listen-only taps require
/// Input Monitoring, active taps run on the Accessibility grant. Listen-only made
/// macOS prompt for a permission that does not even appear in the Accessibility
/// list, and until it was granted the tap silently received nothing.
final class DoubleTapRightCommand {

    private let window: CFTimeInterval = 0.42
    private static let f5KeyCode: Int64 = 96
    private static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private var tap: CFMachPort?
    private var lastTapAt: CFTimeInterval = 0
    private var sawKeyDownSinceTap = false
    private var loggedFirstEvent = false

    var trigger: Trigger = .rightCommand

    /// Fire on a single quick tap rather than a double-tap. Safe because a tap is
    /// only counted when the key goes down and back up with no other key pressed
    /// in between and inside `tapMaxHold` — so ⌃C, ⌃E and friends never trigger it.
    var singleTap = false
    private let tapMaxHold: CFTimeInterval = 0.35
    private var pressedAt: CFTimeInterval = 0
    private var activityAtPress: UInt64 = 0

    /// Total input activity the system has seen. Sampling this at press and at
    /// release tells us whether ANYTHING was done while the modifier was held —
    /// i.e. whether this was a chord — WITHOUT needing to observe the events
    /// themselves. Unlike reading key events, these counters are not
    /// permission-gated, which is what lets single-tap work without Input
    /// Monitoring.
    ///
    /// Clicks and scrolls are counted too: ⌃-click is the right-click gesture and
    /// ⌃-scroll is screen zoom. Neither moves a key counter, and both would
    /// otherwise look exactly like a bare tap.
    private static let watchedActivity: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    private static func activityCounter() -> UInt64 {
        var total: UInt64 = 0
        for type in watchedActivity {
            total &+= UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: type))
            total &+= UInt64(CGEventSource.counterForEventType(.hidSystemState, eventType: type))
        }
        return total
    }
    /// Off unless QUILL_DEBUG_KEYS is set — this would otherwise leave a keystroke
    /// trail on disk, which a dictation tool has no business doing.
    private let debugKeys = ProcessInfo.processInfo.environment["QUILL_DEBUG_KEYS"] != nil
        || UserDefaults.standard.bool(forKey: "debugKeys")
    var onTrigger: () -> Void = {}
    var onFirstEvent: () -> Void = {}

    /// Two quick taps in single-tap mode. The first of them has already been
    /// delivered through `onTrigger`, so the handler is responsible for undoing it.
    var onDoubleTap: () -> Void = {}
    var doubleTapEnabled = false
    private var sequence = TapSequence()

    /// A click anywhere on screen, in CoreGraphics global coordinates. Only
    /// delivered while `watchClicks` is set — that is what lets a recording stop
    /// itself the moment you click where the text should go.
    var onClickAnywhere: (CGPoint) -> Void = { _ in }
    var watchClicks = false

    /// Escape pressed during a recording or with live translation open.
    var onCancel: () -> Void = {}

    private static let escapeKeyCode: Int64 = 53
    private var cancelTimer: Timer?
    private var escapeWasDown = false

    /// Escape is watched two ways, because either can be unavailable.
    ///
    /// The event tap only receives key presses when Input Monitoring has been
    /// granted, which Quill deliberately does not require. `CGEventSource.keyState`
    /// asks the hardware whether a key is down and is not gated behind that
    /// permission, so polling it covers the common case. Whichever notices first
    /// wins; a flag stops the cancel firing twice.
    ///
    /// Asking for what is already the case changes nothing, and a press that is
    /// already down when watching starts belongs to whatever came before — so the
    /// one press that cancels a dictation cannot go on to close the translator.
    func watchForCancel(_ on: Bool) {
        guard on != (cancelTimer != nil) else { return }
        cancelTimer?.invalidate()
        cancelTimer = nil
        escapeWasDown = on && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.escapeKeyCode))
        guard on else { return }

        cancelTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self else { return }
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.escapeKeyCode))
            if down, !self.escapeWasDown {
                self.escapeWasDown = true
                DispatchQueue.main.async { self.onCancel() }
            } else if !down {
                self.escapeWasDown = false
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                var swallow = false
                if let refcon {
                    swallow = Unmanaged<DoubleTapRightCommand>.fromOpaque(refcon)
                        .takeUnretainedValue()
                        .handle(type, event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        loggedFirstEvent = false
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        tap = nil
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if !loggedFirstEvent {
            loggedFirstEvent = true
            DispatchQueue.main.async { [weak self] in self?.onFirstEvent() }
        }

        // macOS disables a tap that is slow or gets interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }

        if type == .leftMouseDown {
            guard watchClicks else { return false }
            let location = event.location
            DispatchQueue.main.async { [weak self] in self?.onClickAnywhere(location) }
            return false
        }

        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)

            // Only meaningful when Input Monitoring happens to be granted; the
            // keyState poll above covers everyone else.
            if code == Self.escapeKeyCode, cancelTimer != nil, !escapeWasDown {
                escapeWasDown = true
                DispatchQueue.main.async { [weak self] in self?.onCancel() }
                return false
            }
            let bareKey = event.flags
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                .isEmpty

            if trigger == .f5, code == Self.f5KeyCode, bareKey {
                DispatchQueue.main.async { [weak self] in self?.onTrigger() }
                // Swallowed so macOS dictation does not also fire on the same press.
                return true
            }

            // A real keystroke means the modifier press was part of a shortcut
            // (⌘C, ⌥→ …), not a bare tap. Invalidate.
            if debugKeys { Log.write("    [keys] keyDown code=\(code) → invalidating tap") }
            sawKeyDownSinceTap = true
            lastTapAt = 0
            sequence.reset()
            return false
        }

        guard type == .flagsChanged, let spec = trigger.modifier else { return false }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard spec.keyCodes.contains(code) else {
            // A different modifier joined in — this is a chord, not a tap.
            if Self.modifierKeyCodes.contains(code), !event.flags.isEmpty {
                lastTapAt = 0
                pressedAt = 0
                sequence.reset()
            }
            return false
        }

        let now = CACurrentMediaTime()
        let isDown = event.flags.contains(spec.flag)

        if debugKeys {
            Log.write("    [keys] trigger-mod \(isDown ? "DOWN" : "UP") code=\(code) sawKeyDown=\(sawKeyDownSinceTap) held=\(String(format: "%.2f", now - pressedAt))")
        }

        if isDown {
            if singleTap {
                pressedAt = now
                activityAtPress = Self.activityCounter()
                sawKeyDownSinceTap = false
            } else if now - lastTapAt < window && !sawKeyDownSinceTap {
                lastTapAt = 0
                sawKeyDownSinceTap = false
                DispatchQueue.main.async { [weak self] in self?.onTrigger() }
            } else {
                lastTapAt = now
                sawKeyDownSinceTap = false
            }
            return false
        }

        // Release. A single tap only counts if NOTHING was struck while the key was
        // held, and it was held briefly — a chord or a long hold is not a tap.
        let activityNow = Self.activityCounter()
        let didSomethingElse = activityNow != activityAtPress

        if debugKeys {
            Log.write("    [keys] release: usedAsChord=\(didSomethingElse) "
                + "activity \(activityAtPress)→\(activityNow) held=\(String(format: "%.2f", now - pressedAt))")
        }

        if singleTap, pressedAt > 0, !sawKeyDownSinceTap, !didSomethingElse, now - pressedAt < tapMaxHold {
            let kind = sequence.tap(pressedAt: pressedAt, releasedAt: now,
                                    activityAtPress: activityAtPress, activityAtRelease: activityNow)
            pressedAt = 0
            if doubleTapEnabled, kind == .double {
                if debugKeys { Log.write("    [keys] double tap") }
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.onTrigger() }
            }
        } else if singleTap {
            sequence.reset()
        }
        return false
    }
}
