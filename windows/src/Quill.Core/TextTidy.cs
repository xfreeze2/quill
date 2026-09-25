using System.Text.RegularExpressions;

namespace Quill;

/// <summary>
/// How a dictation fits against the text that is already in the field.
/// Port of the Mac app's TextTidy (Sources/TextTidy.swift).
///
/// Speech-to-text treats every utterance as its own sentence: the first word
/// arrives capitalised and the last one usually carries a full stop. Both are
/// wrong the moment the words land mid-sentence — after "…so I was thinking "
/// a capital "So" reads as a typo, and a full stop dropped in front of ", which"
/// breaks the line. This is the logic that looks at the characters on either
/// side of the insertion point and adjusts the payload to match.
///
/// One deliberate difference from the Mac: macOS ships an on-device tagger
/// that recognises personal, place and organisation names, and the Mac
/// lowercases every opener the tagger does not claim. Windows has no such
/// tagger, so this port inverts the rule — it lowercases the opener only when
/// it is a known English function word ("So", "The", "And", …), which is what
/// the speech service actually capitalises. Everything else keeps its capital,
/// so names ("John", "Paris") are never damaged; the cost is that a rare
/// function word missing from the list stays capitalised, the smaller error.
///
/// Offsets are UTF-16 units, which is what .NET strings index by and what the
/// Mac code uses too.
/// </summary>
public static class TextTidy
{
    /// <summary>
    /// The payload to write: case-corrected, terminator-trimmed and padded so it
    /// neither runs into its neighbours nor leaves a double space.
    /// </summary>
    /// <param name="text">The dictated payload.</param>
    /// <param name="existing">The field's current contents, or null if unreadable.</param>
    /// <param name="offset">Where the text will land, in UTF-16 units; null means the end.</param>
    /// <param name="language">Dictation language code ("en", "de", "auto", …). Only
    /// used to keep German nouns capitalised.</param>
    public static string Fit(string text, string? existing, int? offset, string language = "en")
    {
        var output = text;
        var boundary = offset ?? existing?.Length;

        if (IsContinuation(existing, boundary))
            output = DecapitalizeLead(output, language);
        if (SentenceContinues(existing, boundary))
            output = TrimTrailingTerminator(output);

        if (NeedsSeparator(existing, boundary, output)) output = " " + output;
        if (NeedsTrailingSeparator(existing, boundary, output)) output += " ";
        return output;
    }

    // MARK: Where are we landing?

    /// <summary>
    /// Are we landing in the MIDDLE of a sentence, rather than at the start of a
    /// field, a fresh line, a list item, or right after a finished sentence?
    ///
    /// Only the current line matters. Walking back from the caret: trailing
    /// whitespace and closing wrappers (" ' ) ] } and their smart forms) are
    /// skipped, so `He said "hello."` and `(done.)` still read as finished. A
    /// terminator (. ! ? …) or nothing but a list marker (-, •, 1., a)) means
    /// the next word starts fresh and keeps its capital.
    /// </summary>
    public static bool IsContinuation(string? existing, int? offset)
    {
        if (string.IsNullOrEmpty(existing) || offset is null or <= 0) return false;
        var line = LineBefore(existing, offset.Value);
        var trimmed = line.Trim();
        if (trimmed.Length == 0) return false;                 // fresh line
        if (ListMarker.IsMatch(trimmed)) return false;         // "- ", "• ", "1) ", "a."

        for (var i = line.Length - 1; i >= 0; i--)
        {
            var ch = line[i];
            if (char.IsWhiteSpace(ch) || ClosingWrappers.Contains(ch)) continue;
            return !Terminators.Contains(ch);
        }
        return false;                                          // only wrappers and spaces
    }

    /// <summary>
    /// Does the text after the caret carry on the same sentence? True when the
    /// next thing on the line is a lowercase letter or a joining punctuation
    /// mark — the cases where a full stop from the dictation would be wrong.
    /// </summary>
    public static bool SentenceContinues(string? existing, int? offset)
    {
        if (existing is null || offset is null || offset.Value >= existing.Length) return false;
        var line = LineAfter(existing, offset.Value);
        foreach (var ch in line)
        {
            if (char.IsWhiteSpace(ch)) continue;
            if (char.IsLetter(ch)) return char.IsLower(ch);
            return ch is ',' or ';' or ':';
        }
        return false;
    }

    // MARK: Adjusting the payload

