import Foundation

/// Grok chat completions, shaped for `SummaryRunner`.
enum MeetingSummarizer {

    static let model = Polisher.model
    private static let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Summarises on a background thread; `done` is called on main.
    static func summarize(_ meeting: Meeting, done: @escaping (Result<ParsedSummary, SummaryFailure>) -> Void) {
        guard let creds = Auth.current() else {
            return DispatchQueue.main.async {
                done(.failure(.network("No Grok sign-in found — run `grok` once, or add an xAI API key in Settings")))
            }
        }
        let runner = SummaryRunner { system, user, reply in
            complete(token: creds.token, system: system, user: user, done: reply)
        }
        runner.run(meeting) { result in
            DispatchQueue.main.async { done(result) }
        }
    }

    /// A busy service (429, 502, 503) is asked again, twice, after the wait it names or a few seconds.
    /// Any single question to Grok, answered on a background thread — the live
    /// notes and the questions about a meeting use it.
    static func chat(system: String, user: String, maxTokens: Int = 1_200,
                     done: @escaping (Result<String, SummaryFailure>) -> Void) {
        guard let creds = Auth.current() else {
            return done(.failure(.network("No Grok sign-in found — run `grok` once, or add an xAI API key in Settings")))
        }
        complete(token: creds.token, system: system, user: user, maxTokens: maxTokens, done: done)
    }

    private static func complete(token: String, system: String, user: String, attempt: Int = 1, maxTokens: Int = 3_000,
                                 done: @escaping (Result<String, SummaryFailure>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let started = Date()
        session.dataTask(with: request) { data, response, error in
            if let error {
                Log.write("meeting summary: \(error.localizedDescription)")
                return done(.failure(.network(describe(error))))
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.write("meeting summary: HTTP \(http.statusCode)")
                if [429, 502, 503].contains(http.statusCode), attempt < 3 {
                    let named = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                    let wait = min(20, max(named, Double(attempt) * 4))
                    return DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                        complete(token: token, system: system, user: user, attempt: attempt + 1, maxTokens: maxTokens, done: done)
                    }
                }
                if http.statusCode == 401 || http.statusCode == 403 { return done(.failure(.unauthorized)) }
                let busy = http.statusCode == 429
                return done(.failure(.network(busy
                    ? "The summary service is busy right now — try again in a minute"
                    : "The summary service answered with an error (\(http.statusCode))")))
            }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String
            else { return done(.failure(.unreadable)) }
            Log.write("meeting summary: answered in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            done(.success(text))
        }.resume()
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "No network connection"
        case NSURLErrorTimedOut:               return "The summary took too long — try again"
        default:                               return "Couldn't reach the summary service — check your connection"
        }
    }
}
