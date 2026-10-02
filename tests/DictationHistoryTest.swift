// The dictation history: what is kept, what is found, what the numbers say.
import Foundation

@main
enum DictationHistoryTest {
    static func main() {
        let check = Check()
        let dir = scratchDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ d: Int, hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
        }
        let now = day(10, hour: 18)

        // Adding.
        let history = DictationHistory(url: url, limit: 5)
        check.isTrue("starts empty", history.entries.isEmpty)
        check.isTrue("nothing is not an entry", history.add(text: "   \n ") == nil)
        let first = history.add(text: "  Remind me to call Maria.  ", app: "Notes", seconds: 6, date: day(10))
        check.isTrue("an entry is stored", first != nil)
        check.equal("its text is tidied", history.entries.first?.text, "Remind me to call Maria.")
        check.equal("it knows its words", history.entries.first?.wordCount, 5)

        // Newest first, and capped.
        for index in 1...6 { history.add(text: "note number \(index)", date: day(10, hour: 12 + index)) }
        check.equal("capped at the limit", history.entries.count, 5)
        check.equal("newest first", history.entries.first?.text, "note number 6")
        check.isTrue("the oldest fell off", !history.entries.contains { $0.text.hasPrefix("Remind") })

        // It survives a restart, and only the owner can read it.
        let reopened = DictationHistory(url: url, limit: 5)
        check.equal("reloaded", reopened.entries.map(\.text), history.entries.map(\.text))
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        check.equal("file is private to the user", mode, 0o600)

        // Setting the app after the fact.
        let id = reopened.add(text: "send the invoice", date: day(10, hour: 20))!
        reopened.setApp(id, "Mail")
        check.equal("app recorded later", DictationHistory(url: url, limit: 5).entries.first?.app, "Mail")

        // Search: every word must match, in the text or the app.
        let searchable = DictationHistory(url: dir.appendingPathComponent("search.json"))
        searchable.add(text: "Book the flight to Lisbon", app: "Safari", date: day(9))
        searchable.add(text: "Lisbon hotel near the river", app: "Notes", date: day(8))
        searchable.add(text: "Buy milk", app: "Reminders", date: day(7))
        check.equal("one word", searchable.search("lisbon").count, 2)
        check.equal("every word", searchable.search("lisbon river").count, 1)
        check.equal("the app counts", searchable.search("reminders").count, 1)
        check.equal("no match", searchable.search("tokyo").count, 0)
        check.equal("empty query is everything", searchable.search("  ").count, 3)

        // Removing and clearing.
        let removable = searchable.entries[0].id
        searchable.remove(removable)
        check.equal("removed", searchable.entries.count, 2)
        searchable.clear()
        check.isTrue("cleared", searchable.entries.isEmpty)
        check.isTrue("clearing deletes the file", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("search.json").path))

        // Stats.
        let stats = DictationHistory(url: dir.appendingPathComponent("stats.json"), limit: 100)
        stats.add(text: String(repeating: "word ", count: 120), seconds: 60, date: day(10, hour: 9))     // today, 120 words in 1 min
        stats.add(text: String(repeating: "word ", count: 30), seconds: 30, date: day(9))                // yesterday
        stats.add(text: String(repeating: "word ", count: 10), date: day(8))                             // two days ago, no timing
        stats.add(text: String(repeating: "word ", count: 50), date: day(5))                             // a gap before it
        let s = stats.stats(now: now, calendar: calendar)
        check.equal("dictation count", s.dictations, 4)
        check.equal("total words", s.words, 210)
        check.equal("words today", s.wordsToday, 120)
        check.equal("words this week", s.wordsThisWeek, 210 - 0)
        check.equal("a streak stops at the gap", s.streakDays, 3)
        check.equal("speed from timed dictations only", s.wordsPerMinute, 100)

        let later = stats.stats(now: day(11, hour: 8), calendar: calendar)
        check.equal("a streak survives until you miss a whole day", later.streakDays, 3)
        let muchLater = stats.stats(now: day(14, hour: 8), calendar: calendar)
        check.equal("then it ends", muchLater.streakDays, 0)
        check.equal("nothing too short to time", DictationHistory(url: dir.appendingPathComponent("none.json")).stats().wordsPerMinute, nil)

        // A damaged file is set aside, not overwritten.
        let broken = dir.appendingPathComponent("broken.json")
        try? Data("{ not json".utf8).write(to: broken)
        let recovered = DictationHistory(url: broken)
        check.isTrue("a damaged file reads as empty", recovered.entries.isEmpty)
        check.isTrue("but is kept for a look", FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken.corrupt.json").path))
        recovered.add(text: "fresh start")
        check.equal("and writing carries on", DictationHistory(url: broken).entries.count, 1)

        check.finish()
    }
}