    /// <summary>
    /// Lowercases only the first letter, for use when continuing a sentence.
    ///
    /// Only known English function words are lowered; words that are capitalised
    /// in their own right — the pronoun "I" and its contractions, all-caps
    /// acronyms (NASA, API), day and month names, and anything else, names
    /// included — are left alone. German is left entirely alone: every noun is
    /// capitalised there, and lowercasing one is a worse error than leaving a
    /// function word capitalised.
    /// </summary>
    public static string DecapitalizeLead(string text, string language = "en")
    {
        if (text.Length == 0) return text;
        var first = text[0];
        if (!char.IsLetter(first) || !char.IsUpper(first)) return text;
        if (CapitalisesNouns(language, text)) return text;
        var token = LeadingToken(text);
        if (ShouldPreserveCapital(token)) return text;
        return char.ToLowerInvariant(first) + text[1..];
    }

    /// <summary>Drops one trailing sentence terminator, for text landing mid-sentence.</summary>
    public static string TrimTrailingTerminator(string text)
    {
        if (text.Length == 0) return text;
        var last = text[^1];
        if (!Terminators.Contains(last) || last == '\u2026') return text;
        return text[..^1];
    }

    // MARK: Spacing

    /// <summary>
    /// Should a space go between what is already there and what we are adding?
    ///
    /// Only when the two would otherwise collide: there is text before the
    /// insertion point, it does not already end in whitespace or an opening
    /// bracket, and the new text does not begin with punctuation that belongs
    /// tight against the previous word.
    /// </summary>
    public static bool NeedsSeparator(string? existing, int? offset, string inserting)
    {
        if (string.IsNullOrEmpty(existing) || offset is null or <= 0) return false;
        var at = Math.Min(offset.Value, existing.Length) - 1;
        if (at < 0) return false;
        var boundary = existing[at];

        if (char.IsWhiteSpace(boundary)) return false;
        if (OpeningBefore.Contains(boundary)) return false;

        if (inserting.Length > 0)
        {
            if (ClosingAfter.Contains(inserting[0])) return false;
            // Chinese and Japanese do not put spaces between words.
            if (IsCjkAt(inserting, 0) || IsCjkAt(existing, at)) return false;
        }
        return true;
    }

    /// <summary>
    /// Should a space go between what we are adding and what already follows?
    ///
    /// Only relevant when landing mid-text — appending at the end has nothing
    /// after it. Mirrors the leading rule: skip it if the next character is
    /// already whitespace, or is punctuation that belongs tight against a word.
    /// </summary>
    public static bool NeedsTrailingSeparator(string? existing, int? offset, string inserting)
    {
        if (existing is null || offset is null || offset.Value < 0 || offset.Value >= existing.Length) return false;
        var next = existing[offset.Value];

        if (char.IsWhiteSpace(next)) return false;
        if (ClosingAfter.Contains(next)) return false;

        if (inserting.Length > 0)
        {
            if (char.IsWhiteSpace(inserting[^1])) return false;
            if (IsCjkAt(inserting, inserting.Length - 1) || IsCjkAt(existing, offset.Value)) return false;
        }
        return true;
    }

    // MARK: Internals

    const string Terminators = ".!?\u2026\u3002\uFF01\uFF1F";
    const string ClosingWrappers = "\"')]}\u2019\u201D\u300D\u300F";
    const string OpeningBefore = "([{<\u201C\u2018\"'-\u2013\u2014/@#";
    const string ClosingAfter = ",.;:!?)]}%\u201D\u2019";

    static readonly Regex ListMarker = new(
        @"^(?:[-\u2013\u2014\u2022*+>#]+|\d{1,3}[.)]|[a-zA-Z][.)])$", RegexOptions.Compiled);

    static readonly HashSet<string> DayAndMonthNames = new(StringComparer.Ordinal)
    {
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    };

