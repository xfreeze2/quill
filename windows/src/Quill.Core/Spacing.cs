namespace Quill;

/// <summary>
/// Whether a space should go between existing text and the insertion.
/// Mirrors the Mac Accessibility inserter so Windows paste/UIA land the same way.
/// Offsets are UTF-16 units, matching both .NET strings and the Mac code.
/// </summary>
public static class Spacing
{
    const string OpeningBefore = "([{<\u201C\u2018\"'-–—/@#";
    const string ClosingAfter = ",.;:!?)]}%\u201D\u2019";

    public static bool NeedsSeparator(string? existing, int? offset, string inserting)
    {
        if (string.IsNullOrEmpty(existing) || offset is null or <= 0) return false;
        var boundary = CharacterBefore(existing, offset.Value);
        if (boundary is null) return false;
        var ch = boundary.Value;
        if (char.IsWhiteSpace(ch)) return false;
        if (OpeningBefore.Contains(ch)) return false;
        if (inserting.Length > 0 && ClosingAfter.Contains(inserting[0])) return false;
        return true;
    }

    public static bool NeedsTrailingSeparator(string? existing, int? offset, string inserting)
    {
        if (existing is null || offset is null || offset.Value >= existing.Length) return false;
        var next = CharacterAtOrAfter(existing, offset.Value);
        if (next is null) return false;
        var ch = next.Value;
        if (char.IsWhiteSpace(ch)) return false;
        if (ClosingAfter.Contains(ch)) return false;
        if (inserting.Length > 0 && char.IsWhiteSpace(inserting[^1])) return false;
        return true;
    }

    public static string Apply(string payload, string? existing, int? offset)
    {
        var before = NeedsSeparator(existing, offset, payload);
        var after = NeedsTrailingSeparator(existing, offset, payload);
        if (before) payload = " " + payload;
        if (after) payload += " ";
        return payload;
    }

    static char? CharacterAtOrAfter(string text, int utf16Offset)
    {
        if (utf16Offset < 0 || utf16Offset >= text.Length) return null;
        return text[utf16Offset];
    }

    static char? CharacterBefore(string text, int utf16Offset)
    {
        if (utf16Offset <= 0 || utf16Offset > text.Length) return null;
        return text[utf16Offset - 1];
    }
}
