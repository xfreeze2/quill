using Quill;
using Xunit;

namespace Quill.Tests;

/// <summary>
/// Port of the Mac app's tests/TextTidyTest.swift. Two cases differ by design:
/// Windows has no on-device name tagger, so unknown capitalised openers keep
/// their capital (names always survive; "Git status" in a terminal keeps its G).
/// </summary>
public class TextTidyTests
{
    static int End(string s) => s.Length;

    // MARK: IsContinuation — are we landing mid-sentence?

    [Theory]
    [InlineData("so I was thinking ")]
    [InlineData("so I was thinking")]
    [InlineData("first, ")]
    [InlineData("note: ")]
    [InlineData("one thing — ")]
    [InlineData("step 1 ")]
    [InlineData("(see above) ")]
    public void ContinuationAfterUnfinishedText(string existing) =>
        Assert.True(TextTidy.IsContinuation(existing, End(existing)));

    [Fact]
    public void ContinuationMidTextAtCaret() =>
        Assert.True(TextTidy.IsContinuation("abcdef", 3));

    [Theory]
    [InlineData("Done. ")]
    [InlineData("Really? ")]
    [InlineData("Wow! ")]
    [InlineData("and then… ")]
    [InlineData("好的。")]
    [InlineData("line one\n")]
    [InlineData("para one\n\n")]
    [InlineData("para one\n    ")]
    [InlineData("He said \"hello.\" ")]
    [InlineData("(done.) ")]
    public void NotContinuationAfterFinishedText(string existing) =>
        Assert.False(TextTidy.IsContinuation(existing, End(existing)));

    [Fact]
    public void NotContinuationAtEmptyNilOrStart()
    {
        Assert.False(TextTidy.IsContinuation("", 0));
        Assert.False(TextTidy.IsContinuation(null, null));
        Assert.False(TextTidy.IsContinuation("hello", 0));
        Assert.False(TextTidy.IsContinuation("   ", 3));
    }

    [Fact]
    public void OnlyTheCurrentLineCounts()
    {
        // A previous unfinished line does not make the next one a continuation.
        Assert.False(TextTidy.IsContinuation("no stop here\n", End("no stop here\n")));
        Assert.True(TextTidy.IsContinuation("Done.\nand then ", End("Done.\nand then ")));
    }

    [Theory]
    [InlineData("- ")]
    [InlineData("• ")]
    [InlineData("* ")]
    [InlineData("1. ")]
    [InlineData("12) ")]
    [InlineData("a) ")]
    [InlineData("text\n  - ")]
    [InlineData("## ")]
    [InlineData("> ")]
    public void ListItemsStartFresh(string existing) =>
        Assert.False(TextTidy.IsContinuation(existing, End(existing)));

    [Fact]
    public void DashInsideASentenceIsStillContinuation() =>
        Assert.True(TextTidy.IsContinuation("so - ", End("so - ")));

    // MARK: SentenceContinues — does what follows the caret carry on?

    [Fact]
    public void SentenceContinuesCases()
    {
        Assert.True(TextTidy.SentenceContinues("I think  we should go", End("I think ")));
        Assert.True(TextTidy.SentenceContinues("I think, we should", End("I think")));
        Assert.False(TextTidy.SentenceContinues("I think", End("I think")));
        Assert.False(TextTidy.SentenceContinues("one. Two", End("one. ")));
        Assert.False(TextTidy.SentenceContinues("one\nnext line", End("one")));
        Assert.False(TextTidy.SentenceContinues(null, null));
    }

    // MARK: DecapitalizeLead — lower the opener, keep the exceptions

    [Theory]
    [InlineData("So we could ship", "so we could ship")]
    [InlineData("The cat", "the cat")]
    [InlineData("A thing", "a thing")]
    [InlineData("And then it works", "and then it works")]
    [InlineData("Because of that", "because of that")]
    [InlineData("Which means", "which means")]
    [InlineData("It's fine", "it's fine")]
    public void LowersPlainOpeners(string text, string expected) =>
        Assert.Equal(expected, TextTidy.DecapitalizeLead(text));

