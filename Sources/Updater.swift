import Foundation

/// Checks GitHub for a newer release. This is a notice, never an installer:
/// Quill is self-signed and not notarised, so silently replacing its own
/// running bundle is the same behaviour malware uses to persist, and that is
/// not a corner worth cutting on a security-sensitive feature. This tells the
/// user a new version exists and points them at the same install command they
/// already trust — it never downloads or executes anything itself.
enum Updater {

    struct CheckError: Error {
        let message: String
        var isRateLimit: Bool = false
        var resetAt: Date? = nil

        /// What to actually show someone, distinguishing "GitHub is throttling
        /// this network" from an ordinary failure — a bare "HTTP 403" reads as
        /// the app being broken, which is exactly the false alarm reported.
        var displayMessage: String {
            guard isRateLimit else { return message }
            if let resetAt {
                let minutes = max(1, Int(resetAt.timeIntervalSinceNow / 60))
                return "GitHub rate limit reached on this network — try again in \(minutes)m"
            }
            return "GitHub rate limit reached on this network — try again shortly"
        }
    }

    struct Update {
        let version: String
        let url: URL
    }

    /// The ordinary web redirect, not the REST API. `/releases/latest` 302s to
    /// `/releases/tag/vX.Y.Z` and carries no x-ratelimit headers at all — verified
    /// against the live endpoint. The REST API
    /// (api.github.com/repos/.../releases/latest) is capped at 60 unauthenticated
    /// requests PER HOUR PER IP, shared with anything else on that network — a
    /// user behind a home or office NAT can exhaust it without Quill being the
    /// only thing asking. A user hit exactly this and correctly diagnosed it.
    private static let redirectURL = URL(string: "https://github.com/xfreeze2/quill/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/xfreeze2/quill/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 3600

    /// `force: true` bypasses the once-a-day limit — used by "Check for updates…".
    static func checkForUpdate(force: Bool, completion: @escaping (Result<Update?, CheckError>) -> Void) {
        let last = UserDefaults.standard.double(forKey: Defaults.lastUpdateCheck)
        if !force, Date().timeIntervalSince1970 - last < checkInterval {
            completion(.success(cachedUpdate()))
            return
        }

        checkViaRedirect { result in
            switch result {
            case .success(let update):
                DispatchQueue.main.async { completion(.success(update)) }
            case .failure:
                // The redirect path essentially cannot rate-limit on its own, so a
                // failure here is more likely a real network problem — in which
                // case the API call will fail too, but trying costs nothing and
                // occasionally succeeds (e.g. a transient GitHub Pages hiccup).
                checkViaAPI(completion: completion)
            }
        }
    }

    private static func checkViaRedirect(completion: @escaping (Result<Update?, CheckError>) -> Void) {
        var request = URLRequest(url: redirectURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { _, response, error in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Defaults.lastUpdateCheck)

            if let error {
                Log.write("update check (redirect) failed — \(error.localizedDescription)")
                completion(.failure(classify(error)))
                return
            }
            // The final URL after following the redirect — .../releases/tag/v0.8.0.
            guard let finalURL = response?.url, finalURL.lastPathComponent.hasPrefix("v") else {
                Log.write("update check (redirect) — unexpected response")
                completion(.failure(CheckError(message: "unexpected response", isRateLimit: false)))
                return
            }

            let latest = String(finalURL.lastPathComponent.dropFirst())
            record(latest: latest, url: URL(string: "https://github.com/xfreeze2/quill/releases/tag/v\(latest)")!,
                   completion: completion)
        }.resume()
    }

    /// Fallback only. Same rate limit Pedro hit, so it exists purely for the case
    /// where the redirect path itself is unreachable.
    private static func checkViaAPI(completion: @escaping (Result<Update?, CheckError>) -> Void) {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                Log.write("update check (API) failed — \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(classify(error))) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
                let resetHeader = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init)
                let isRateLimit = http.statusCode == 403 && remaining == "0"
                Log.write("update check (API) — HTTP \(http.statusCode) rateLimit=\(isRateLimit)")
                let resetDate = resetHeader.map { Date(timeIntervalSince1970: $0) }
                DispatchQueue.main.async {
                    completion(.failure(CheckError(message: "HTTP \(http.statusCode)",
                                                   isRateLimit: isRateLimit, resetAt: resetDate)))
                }
                return
            }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = root["tag_name"] as? String
            else {
                DispatchQueue.main.async {
                    completion(.failure(CheckError(message: "unreadable response", isRateLimit: false)))
                }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            record(latest: latest,
                  url: URL(string: "https://github.com/xfreeze2/quill/releases/tag/\(tag)")!,
                  completion: completion)
        }.resume()
    }

    private static func record(latest: String, url: URL,
                               completion: @escaping (Result<Update?, CheckError>) -> Void) {
        let newer = isNewer(latest, than: Build.version)
        Log.write("update check — latest \(latest), running \(Build.version), newer=\(newer)")

        if newer {
            UserDefaults.standard.set(latest, forKey: Defaults.availableUpdateVersion)
            UserDefaults.standard.set(url.absoluteString, forKey: Defaults.availableUpdateURL)
            DispatchQueue.main.async { completion(.success(Update(version: latest, url: url))) }
        } else {
            UserDefaults.standard.removeObject(forKey: Defaults.availableUpdateVersion)
            UserDefaults.standard.removeObject(forKey: Defaults.availableUpdateURL)
            DispatchQueue.main.async { completion(.success(nil)) }
        }
    }

    private static func classify(_ error: Error) -> CheckError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet {
            return CheckError(message: "no internet connection", isRateLimit: false)
        }
        return CheckError(message: ns.localizedDescription, isRateLimit: false)
    }

    /// What the last check found, without hitting the network again.
    static func cachedUpdate() -> Update? {
        guard let version = UserDefaults.standard.string(forKey: Defaults.availableUpdateVersion),
              let urlString = UserDefaults.standard.string(forKey: Defaults.availableUpdateURL),
              let url = URL(string: urlString),
              isNewer(version, than: Build.version)
        else { return nil }
        return Update(version: version, url: url)
    }

    /// Plain dot-separated integer comparison — "0.10.0" > "0.9.0", missing
    /// components treated as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
