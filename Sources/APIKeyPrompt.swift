import Cocoa

/// Entering and checking the user's own xAI API key.
///
/// The field is a secure one, so the key is never rendered on screen or picked up
/// by a screenshot, and it is never written to the log — only whether a write or
/// a check succeeded. The value goes straight to the Keychain and is read back
/// from there when needed, so it never sits in preferences or in memory longer
/// than a request needs it.
enum APIKeyPrompt {

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = Keychain.hasKey ? "Change your xAI API key" : "Use your own xAI API key"
        alert.informativeText = """
            With a key from console.x.ai, Quill works without a Grok subscription. \
            Usage is billed to your own xAI account.

            The key is stored in your Mac's Keychain, is never written to logs, and is only \
            ever sent to api.x.ai.
            """
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = Keychain.hasKey ? (Keychain.redacted ?? "xai-…") : "xai-…"
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if Keychain.hasKey { alert.addButton(withTitle: "Remove") }

        alert.window.initialFirstResponder = field
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            save(field.stringValue)
        case .alertThirdButtonReturn:
            Keychain.remove()
            Log.write("api key removed")
            report("Key removed. Quill will use your Grok Build session if you have one.")
        default:
            break
        }
    }

    private static func save(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        guard key.count > 16, !key.contains(" ") else {
            report("That doesn't look like an API key. Copy it from console.x.ai — it starts with “xai-”.")
            return
        }

        // Check it works before storing it, so a typo surfaces now rather than
        // in the middle of a dictation.
        verify(key) { working, detail in
            guard working else {
                let reason = detail.map { " — \($0)" } ?? ""
                report("That key was rejected by xAI\(reason). Nothing was saved.")
                return
            }
            if Keychain.save(key) {
                report("Key saved to your Keychain. Quill will use it from now on.")
            } else {
                report("Couldn't save to the Keychain. Nothing was stored.")
            }
        }
    }

    /// A cheap authenticated call — enough to prove the key is accepted.
    private static func verify(_ key: String, completion: @escaping (Bool, String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    Log.write("api key check failed: transport")
                    completion(false, error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                Log.write("api key check → HTTP \(code)")
                switch code {
                case 200:      completion(true, nil)
                case 401, 403: completion(false, "it was not accepted")
                case 429:      completion(false, "rate limited, try again shortly")
                default:       completion(false, "HTTP \(code)")
                }
            }
        }.resume()
    }

    private static func report(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quill"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
