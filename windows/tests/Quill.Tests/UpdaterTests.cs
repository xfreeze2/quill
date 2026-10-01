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

public class BuildInfoTests
{
    [Fact]
    public void VersionComesFromTheVersionFile()
    {
        // If the number compiled into the binary ever drifts from the VERSION
        // file again, the updater offers a release to itself. This walks up
        // from the test bin directory to the repo root and compares.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "VERSION")))
            dir = dir.Parent;
        Assert.NotNull(dir);
        var expected = File.ReadAllText(Path.Combine(dir!.FullName, "VERSION")).Trim();
        Assert.Equal(expected, BuildInfo.Version);
    }
}
