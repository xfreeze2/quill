import Foundation

/// A phrase you say and the text it stands for: "my calendar link" becomes the
/// link, "sign off" becomes your whole signature.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

enum Snippets {

    static let key = "snippets"

    static func load(_ defaults: UserDefaults = .standard) -> [Snippet] {
        guard let data = defaults.data(forKey: key),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
        return snippets
    }

    static func save(_ snippets: [Snippet], _ defaults: UserDefaults = .standard) {
        let usable = snippets.filter { !words(in: $0.trigger).isEmpty && !$0.expansion.isEmpty }
        if usable.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(usable) {
            defaults.set(data, forKey: key)
        }
    }

    /// Replaces each spoken trigger with its expansion.
    ///
    /// Punctuation the transcriber put around a phrase does not matter ("My
    /// calendar link." still matches), and a longer trigger wins over a shorter
    /// one that it contains. When the trigger is everything that was said, the
    /// expansion is the whole result — no stray full stop after a link.
    static func expand(_ text: String, using snippets: [Snippet]) -> String {
        let triggers = snippets
            .map { (words: words(in: $0.trigger), expansion: $0.expansion) }
            .filter { !$0.words.isEmpty && !$0.expansion.isEmpty }
            .sorted { $0.words.count > $1.words.count }
        guard !triggers.isEmpty else { return text }

        let spoken = wordRanges(in: text)
        guard !spoken.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, expansion: String)] = []
        var index = 0
        while index < spoken.count {
            var matched = false
            for trigger in triggers where index + trigger.words.count <= spoken.count {
                let slice = spoken[index..<(index + trigger.words.count)]
                guard zip(slice, trigger.words).allSatisfy({ $0.normalised == $1 }) else { continue }
                let range = slice.first!.range.lowerBound..<slice.last!.range.upperBound
                replacements.append((range, trigger.expansion))
                index += trigger.words.count
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        guard !replacements.isEmpty else { return text }

        // Everything that was said is one trigger: the expansion stands alone.
        if replacements.count == 1 {
            let covered = spoken.filter { replacements[0].range.contains($0.range.lowerBound) }.count
            if covered == spoken.count { return replacements[0].expansion }
        }

        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.expansion)
        }
        return result
    }

    // MARK: Words

    private struct Spoken {
        let range: Range<String.Index>
        let normalised: String
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}'’]*")

    private static func wordRanges(in text: String) -> [Spoken] {
        let whole = NSRange(text.startIndex..., in: text)
        return wordPattern.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Spoken(range: range, normalised: normalise(String(text[range])))
        }
    }

    private static func words(in phrase: String) -> [String] {
        wordRanges(in: phrase).map(\.normalised)
    }

    private static func normalise(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }
}
