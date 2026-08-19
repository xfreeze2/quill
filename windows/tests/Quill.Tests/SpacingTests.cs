using Quill;
using Xunit;

namespace Quill.Tests;

public class SpacingTests
{
    [Fact]
    public void AddsSpaceBetweenWords() =>
        Assert.True(Spacing.NeedsSeparator("hello", 5, "world"));

    [Fact]
    public void NoSpaceAfterExistingSpace() =>
        Assert.False(Spacing.NeedsSeparator("hello ", 6, "world"));

    [Fact]
    public void NoSpaceAfterOpeningBracket() =>
        Assert.False(Spacing.NeedsSeparator("hello (", 7, "world"));

    [Fact]
    public void NoSpaceBeforeComma() =>
        Assert.False(Spacing.NeedsSeparator("hello", 5, ","));

    [Fact]
    public void EmptyExistingNeedsNoSpace() =>
        Assert.False(Spacing.NeedsSeparator("", 0, "hello"));

    [Fact]
    public void TrailingSpaceWhenLandingMidText() =>
        Assert.True(Spacing.NeedsTrailingSeparator("helloworld", 5, "there"));

    [Fact]
    public void NoTrailingSpaceAtEnd() =>
        Assert.False(Spacing.NeedsTrailingSeparator("hello", 5, "world"));

    [Fact]
    public void NoTrailingSpaceBeforePunctuation() =>
        Assert.False(Spacing.NeedsTrailingSeparator("hello,", 5, "world"));

    [Fact]
    public void ApplyBothSides()
    {
        var payload = Spacing.Apply("mid", "ab", 1);
        Assert.Equal(" mid ", payload);
    }
}