    [Theory]
    [InlineData("I think")]
    [InlineData("I'm sure")]
    [InlineData("I'll go")]
    [InlineData("I’ve seen it")]
    [InlineData("NASA rocks")]
    [InlineData("API keys")]
    [InlineData("OK then")]
    [InlineData("Monday we ship")]
    [InlineData("December is cold")]
    [InlineData("John said hi")]
    [InlineData("Paris is nice")]
    [InlineData("Google it")]
    [InlineData("Elon said")]
    [InlineData("Cursor is fast")]
    [InlineData("Grok answered")]
    public void KeepsCapitalsThatBelong(string text) =>
        Assert.Equal(text, TextTidy.DecapitalizeLead(text));

    [Fact]
    public void LeavesNonLettersAndLowercaseAlone()
    {
        Assert.Equal("hello there", TextTidy.DecapitalizeLead("hello there"));
        Assert.Equal("123 go", TextTidy.DecapitalizeLead("123 go"));
        Assert.Equal("", TextTidy.DecapitalizeLead(""));
        Assert.Equal("我们可以", TextTidy.DecapitalizeLead("我们可以"));
    }

    [Fact]
    public void GermanIsLeftAlone()
    {
        Assert.Equal("Hunde sind toll", TextTidy.DecapitalizeLead("Hunde sind toll", "de"));
        Assert.Equal("Dann gehen wir nach Hause", TextTidy.DecapitalizeLead("Dann gehen wir nach Hause", "auto"));
        Assert.Equal("so we could ship it", TextTidy.DecapitalizeLead("So we could ship it", "auto"));
    }

    // MARK: TrimTrailingTerminator

    [Fact]
    public void TrimsOneTrailingTerminator()
    {
        Assert.Equal("maybe later", TextTidy.TrimTrailingTerminator("maybe later."));
        Assert.Equal("maybe later", TextTidy.TrimTrailingTerminator("maybe later?"));
        Assert.Equal("maybe later…", TextTidy.TrimTrailingTerminator("maybe later…"));
        Assert.Equal("maybe later", TextTidy.TrimTrailingTerminator("maybe later"));
        Assert.Equal("what?", TextTidy.TrimTrailingTerminator("what?!"));
    }

    // MARK: Spacing (formerly Spacing.cs, same behaviour plus CJK)

    [Fact]
    public void SpacingRules()
    {
        Assert.True(TextTidy.NeedsSeparator("hello", 5, "world"));
        Assert.False(TextTidy.NeedsSeparator("hello ", 6, "world"));
        Assert.False(TextTidy.NeedsSeparator("(", 1, "world"));
        Assert.False(TextTidy.NeedsSeparator("hello", 5, ", world"));
        Assert.False(TextTidy.NeedsSeparator("", 0, "world"));
        Assert.True(TextTidy.NeedsTrailingSeparator("hello world", 6, "there"));
        Assert.False(TextTidy.NeedsTrailingSeparator("hello world", 5, "there"));
        Assert.False(TextTidy.NeedsSeparator("我在想", 3, "我们"));
        Assert.False(TextTidy.NeedsTrailingSeparator("我在想", 1, "们"));
        Assert.False(TextTidy.NeedsTrailingSeparator("hello, world", 5, "there"));
        Assert.False(TextTidy.NeedsTrailingSeparator("hello", 5, "there"));
    }

    [Fact]
    public void SpacingSurvivesNullsAndBadOffsets()
    {
        Assert.False(TextTidy.NeedsSeparator(null, 3, "x"));
        Assert.False(TextTidy.NeedsSeparator("hi", null, "x"));
        Assert.False(TextTidy.NeedsSeparator("hi", -1, "x"));
        Assert.True(TextTidy.NeedsSeparator("hi", 99, "x"));   // clamped to the end
        Assert.False(TextTidy.NeedsTrailingSeparator("hi", 99, "x"));
        Assert.False(TextTidy.NeedsTrailingSeparator("hi", -1, "x"));
    }