    /// <summary>
    /// English words the speech service capitalises only because they opened the
    /// utterance: articles, pronouns, auxiliaries, conjunctions, prepositions,
    /// discourse adverbs and their common contractions. Words that double as
    /// first names (Mark, Bill, Grant…) are deliberately absent — for those,
    /// keeping a capital is the smaller error.
    /// </summary>
    static readonly HashSet<string> LowercaseOpeners = new(StringComparer.Ordinal)
    {
        // articles and determiners
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "each",
        "every", "no", "all", "both", "either", "neither", "another", "such", "more",
        "most", "much", "many", "few", "several", "other", "own", "same",
        // pronouns
        "it", "we", "you", "he", "she", "they", "them", "us", "me", "him", "her",
        "my", "your", "his", "its", "our", "their", "mine", "yours", "hers", "ours",
        "theirs", "myself", "yourself", "himself", "herself", "itself", "ourselves",
        "yourselves", "themselves", "one", "someone", "somebody", "anyone", "anybody",
        "everyone", "everybody", "nobody", "something", "anything", "everything", "nothing",
        // auxiliaries and very common verbs
        "is", "are", "was", "were", "am", "be", "been", "being", "do", "does", "did",
        "doing", "done", "have", "has", "had", "having", "can", "could", "will",
        "would", "shall", "should", "might", "must", "ought", "need", "needs", "let",
        "lets", "go", "goes", "going", "went", "gone", "get", "gets", "getting", "got",
        "make", "makes", "making", "made", "take", "takes", "taking", "took", "keep",
        "keeps", "keeping", "kept", "put", "puts", "putting", "say", "says", "saying",
        "said", "see", "sees", "seeing", "saw", "know", "knows", "knowing", "knew",
        "think", "thinks", "thinking", "thought", "want", "wants", "wanted", "wanting",
        "try", "tries", "trying", "tried", "use", "uses", "using", "used", "seems",
        "seem", "seemed", "means", "mean", "meant", "feels", "feel", "felt", "looks",
        "look", "looking", "looked", "sounds", "sound", "comes", "come", "coming", "came",
        // conjunctions and subordinators
        "and", "but", "or", "nor", "so", "yet", "for", "because", "although", "though",
        "while", "whereas", "if", "unless", "until", "till", "since", "when", "whenever",
        "where", "wherever", "whether", "which", "who", "whom", "whose", "what", "why",
        "how", "after", "before", "once", "as", "than",
        // prepositions
        "in", "on", "at", "by", "to", "of", "with", "from", "into", "onto", "over",
        "under", "about", "against", "between", "among", "through", "during", "without",
        "within", "along", "across", "behind", "beyond", "up", "down", "off", "out",
        "around", "near", "inside", "outside", "toward", "towards", "upon", "per",
        "via", "despite", "except", "beside", "besides", "above", "below", "underneath",
        "throughout", "amid", "amidst", "plus",
        // discourse adverbs and fillers
        "then", "also", "maybe", "perhaps", "well", "now", "just", "actually",
        "basically", "anyway", "anyways", "okay", "alright", "right", "sure", "yes",
        "yeah", "yep", "nope", "not", "please", "thanks", "hopefully", "honestly",
        "seriously", "obviously", "clearly", "apparently", "probably", "definitely",
        "certainly", "absolutely", "exactly", "again", "still", "even", "only",
        "really", "very", "quite", "rather", "too", "instead", "otherwise",
        "meanwhile", "however", "therefore", "moreover", "furthermore", "finally",
        "first", "firstly", "second", "secondly", "third", "thirdly", "next", "last",
        "lastly", "especially", "specifically", "particularly", "mostly", "mainly",
        "usually", "normally", "typically", "generally", "currently", "recently",
        "soon", "later", "today", "tomorrow", "tonight", "yesterday", "here", "there",
        "everywhere", "somewhere", "anywhere", "nowhere", "never", "always",
        "sometimes", "often", "rarely", "already", "almost", "enough", "else",
        // common contractions
        "it's", "that's", "there's", "here's", "he's", "she's", "what's", "who's",
        "where's", "when's", "how's", "why's", "we're", "they're", "you're", "we'll",
        "we've", "we'd", "you'll", "you've", "you'd", "they'll", "they've", "they'd",
        "he'll", "he'd", "she'll", "she'd", "it'll", "let's", "don't", "doesn't",
        "didn't", "can't", "cannot", "couldn't", "won't", "wouldn't", "shouldn't",
        "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't", "hadn't",
        "mustn't", "ain't", "y'all",
    };

    /// <summary>
    /// A small set of distinctly German function words, for telling German from
    /// English under auto-detect. Words spelled identically in English ("so",
    /// "also", "in", "an", "war", "hat", "die", "will", "man") are deliberately
    /// excluded so English text can never look German.
    /// </summary>
    static readonly HashSet<string> GermanFunctionWords = new(StringComparer.Ordinal)
    {
        "ich", "du", "er", "sie", "es", "wir", "ihr", "sind", "ist", "bin", "bist",
        "seid", "waren", "sein", "haben", "habe", "hatte", "hatten", "wird", "werden",
        "wurde", "wurden", "und", "oder", "aber", "nicht", "kein", "keine", "keinen",
        "einen", "einem", "einer", "eines", "eine", "ein", "der", "das", "dem", "den",
        "des", "zu", "zum", "zur", "mit", "auf", "für", "von", "aus", "bei", "nach",
        "über", "unter", "vor", "zwischen", "durch", "gegen", "ohne", "um", "dass",
        "weil", "wenn", "als", "auch", "noch", "schon", "sehr", "nur", "dann", "doch",
        "ja", "nein", "bitte", "danke", "heute", "morgen", "gestern", "jetzt", "hier",
        "dort", "wo", "wie", "wer", "warum", "gehen", "geht", "gehe", "kommen",
        "kommt", "machen", "macht", "sagen", "sagt", "sehen", "sieht", "wissen",
        "weiß", "können", "kann", "müssen", "muss", "wollen", "sollen", "soll",
        "dürfen", "darf", "mögen", "mag", "hause", "mal", "ganz", "immer", "wieder",
        "alles", "etwas", "nichts", "mehr", "viel", "wirklich", "vielleicht",
    };

