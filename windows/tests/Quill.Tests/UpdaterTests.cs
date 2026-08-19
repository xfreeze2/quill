using Quill;
using Xunit;

namespace Quill.Tests;

public class UpdaterTests
{
    [Theory]
    [InlineData("0.8.4", "0.8.3", true)]
    [InlineData("0.9.0", "0.8.3", true)]
    [InlineData("0.10.0", "0.9.0", true)]
    [InlineData("0.8.3", "0.8.3", false)]
    [InlineData("0.8.2", "0.8.3", false)]
    [InlineData("0.8.3-windows", "0.8.3", false)]
    public void ComparesDotVersions(string candidate, string current, bool newer) =>
        Assert.Equal(newer, Updater.IsNewer(candidate, current));
}
