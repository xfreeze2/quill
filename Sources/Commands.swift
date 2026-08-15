import Cocoa
import ApplicationServices

/// Spoken commands that act while you keep talking.
///
/// "open Grok" is only a command when it is the first thing said. Mid-sentence
/// it is ordinary speech — launching Grok in the middle of a thought dumps you
/// into a new session and wrecks the dictation. The phrase is removed from the
/// inserted text only when it counted as a command, so "open Grok, now write me
/// a haiku" opens Grok and types only the haiku.
enum VoiceCommands {

    /// "open grok" / "open grok build", allowing for how speech-to-text actually
    /// hears the word — grock, grog, croc and friends all turn up in practice.
    ///
    /// Anchored to the start on purpose. Same reason the stop phrase is
    /// end-only: the words are ordinary English once you are already talking.
    private static let openGrok: NSRegularExpression = {
        let word = "gro(?:k|ck|g|c)|crock|croc|grokk"
        let pattern = "^[\\s,.!?]*(?:please\\s+)?(?:open|launch|start)\\s+(?:up\\s+)?(?:the\\s+)?"
                    + "(?:\(word))(?:\\s+build)?\\b[\\s,.!?]*"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func containsOpenGrok(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return openGrok.firstMatch(in: text, range: range) != nil
    }

    /// "that's it" or "that's all" — but only as the very last thing said.
    ///
    /// Anchored to the end on purpose. The phrase is ordinary English in the middle
    /// of a sentence ("that's it exactly"), and stopping there would cut someone off
    /// mid-thought. Matching only a trailing occurrence, and only after a short
    /// silence, is what makes it safe to have on by default.
    private static let stopPhrase: NSRegularExpression = {
        let pattern = "(?:^|\\s)(?:and\\s+)?that(?:'|’)?s\\s+(?:it|all)\\b[\\s,.!?]*$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func endsWithStopPhrase(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return stopPhrase.firstMatch(in: text, range: range) != nil
    }

    /// Removes a trailing "that's it" so the words that ended the dictation are not
    /// part of what gets pasted.
    static func stripStopPhrase(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = stopPhrase.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything a spoken command should never leave behind.
    static func stripAll(_ text: String) -> String {
        stripStopPhrase(strip(text))
    }

    /// The transcript with any command phrase taken out.
    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = openGrok.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: " ")
        return stripped
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: -

/// Opens Grok Build the way you would by hand.
///
/// `ghostty -e grok` is explicitly unsupported on macOS — Ghostty's own help says
/// so — and it produces a session with the wrong appearance and broken copy and
/// paste. The supported path, `open -na Ghostty.app`, gives a completely ordinary
/// window running a normal login shell; then `grok` is typed into it, which is
/// exactly the sequence a person performs.
///
/// The risk in typing is hitting the wrong window, so the command is only sent
/// once a NEW Ghostty window exists and Ghostty is frontmost. Window counting goes
/// through Accessibility, which Quill already has — `CGWindowListCopyWindowInfo`
/// would need Screen Recording and returns nothing without it.
enum GrokLauncher {

    private static let ghosttyBundleID = "com.mitchellh.ghostty"

    enum Outcome {
        case opened(String)      // which terminal
        case failed(String)
    }

    static var ghosttyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleID) != nil
    }

    static func open(completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            if ghosttyInstalled, let result = viaGhostty() {
                outcome = result
            } else {
                outcome = viaTerminal()
            }
            Log.write("open Grok → \(outcome)")
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // MARK: Ghostty

    /// Returns nil if Ghostty could not be driven, so the caller can fall back.
    private static func viaGhostty() -> Outcome? {
        let before = ghosttyWindowCount()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-na", "Ghostty.app"]
        do { try task.run() } catch {
            Log.write("  ghostty: open failed — \(error.localizedDescription)")
            return nil
        }

        // Wait for a genuinely new window that is also frontmost.
        let deadline = Date().addingTimeInterval(8)
        var ready = false
        while Date() < deadline {
            if ghosttyWindowCount() > before, frontmostBundleID == ghosttyBundleID {
                ready = true
                break
            }
            usleep(80_000)
        }
        guard ready else {
            Log.write("  ghostty: no new frontmost window within 8s")
            return nil
        }

        // Let the shell finish starting so the prompt is accepting input.
        usleep(900_000)

        // Re-check: never type into whatever happened to steal focus.
        guard frontmostBundleID == ghosttyBundleID else {
            Log.write("  ghostty: focus moved away before typing — aborted")
            return nil
        }

        typeText("grok")
        usleep(80_000)
        pressReturn()
        return .opened("Ghostty")
    }

    private static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private static func ghosttyWindowCount() -> Int {
        var total = 0
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                total += windows.count
            }
        }
        return total
    }

    // MARK: Terminal fallback

    private static func viaTerminal() -> Outcome {
        // `do script` runs the command in a normal interactive shell in a new
        // window — the same thing typing it would do.
        let script = """
        tell application "Terminal"
            activate
            do script "grok"
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return .failed("Couldn't open Terminal: \(error.localizedDescription)")
        }

        guard task.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The usual cause is the one-time "wants to control Terminal" prompt
            // being dismissed rather than allowed.
            return .failed(message.isEmpty ? "Terminal refused to open" : message)
        }
        return .opened("Terminal")
    }

    // MARK: Synthetic input

    /// Layout independent — the unicode payload is set directly rather than
    /// guessing at key codes, so it works on non-US keyboards too.
    private static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for unit in text.utf16 {
            var character = unit
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            usleep(12_000)
        }
    }

    private static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?
            .post(tap: .cgAnnotatedSessionEventTap)
        usleep(20_000)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?
            .post(tap: .cgAnnotatedSessionEventTap)
    }
}
