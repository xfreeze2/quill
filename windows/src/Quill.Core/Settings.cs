namespace Quill;

public enum Trigger
{
    Control,
    RightWin,
    RightAlt,
    F5,
}

public static class TriggerInfo
{
    public static string Title(Trigger t) => t switch
    {
        Trigger.Control => "Control",
        Trigger.RightWin => "Right Windows",
        Trigger.RightAlt => "Right Alt",
        Trigger.F5 => "F5",
        _ => t.ToString(),
    };

    public static string Gesture(Trigger t, bool singleTap)
    {
        if (t == Trigger.F5) return "Press F5";
        return (singleTap ? "Tap " : "Double-tap ") + Title(t);
    }

    public static Trigger Parse(string? raw) => raw switch
    {
        "rightWin" or "rightCommand" => Trigger.RightWin,
        "rightAlt" or "rightOption" => Trigger.RightAlt,
        "f5" => Trigger.F5,
        "control" => Trigger.Control,
        _ => Trigger.Control,
    };

    public static string WireName(Trigger t) => t switch
    {
        Trigger.Control => "control",
        Trigger.RightWin => "rightWin",
        Trigger.RightAlt => "rightAlt",
        Trigger.F5 => "f5",
        _ => "control",
    };
}

public interface ISettingsStore
{
    bool GetBool(string key, bool defaultValue);
    void SetBool(string key, bool value);
    double GetDouble(string key, double defaultValue);
    void SetDouble(string key, double value);
    string GetString(string key, string defaultValue);
    void SetString(string key, string value);
    IReadOnlyList<string> GetStringList(string key);
    void SetStringList(string key, IReadOnlyList<string> value);
    void Remove(string key);
}

public static class SettingKeys
{
    public const string Language = "language";
    public const string History = "history";
    public const string CornerButton = "cornerButton";
    public const string InsertAtEnd = "insertAtEnd";
    public const string ClickToInsert = "clickToInsert";
    public const string Trigger = "trigger";
    public const string SingleTap = "singleTap";
    public const string DidShowSetup = "didShowSetup";
    public const string StopPhrase = "stopPhrase";
    public const string PauseSeconds = "pauseSeconds";
    public const string Polish = "polish";
    public const string KeepHistory = "keepHistory";
    public const string NotifyUpdates = "notifyUpdates";
    public const string LastUpdateCheck = "lastUpdateCheck";
    public const string AvailableUpdateVersion = "availableUpdateVersion";
    public const string AvailableUpdateURL = "availableUpdateURL";
    public const string NotifiedUpdateVersion = "notifiedUpdateVersion";
    public const string HudEdge = "hudEdge";
    public const string HudEdgeOffset = "hudEdgeOffset";
}

public sealed class Settings
{
    readonly ISettingsStore _store;

    public Settings(ISettingsStore store) => _store = store;

    public ISettingsStore Store => _store;

