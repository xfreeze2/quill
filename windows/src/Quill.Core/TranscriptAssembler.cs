namespace Quill;

/// <summary>
/// The server segments an utterance by <c>start</c> time. Within one segment the
/// partials are cumulative (each carries the whole segment so far). Last-write-wins
/// per start, never append. Interim empties must not wipe text we already have.
/// </summary>
public sealed class TranscriptAssembler
{
    readonly List<double> _order = [];
    readonly Dictionary<double, string> _segments = [];

    public string Transcript =>
        string.Join(" ", _order.Where(_segments.ContainsKey).Select(k => _segments[k]));

    public void Record(double start, string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        if (!_segments.ContainsKey(start)) _order.Add(start);
        _segments[start] = trimmed;
    }

    public void ReplaceWithConsolidated(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        _order.Clear();
        _segments.Clear();
        _order.Add(-1);
        _segments[-1] = trimmed;
    }

    public void Reset()
    {
        _order.Clear();
        _segments.Clear();
    }
}
