import Foundation

/// Reads the Grok Build (grok CLI) OIDC credential.
///
/// This is the whole trick: `grok` writes a subscription-backed OIDC token to
/// ~/.grok/auth.json and refreshes it on its own schedule. The same token is what
/// its Ctrl+Space /voice mode presents to the xAI streaming STT endpoint. We read
/// it fresh on every recording — never cache it, never copy it anywhere.
enum Auth {

    enum Source {
        case grokBuild      // the subscription login the grok CLI stores
        case apiKey         // the user's own xAI key, from the Keychain

        var label: String {
            switch self {
            case .grokBuild: return "Grok subscription"
            case .apiKey:    return "xAI API key"
            }
        }
    }

    struct Creds {
        let token: String
        let expiresAt: Date?
        let email: String?
        var source: Source = .grokBuild

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }
    }

    static let path = NSHomeDirectory() + "/.grok/auth.json"

    /// What Quill should authenticate with right now.
    ///
    /// A key the user entered themselves wins over the subscription login: they
    /// went out of their way to provide it, and it is the only option for anyone
    /// without a Grok subscription. Falls back to the CLI session otherwise, so
    /// existing users notice no change.
    static func current() -> Creds? {
        if let key = Keychain.load() {
            return Creds(token: key, expiresAt: nil, email: nil, source: .apiKey)
        }
        return load()
    }

    /// True when there is any usable credential at all.
    static var isConfigured: Bool { current() != nil }

    static func load() -> Creds? {
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
                     email: entry["email"] as? String)
    }

    private static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
