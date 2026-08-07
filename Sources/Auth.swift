import Foundation

/// Resolves a Bearer token for xAI's streaming STT endpoint.
///
/// Two credential sources, tried in order:
///
/// 1. **Grok Build subscription** — the OIDC token the `grok` CLI keeps in
///    `~/.grok/auth.json`. Free with the subscription, nothing metered. Read
///    fresh on every recording; never cached.
/// 2. **xAI API key (BYOK)** — a console key (`xai-…`). Checked in:
///      - `XAI_API_KEY` / `GROK_CODE_XAI_API_KEY` environment variables
///      - `~/.config/xai/api_key` (one line, no quotes) — so a GUI launch
///        (Dock / Login Items) still finds the key when the shell env is absent
///
/// A valid, unexpired subscription token always wins. An expired one is skipped
/// so a configured API key can take over without a re-login.
enum Auth {

    enum Source: Equatable {
        case subscription
        case apiKey
    }

    struct Creds {
        let token: String
        let expiresAt: Date?
        let email: String?
        let source: Source

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }

        /// Short label for menus and the setup window.
        var displayName: String {
            switch source {
            case .subscription:
                return email ?? "signed in"
            case .apiKey:
                return "API key · \(Self.mask(token))"
            }
        }

        private static func mask(_ key: String) -> String {
            // xai-abc…xyz — keep a recognisable tail without exposing the secret.
            guard key.count > 12 else { return "••••" }
            return "…" + String(key.suffix(4))
        }
    }

    static let path = NSHomeDirectory() + "/.grok/auth.json"
    static let apiKeyFilePath = NSHomeDirectory() + "/.config/xai/api_key"

    static func load() -> Creds? {
        if let sub = loadSubscription(), !sub.isExpired { return sub }
        if let key = loadAPIKey() { return key }
        // Last resort: surface an expired subscription so the UI can still say
        // "signed in (expired)" rather than "not signed in", and STT can return
        // a clear 401 rather than a missing-creds notice.
        if let sub = loadSubscription() { return sub }
        return nil
    }

    // MARK: - Subscription (OIDC)

    private static func loadSubscription() -> Creds? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // auth.json is keyed by issuer::principal. Take the most recently created
        // entry that actually carries a key.
        var newest: [String: Any]?
        var newestTime = Date.distantPast
        for (_, value) in root {
            guard let entry = value as? [String: Any], entry["key"] is String else { continue }
            let created = (entry["create_time"] as? String).flatMap(parseDate) ?? Date.distantPast
            if created >= newestTime {
                newestTime = created
                newest = entry
            }
        }

        guard let entry = newest, let key = entry["key"] as? String, !key.isEmpty else { return nil }
        return Creds(token: key,
                     expiresAt: (entry["expires_at"] as? String).flatMap(parseDate),
                     email: entry["email"] as? String,
                     source: .subscription)
    }

    // MARK: - API key (BYOK)

    private static func loadAPIKey() -> Creds? {
        if let raw = ProcessInfo.processInfo.environment["XAI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GROK_CODE_XAI_API_KEY"],
           let key = normalizeAPIKey(raw) {
            return Creds(token: key, expiresAt: nil, email: nil, source: .apiKey)
        }

        if let data = FileManager.default.contents(atPath: apiKeyFilePath),
           let raw = String(data: data, encoding: .utf8),
           let key = normalizeAPIKey(raw) {
            return Creds(token: key, expiresAt: nil, email: nil, source: .apiKey)
        }

        return nil
    }

    /// Strip whitespace/newlines and reject empty or placeholder values.
    private static func normalizeAPIKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        // Common dotenv mistakes: quotes around the value.
        if (key.hasPrefix("\"") && key.hasSuffix("\""))
            || (key.hasPrefix("'") && key.hasSuffix("'")),
           key.count >= 2 {
            let inner = String(key.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }
        return key
    }

    private static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