    // MARK: Fit — the whole thing, as the inserter uses it

    [Fact]
    public void TheReportedBugAppendMidSentence() =>
        Assert.Equal("so we could ship on Friday.",
            TextTidy.Fit("So we could ship on Friday.", "so I was thinking ", End("so I was thinking ")));

    [Fact]
    public void AppendMidSentenceWithoutTrailingSpaceAddsOne() =>
        Assert.Equal(" so we could",
            TextTidy.Fit("So we could", "so I was thinking", End("so I was thinking")));

    [Fact]
    public void AppendAfterAFullStopKeepsTheCapital()
    {
        Assert.Equal("Great idea.", TextTidy.Fit("Great idea.", "Done. ", End("Done. ")));
        Assert.Equal(" Great idea.", TextTidy.Fit("Great idea.", "Done.", End("Done.")));
    }

    [Fact]
    public void EmptyOrUnreadableFieldUntouched()
    {
        Assert.Equal("Hello world.", TextTidy.Fit("Hello world.", "", 0));
        Assert.Equal("Hello world.", TextTidy.Fit("Hello world.", null, null));
    }

    [Fact]
    public void NullOffsetMeansTheEndOfTheField() =>
        Assert.Equal("so we could", TextTidy.Fit("So we could", "I was thinking ", null));

    [Fact]
    public void MidSentenceIStaysCapital() =>
        Assert.Equal("I think so.", TextTidy.Fit("I think so.", "you know ", End("you know ")));

    [Fact]
    public void InsertIntoTheMiddleOfASentence()
    {
        // Case and full stop corrected, one space before.
        Assert.Equal(" maybe", TextTidy.Fit("Maybe.", "I think we should go", End("I think")));
        // No gap on either side: both spaces.
        Assert.Equal(" maybe ", TextTidy.Fit("Maybe.", "I thinkwe should go", End("I think")));
        // Before a comma: the full stop and the trailing space both go.
        Assert.Equal(" maybe", TextTidy.Fit("Maybe.", "I think, we should go", End("I think")));
        // Before a new sentence: the full stop stays.
        Assert.Equal("Maybe. ", TextTidy.Fit("Maybe.", "I think. We should go", End("I think. ")));
    }

    [Fact]
    public void FreshLinesAndListItemsKeepTheirCapital()
    {
        Assert.Equal("Buy milk.", TextTidy.Fit("Buy milk.", "Shopping:\n- ", End("Shopping:\n- ")));
        Assert.Equal("Buy milk.", TextTidy.Fit("Buy milk.", "1. ", End("1. ")));
        Assert.Equal("Buy milk.", TextTidy.Fit("Buy milk.", "Shopping list\n", End("Shopping list\n")));
    }

    [Fact]
    public void NameMidSentenceKeepsItsCapital() =>
        Assert.Equal("John will know.", TextTidy.Fit("John will know.", "ask ", End("ask ")));

    [Fact]
    public void UnknownOpenerKeepsItsCapitalOnWindows()
    {
        // The Mac's tagger lowers "Git" here; without one, an unknown word keeps
        // its capital — the safer error, and terminals are unreadable via
        // WM_GETTEXT anyway, so this path rarely triggers for prompts.
        Assert.Equal("Git status.", TextTidy.Fit("Git status.", "~/code ❯ ", End("~/code ❯ ")));
    }

    [Fact]
    public void ChinesePassesStraightThrough() =>
        Assert.Equal("我们可以明天再说。", TextTidy.Fit("我们可以明天再说。", "我在想", End("我在想")));

    [Fact]
    public void SurrogatePairCjkNeedsNoSpace()
    {
        // U+20BB7 (𠮷) is a surrogate pair; spacing must treat it as CJK.
        var existing = "\U00020BB7";
        Assert.False(TextTidy.NeedsSeparator(existing, existing.Length, "我们"));
    }
}
