using Quill;
using Xunit;

namespace Quill.Tests;

public class VoiceCommandsTests
{
    static int Fired(params string[] partials)
    {
        var didRun = false;
        var count = 0;
        foreach (var text in partials.Where(t => t.Length > 0))
        {
            if (!didRun && VoiceCommands.ContainsOpenGrok(text))
            {
                didRun = true;
                count++;
            }
        }
        return count;
    }

    [Theory]
    [InlineData("open Grok, write a haiku")]
    [InlineData("Open Grok Build then write")]
    [InlineData("please open grok")]
    [InlineData("launch grok")]
    [InlineData("start up the grok")]
    [InlineData("open croc")]
    [InlineData("open grock")]
    [InlineData("  open Grok, hello")]
    public void StartOfUtteranceIsACommand(string text) =>
        Assert.True(VoiceCommands.ContainsOpenGrok(text), text);

    [Theory]
    [InlineData("I think we should open Grok now")]
    [InlineData("write this then open grok")]
    [InlineData("and then please open grok")]
    [InlineData("can you open Grok Build after this")]
    [InlineData("open the document")]
    [InlineData("It opens croc. But the problem is If somebody's already in the middle of talking")]
    [InlineData("In the middle whenever somebody says open Grok")]
    [InlineData("Grok, then it shouldn't open")]
    public void MidSentenceIsNotACommand(string text) =>
        Assert.False(VoiceCommands.ContainsOpenGrok(text), text);

    [Fact]
    public void StreamMidNeverFires() =>
        Assert.Equal(0, Fired(
            "I think",
            "I think we should",
            "I think we should open",
            "I think we should open Grok",
            "I think we should open Grok and try that"));

    [Fact]
    public void StreamStartFiresOnce() =>
        Assert.Equal(1, Fired("open", "open Grok", "open Grok, write me a haiku"));

    [Fact]
    public void StreamStartAfterPlease() =>
        Assert.Equal(1, Fired("please", "please open", "please open grok"));

    [Fact]
    public void StripStart() =>
        Assert.Equal("write a haiku", VoiceCommands.Strip("open Grok, write a haiku"));

    [Fact]
    public void StripStartBuild() =>
        Assert.Equal(
            "then write me a haiku about rockets",
            VoiceCommands.Strip("open Grok Build, then write me a haiku about rockets"));

    [Fact]
    public void StripMidUnchanged() =>
        Assert.Equal(
            "I think we should open Grok now",
            VoiceCommands.Strip("I think we should open Grok now"));

    [Fact]
    public void StripLaterUnchanged() =>
        Assert.Equal(
            "write this then open grok",
            VoiceCommands.Strip("write this then open grok"));

    [Theory]
    [InlineData("hello that's it")]
    [InlineData("hello thats it")]
    [InlineData("hello that’s it")]
    [InlineData("hello that's all")]
    [InlineData("that's it")]
    [InlineData("and that's all.")]
    public void TrailingStopPhrase(string text) =>
        Assert.True(VoiceCommands.EndsWithStopPhrase(text), text);

    [Theory]
    [InlineData("that's it exactly")]
    [InlineData("that's all I need from you")]
    [InlineData("that is it")]
    public void MidStopPhraseDoesNotEnd(string text) =>
        Assert.False(VoiceCommands.EndsWithStopPhrase(text), text);

    [Fact]
    public void StripStopPhrase() =>
        Assert.Equal("hello there", VoiceCommands.StripStopPhrase("hello there that's it"));

    [Fact]
    public void StripAllRemovesCommandAndStop() =>
        Assert.Equal(
            "write a haiku",
            VoiceCommands.StripAll("open Grok, write a haiku that's it"));
}
