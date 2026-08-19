using System.Text.Json;
using Quill;

namespace Quill.Win.Native;

sealed class JsonSettingsStore : ISettingsStore
{
    readonly string _path;
    readonly object _gate = new();
    Dictionary<string, JsonElement> _data = new(StringComparer.Ordinal);

    public JsonSettingsStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Quill", "settings.json");
        Load();
    }

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Quill", "settings.json");

    void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            using var doc = JsonDocument.Parse(File.ReadAllText(_path));
            _data = doc.RootElement.EnumerateObject()
                .ToDictionary(p => p.Name, p => p.Value.Clone(), StringComparer.Ordinal);
        }
        catch
        {
            _data = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        }
    }

    void Save()
    {
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var obj = new Dictionary<string, object?>();
        foreach (var (k, v) in _data)
            obj[k] = JsonSerializer.Deserialize<object>(v.GetRawText());
        File.WriteAllText(_path, JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true }));
    }

    public bool GetBool(string key, bool defaultValue)
    {
        lock (_gate) return _data.TryGetValue(key, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? v.GetBoolean() : defaultValue;
    }

    public void SetBool(string key, bool value)
    {
        lock (_gate)
        {
            _data[key] = JsonSerializer.SerializeToElement(value);
            Save();
        }
    }

    public double GetDouble(string key, double defaultValue)
    {
        lock (_gate) return _data.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : defaultValue;
    }

    public void SetDouble(string key, double value)
    {
        lock (_gate)
        {
            _data[key] = JsonSerializer.SerializeToElement(value);
            Save();
        }
    }

    public string GetString(string key, string defaultValue)
    {
        lock (_gate) return _data.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? defaultValue : defaultValue;
    }

    public void SetString(string key, string value)
    {
        lock (_gate)
        {
            _data[key] = JsonSerializer.SerializeToElement(value);
            Save();
        }
    }

    public IReadOnlyList<string> GetStringList(string key)
    {
        lock (_gate)
        {
            if (!_data.TryGetValue(key, out var v) || v.ValueKind != JsonValueKind.Array)
                return Array.Empty<string>();
            return v.EnumerateArray().Select(e => e.GetString() ?? "").Where(s => s.Length > 0).ToList();
        }
    }

    public void SetStringList(string key, IReadOnlyList<string> value)
    {
        lock (_gate)
        {
            _data[key] = JsonSerializer.SerializeToElement(value);
            Save();
        }
    }

    public void Remove(string key)
    {
        lock (_gate)
        {
            _data.Remove(key);
            Save();
        }
    }
}
