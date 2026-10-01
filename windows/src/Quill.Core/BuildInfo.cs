using System.Reflection;

namespace Quill;

public static class BuildInfo
{
    /// <summary>
    /// The app version, stamped into the assembly at build time from the
    /// VERSION file at the repo root (see windows/Directory.Build.props).
    /// It used to be a hardcoded constant, which drifted: a binary published
    /// as 0.9.0 reported itself as 0.8.3 and the updater then offered the
    /// build to itself as an update, forever.
    /// </summary>
    public static readonly string Version = ReadStampedVersion();

    public const string BundleId = "com.freeze.quill";

    static string ReadStampedVersion()
    {
        var stamped = typeof(BuildInfo).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;
        if (string.IsNullOrWhiteSpace(stamped)) return "0.0.0";
        // The SDK may append "+<commit>" build metadata; the updater compares
        // plain x.y.z numbers.
        var plus = stamped.IndexOf('+');
        return plus < 0 ? stamped : stamped[..plus];
    }
}
