import Foundation

/// Pure text tidying applied the moment before a dictation is written into a
/// field. Deliberately free of AppKit and Accessibility: this is the logic that
/// decides how the transcript fits against whatever is already there, and keeping
/// it framework-free is what lets it be unit-tested without a Mac in the loop.
enum TextTidy {

    /// Are we landing in the MIDDLE of an existing sentence, rather than at the
    /// start of a field or right after a finished sentence?
    ///
    /// The speech-to-text service capitalises the first word of every utterance —
    /// to it, each dictation is a fresh sentence. When those words are appended
    /// after "…so I was thinking " that leading capital is wrong, and this is what
    /// tells the caller when to correct it.
    ///
    /// A "finished sentence" is one whose last meaningful character is a
    /// terminator (`. ! ? …`) or a line break. Trailing whitespace and closing
    /// wrappers (`" ' ) ] }` and their smart-quote forms) are skipped first, so
    /// `He said "hello."` and `(done.)` still read as finished.
    static func isContinuation(before existing: String?, at offset: Int?) -> Bool {
        guard let existing, !existing.isEmpty, let offset, offset > 0 else { return false }

        let units = existing.utf16
        let clamped = min(offset, units.count)
        let unit = units.index(units.startIndex, offsetBy: clamped)
        var index = String.Index(unit, within: existing) ?? existing.endIndex

        while index > existing.startIndex {
            let previous = existing.index(before: index)
            let character = existing[previous]
            // A line break starts a fresh line → keep the capital.
            if character.isNewline { return false }
            if character.isWhitespace || closingWrappers.contains(character) {
                index = previous
                continue
            }
            // A terminator means the previous sentence ended → keep the capital.
            if terminators.contains(character) { return false }
            return true
        }
        // Nothing but whitespace/wrappers before us → treat as a sentence start.
        return false
    }

    /// Lowercases only the first letter of `text`, for use when continuing an
    /// existing sentence. Leaves words that are meant to stay capitalised alone:
    /// the pronoun "I" and its contractions, and all-caps acronyms (NASA, API).
    ///
    /// Proper nouns are a known limitation — "…met John" dictated as a
    /// continuation becomes "…met john" — because they are indistinguishable from
    /// an ordinary auto-capitalised sentence opener without a dictionary. The
    /// common case (a function word the model capitalised) is corrected; the rare
    /// case is a lowercase proper noun the user can fix.
    static func decapitalizeLead(_ text: String) -> String {
        guard let first = text.first, first.isLetter, first.isUppercase else { return text }
        if shouldPreserveCapital(leadingToken(text)) { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Fixes the leading capital only when landing mid-sentence.
    static func applyContinuationCase(_ text: String, existing: String?, at offset: Int?) -> String {
        guard isContinuation(before: existing, at: offset) else { return text }
        return decapitalizeLead(text)
    }

    // MARK: Internals

    private static let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let closingWrappers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{2019}", "\u{201D}"]

    /// The opening run of letters and internal apostrophes: "I'll," → "I'll".
    private static func leadingToken(_ text: String) -> String {
        var token = ""
        for character in text {
            if character.isLetter || character == "'" || character == "\u{2019}" {
                token.append(character)
            } else {
                break
            }
        }
        return token
    }

    private static func shouldPreserveCapital(_ token: String) -> Bool {
        if token == "I" { return true }
        if token.hasPrefix("I'") || token.hasPrefix("I\u{2019}") { return true }
        let letters = token.filter { $0.isLetter }
        if letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) { return true }
        return false
    }
}
