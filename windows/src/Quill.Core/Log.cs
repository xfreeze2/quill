using System.Text;

namespace Quill;

/// <summary>
/// Append-only breadcrumb trail. No transcript content, no credentials.
/// Capped so it cannot accumulate indefinitely.
/// </summary>
public sealed class Log
{
    public const int MaxBytes = 512 * 1024;
    readonly string _path;
    readonly object _gate = new();

    public Log(string path)
    {
        _path = path;
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
    }

    public static string DefaultPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Quill",
            "Quill.log");

    public void Write(string message)
    {
        var line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + message + "\n";
        var data = Encoding.UTF8.GetBytes(line);
        lock (_gate)
        {
            try
            {
                if (File.Exists(_path) && new FileInfo(_path).Length > MaxBytes)
                {
                    var existing = File.ReadAllText(_path);
                    var keepFrom = Math.Max(0, existing.Length / 2);
                    File.WriteAllText(_path, existing[keepFrom..]);
                }
                File.AppendAllText(_path, line);
            }
            catch
            {
                // Logging must never take down dictation.
            }
        }
        _ = data;
    }
}
