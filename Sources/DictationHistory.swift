import Foundation

/// One finished dictation, as it was put into the app you were using.
struct DictationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
    /// The app it went into, when known.
    var app: String?
    /// How long you spoke for.
    var seconds: Double?

    var wordCount: Int { Self.wordCount(of: text) }

    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

struct DictationStats: Equatable {
    var dictations = 0
    var words = 0
    var wordsToday = 0
    var wordsThisWeek = 0
    /// Words per day for the last seven days, oldest first; the last is today.
    var lastSevenDays = [Int](repeating: 0, count: 7)
    /// Consecutive days, ending today or yesterday, with at least one dictation.
    var streakDays = 0
    /// Words per minute across the dictations whose length is known.
    var wordsPerMinute: Int?
}

/// Everything you have dictated, kept on this Mac and nowhere else.
///
/// A plain JSON file in Application Support, readable by you alone. The cap keeps
/// it from growing forever; the oldest entries fall off first. Newest first.
final class DictationHistory {

    private(set) var entries: [DictationEntry] = []

    private let url: URL
    private let limit: Int

    init(url: URL, limit: Int = 2000) {
        self.url = url
        self.limit = max(1, limit)
        load()
    }

    static func defaultURL() -> URL {
        AppSupport.directory.appendingPathComponent("history.json")
    }

    // MARK: Changing

    @discardableResult
    func add(text: String, app: String? = nil, seconds: Double? = nil, date: Date = Date()) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = DictationEntry(text: trimmed, date: date, app: app, seconds: seconds)
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
        return entry.id
    }

    func setApp(_ id: UUID, _ app: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].app != app else { return }
        entries[index].app = app
        save()
    }

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Reading

    func recent(_ count: Int) -> [DictationEntry] {
        Array(entries.prefix(max(0, count)))
    }

    /// Every word of the query must appear, in the text or the app's name.
    func search(_ query: String) -> [DictationEntry] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = (entry.text + " " + (entry.app ?? "")).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    func stats(now: Date = Date(), calendar: Calendar = .current) -> DictationStats {
        var stats = DictationStats()
        stats.dictations = entries.count
        let startOfToday = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var timedWords = 0
        var timedSeconds = 0.0
        var days = Set<Date>()
        for entry in entries {
            let words = entry.wordCount
            stats.words += words
            let day = calendar.startOfDay(for: entry.date)
            days.insert(day)
            if day >= startOfToday { stats.wordsToday += words }
            if day >= weekAgo {
                stats.wordsThisWeek += words
                if let back = calendar.dateComponents([.day], from: day, to: startOfToday).day, (0...6).contains(back) {
                    stats.lastSevenDays[6 - back] += words
                }
            }
            if let seconds = entry.seconds, seconds >= 1 {
                timedWords += words
                timedSeconds += seconds
            }
        }
        if timedSeconds >= 5 {
            stats.wordsPerMinute = Int((Double(timedWords) / (timedSeconds / 60)).rounded())
        }

        // Today may still be empty; the streak is alive if yesterday is not.
        var cursor = days.contains(startOfToday) ? startOfToday
            : (calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
        while days.contains(cursor) {
            stats.streakDays += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return stats
    }

    // MARK: Disk

    private struct File: Codable {
        var version = 1
        var entries: [DictationEntry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(File.self, from: data) {
            entries = file.entries
        } else {
            // Unreadable. Keep it where someone can look at it rather than
            // overwrite it with an empty list on the next dictation.
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(entries: entries)) else { return }
        AppSupport.write(data, to: url)
    }
}

/// Where Quill keeps what it remembers.
enum AppSupport {

    /// QUILL_DATA_DIR points the app at a scratch folder, so a test never touches
    /// what is really kept.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["QUILL_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            ensure(dir)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Quill", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// Private to the user: other accounts on the Mac have no business reading
    /// what you said.
    static func ensure(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    static func write(_ data: Data, to url: URL) {
        ensure(url.deletingLastPathComponent())
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