    /// <summary>The current line up to the caret.</summary>
    static ReadOnlySpan<char> LineBefore(string text, int offset)
    {
        var end = Math.Clamp(offset, 0, text.Length);
        var start = end;
        while (start > 0 && !IsNewline(text[start - 1])) start--;
        return text.AsSpan(start, end - start);
    }

    /// <summary>The current line from the caret onward.</summary>
    static ReadOnlySpan<char> LineAfter(string text, int offset)
    {
        var start = Math.Clamp(offset, 0, text.Length);
        var end = start;
        while (end < text.Length && !IsNewline(text[end])) end++;
        return text.AsSpan(start, end - start);
    }

    static bool IsNewline(char ch) =>
        ch is '\n' or '\r' or '\u000B' or '\u000C' or '\u0085' or '\u2028' or '\u2029';

    /// <summary>
    /// Han, Hiragana, Katakana, and the CJK punctuation and fullwidth blocks.
    /// Index is a UTF-16 unit; surrogate pairs (CJK extension B and beyond) are
    /// resolved to the full code point.
    /// </summary>
    static bool IsCjkAt(string text, int index)
    {
        if (index < 0 || index >= text.Length) return false;
        int value;
        var ch = text[index];
        if (char.IsHighSurrogate(ch) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]))
            value = char.ConvertToUtf32(ch, text[index + 1]);
        else if (char.IsLowSurrogate(ch) && index > 0 && char.IsHighSurrogate(text[index - 1]))
            value = char.ConvertToUtf32(text[index - 1], ch);
        else
            value = ch;
        return value is (>= 0x3000 and <= 0x30FF) or (>= 0x3400 and <= 0x4DBF)
            or (>= 0x4E00 and <= 0x9FFF) or (>= 0xF900 and <= 0xFAFF)
            or (>= 0xFF00 and <= 0xFFEF) or (>= 0x20000 and <= 0x2FFFF);
    }

    /// <summary>The opening run of letters and internal apostrophes: "I'll," → "I'll".</summary>
    static string LeadingToken(string text)
    {
        var end = 0;
        while (end < text.Length && (char.IsLetter(text[end]) || text[end] is '\'' or '\u2019')) end++;
        return text[..end];
    }

    static bool ShouldPreserveCapital(string token)
    {
        if (token == "I" || token.StartsWith("I'", StringComparison.Ordinal)
            || token.StartsWith("I\u2019", StringComparison.Ordinal)) return true;
        var letters = 0;
        var uppers = 0;
        foreach (var ch in token)
        {
            if (!char.IsLetter(ch)) continue;
            letters++;
            if (char.IsUpper(ch)) uppers++;
        }
        if (letters >= 2 && letters == uppers) return true;    // acronyms: NASA, API, OK
        var lowered = token.ToLowerInvariant().Replace('\u2019', '\'');
        if (DayAndMonthNames.Contains(lowered)) return true;
        // No name tagger on Windows: keep the capital unless this is a known
        // function word. Names, brands and anything unusual pass through intact.
        return !LowercaseOpeners.Contains(lowered);
    }

    /// <summary>
    /// German capitalises every noun, so its openers are never lowered. With
    /// auto-detect on, the language is inferred from the dictation itself.
    /// </summary>
    static bool CapitalisesNouns(string language, string text)
    {
        if (language == "de") return true;
        if (language != "auto" && language.Length != 0) return false;
        return LooksGerman(text);
    }

    static bool LooksGerman(string text)
    {
        var words = 0;
        var german = 0;
        var start = -1;
        for (var i = 0; i <= text.Length; i++)
        {
            var isLetter = i < text.Length && char.IsLetter(text[i]);
            if (isLetter && start < 0) start = i;
            if (!isLetter && start >= 0)
            {
                words++;
                if (GermanFunctionWords.Contains(text[start..i].ToLowerInvariant())) german++;
                start = -1;
            }
        }
        return german >= 2 && german * 4 >= words;
    }
}