    public bool CornerButton { get => _store.GetBool(SettingKeys.CornerButton, true); set => _store.SetBool(SettingKeys.CornerButton, value); }
    public bool InsertAtEnd { get => _store.GetBool(SettingKeys.InsertAtEnd, true); set => _store.SetBool(SettingKeys.InsertAtEnd, value); }
    public bool ClickToInsert { get => _store.GetBool(SettingKeys.ClickToInsert, true); set => _store.SetBool(SettingKeys.ClickToInsert, value); }
    public bool SingleTap { get => _store.GetBool(SettingKeys.SingleTap, true); set => _store.SetBool(SettingKeys.SingleTap, value); }
    public bool DidShowSetup { get => _store.GetBool(SettingKeys.DidShowSetup, false); set => _store.SetBool(SettingKeys.DidShowSetup, value); }
    public bool StopPhrase { get => _store.GetBool(SettingKeys.StopPhrase, true); set => _store.SetBool(SettingKeys.StopPhrase, value); }
    public bool Polish { get => _store.GetBool(SettingKeys.Polish, false); set => _store.SetBool(SettingKeys.Polish, value); }
    public bool KeepHistory { get => _store.GetBool(SettingKeys.KeepHistory, true); set => _store.SetBool(SettingKeys.KeepHistory, value); }
    public bool NotifyUpdates { get => _store.GetBool(SettingKeys.NotifyUpdates, true); set => _store.SetBool(SettingKeys.NotifyUpdates, value); }
    public double PauseSeconds { get => _store.GetDouble(SettingKeys.PauseSeconds, 5.0); set => _store.SetDouble(SettingKeys.PauseSeconds, value); }
    public string Language { get => _store.GetString(SettingKeys.Language, "en"); set => _store.SetString(SettingKeys.Language, value); }
    public Trigger Trigger { get => TriggerInfo.Parse(_store.GetString(SettingKeys.Trigger, "control")); set => _store.SetString(SettingKeys.Trigger, TriggerInfo.WireName(value)); }
    public string HudEdge { get => _store.GetString(SettingKeys.HudEdge, "right"); set => _store.SetString(SettingKeys.HudEdge, value); }
    public double HudEdgeOffset { get => _store.GetDouble(SettingKeys.HudEdgeOffset, 0.82); set => _store.SetDouble(SettingKeys.HudEdgeOffset, value); }

    public IReadOnlyList<string> History => _store.GetStringList(SettingKeys.History);

    public void Remember(string text)
    {
        if (!KeepHistory) return;
        var next = new List<string> { text };
        next.AddRange(History.Where(h => h != text).Take(19));
        _store.SetStringList(SettingKeys.History, next);
    }

    public void ClearHistory() => _store.Remove(SettingKeys.History);

    public void Flip(string key)
    {
        var current = key switch
        {
            SettingKeys.CornerButton => CornerButton,
            SettingKeys.InsertAtEnd => InsertAtEnd,
            SettingKeys.ClickToInsert => ClickToInsert,
            SettingKeys.SingleTap => SingleTap,
            SettingKeys.StopPhrase => StopPhrase,
            SettingKeys.Polish => Polish,
            SettingKeys.KeepHistory => KeepHistory,
            SettingKeys.NotifyUpdates => NotifyUpdates,
            _ => false,
        };
        switch (key)
        {
            case SettingKeys.CornerButton: CornerButton = !current; break;
            case SettingKeys.InsertAtEnd: InsertAtEnd = !current; break;
            case SettingKeys.ClickToInsert: ClickToInsert = !current; break;
            case SettingKeys.SingleTap: SingleTap = !current; break;
            case SettingKeys.StopPhrase: StopPhrase = !current; break;
            case SettingKeys.Polish: Polish = !current; break;
            case SettingKeys.KeepHistory: KeepHistory = !current; break;
            case SettingKeys.NotifyUpdates: NotifyUpdates = !current; break;
        }
    }
}

public sealed class MemorySettingsStore : ISettingsStore
{
    readonly Dictionary<string, object> _data = new(StringComparer.Ordinal);

    public bool GetBool(string key, bool defaultValue) =>
        _data.TryGetValue(key, out var v) && v is bool b ? b : defaultValue;

    public void SetBool(string key, bool value) => _data[key] = value;

    public double GetDouble(string key, double defaultValue) =>
        _data.TryGetValue(key, out var v) && v is double d ? d : defaultValue;

    public void SetDouble(string key, double value) => _data[key] = value;

    public string GetString(string key, string defaultValue) =>
        _data.TryGetValue(key, out var v) && v is string s ? s : defaultValue;

    public void SetString(string key, string value) => _data[key] = value;

    public IReadOnlyList<string> GetStringList(string key) =>
        _data.TryGetValue(key, out var v) && v is List<string> list ? list : Array.Empty<string>();

    public void SetStringList(string key, IReadOnlyList<string> value) =>
        _data[key] = value.ToList();

    public void Remove(string key) => _data.Remove(key);
}
