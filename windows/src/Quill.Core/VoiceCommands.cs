using System.Text.RegularExpressions;

namespace Quill;

/// <summary>
/// Spoken commands that act while you keep talking.
///
/// "open Grok" is only a command when it is the first thing said. Mid-sentence
/// it is ordinary speech. The phrase is removed from the inserted text only
/// when it counted as a command.
/// </summary>
public static class VoiceCommands
{
    /// <summary>
    /// "open grok" / "open grok build", allowing for how speech-to-text actually
    /// hears the word — grock, grog, croc and friends all turn up in practice.
    /// Anchored to the start on purpose.
    /// </summary>
    static readonly Regex OpenGrok = new(
        @"^[\s,.!?]*(?:please\s+)?(?:open|launch|start)\s+(?:up\s+)?(?:the\s+)?"
        + @"(?:gro(?:k|ck|g|c)|crock|croc|grokk)(?:\s+build)?\b[\s,.!?]*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>
    /// "that's it" or "that's all" — but only as the very last thing said.
    /// </summary>
    static readonly Regex StopPhrase = new(
        @"(?:^|\s)(?:and\s+)?that(?:'|’)?s\s+(?:it|all)\b[\s,.!?]*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    static readonly Regex ExtraSpace = new(@"\s{2,}", RegexOptions.Compiled);

    public static bool ContainsOpenGrok(string text) =>
        OpenGrok.IsMatch(text);

    public static bool EndsWithStopPhrase(string text) =>
        StopPhrase.IsMatch(text);

    public static string StripStopPhrase(string text) =>
        StopPhrase.Replace(text, "").Trim();

    public static string Strip(string text)
    {
        var stripped = OpenGrok.Replace(text, " ");
        return ExtraSpace.Replace(stripped, " ").Trim();
    }

    public static string StripAll(string text) => StripStopPhrase(Strip(text));
}
