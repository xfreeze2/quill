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
    }

    struct Update {
        let version: String
        let url: URL
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/xfreeze2/quill/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 3600

    /// `force: true` bypasses the once-a-day limit — used by "Check for updates…".
    static func checkForUpdate(force: Bool, completion: @escaping (Result<Update?, CheckError>) -> Void) {
        let last = UserDefaults.standard.double(forKey: Defaults.lastUpdateCheck)
        if !force, Date().timeIntervalSince1970 - last < checkInterval {
            completion(.success(cachedUpdate()))
            return
        }

        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Defaults.lastUpdateCheck)

            if let error {
                Log.write("update check failed — \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(CheckError(message: error.localizedDescription))) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.write("update check — HTTP \(http.statusCode)")
                DispatchQueue.main.async { completion(.failure(CheckError(message: "HTTP \(http.statusCode)"))) }
                return
            }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = root["tag_name"] as? String,
                  let htmlURL = (root["html_url"] as? String).flatMap(URL.init(string:))
            else {
                DispatchQueue.main.async { completion(.failure(CheckError(message: "unreadable response"))) }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let newer = isNewer(latest, than: Build.version)
            Log.write("update check — latest \(latest), running \(Build.version), newer=\(newer)")

            if newer {
                UserDefaults.standard.set(latest, forKey: Defaults.availableUpdateVersion)
                UserDefaults.standard.set(htmlURL.absoluteString, forKey: Defaults.availableUpdateURL)
                DispatchQueue.main.async { completion(.success(Update(version: latest, url: htmlURL))) }
            } else {
                UserDefaults.standard.removeObject(forKey: Defaults.availableUpdateVersion)
                UserDefaults.standard.removeObject(forKey: Defaults.availableUpdateURL)
                DispatchQueue.main.async { completion(.success(nil)) }
            }
        }.resume()
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
