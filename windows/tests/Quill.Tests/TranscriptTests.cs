using Quill;
using Xunit;

namespace Quill.Tests;

public class TranscriptTests
{
    [Fact]
    public void LastWriteWinsPerSegment()
    {
        var a = new TranscriptAssembler();
        a.Record(0, "hello");
        a.Record(0, "hello there");
        Assert.Equal("hello there", a.Transcript);
    }

    [Fact]
    public void JoinsSegmentsInOrder()
    {
        var a = new TranscriptAssembler();
        a.Record(0, "one");
        a.Record(1.2, "two");
        a.Record(0, "one plus");
        Assert.Equal("one plus two", a.Transcript);
    }

    [Fact]
    public void EmptyPartialDoesNotWipe()
    {
        var a = new TranscriptAssembler();
        a.Record(0, "kept");
        a.Record(0, "   ");
        Assert.Equal("kept", a.Transcript);
    }

    [Fact]
    public void ConsolidatedReplaces()
    {
        var a = new TranscriptAssembler();
        a.Record(0, "partial");
        a.ReplaceWithConsolidated("full sentence");
        Assert.Equal("full sentence", a.Transcript);
    }
}
