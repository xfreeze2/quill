namespace Quill;

/// <summary>
/// Tap detection for a trigger key the OS itself reacts to. A bare Right
/// Windows tap opens the Start menu on release, and a bare Right Alt tap arms
/// the menu bar of the focused window — both react to the key events
/// themselves, so detecting the tap is not enough: the events must be
/// swallowed before the OS sees them. This decides, per real event, whether
/// the hook forwards it, eats it, or eats it and re-injects the chord the user
/// actually meant (Right Win+L must still lock the machine). Pure logic so it
/// can be tested without a keyboard.
/// </summary>
public sealed class SwallowedTrigger
{
    /// <summary>A press released after this long is a hold, not a tap.</summary>
    public const double TapMaxHold = 0.35;

    /// <summary>Two taps this close together count as a double tap.</summary>
    public const double DoubleWindow = 0.42;

    public enum Verdict
    {
        /// <summary>Pass the event on unchanged.</summary>
        Forward,
        /// <summary>Eat the event; the OS must never see it.</summary>
        Swallow,
        /// <summary>Eat the event and toggle dictation.</summary>
        SwallowAndFire,
        /// <summary>
        /// Eat this other key's down and inject trigger-down followed by a copy
        /// of the key, so the OS sees the chord it was about to miss.
        /// </summary>
        SwallowAndReplay,
    }

    public bool SingleTap { get; set; } = true;

    bool _held;
    double _pressedAt;
    bool _tapPending;  // a first tap was seen and the double window is open
    double _lastTapAt;
    bool _chorded; // the trigger-down was re-injected; the OS believes the key is down
    bool _spent;   // this press can no longer count as a tap (fired, chorded, or clicked)

    public bool IsHeld => _held;

    /// <summary>The trigger key went down (or auto-repeated while held).</summary>
    public Verdict TriggerDown(double now)
    {
        if (_held) return Verdict.Swallow; // auto-repeat; keep the first press time

        _held = true;
        _pressedAt = now;
        _chorded = false;

        if (!SingleTap && _tapPending && now - _lastTapAt < DoubleWindow)
        {
            _tapPending = false;
            _spent = true; // the release of this second press is not another tap
            return Verdict.SwallowAndFire;
        }

        _tapPending = false;
        _spent = false;
        return Verdict.Swallow;
    }

    /// <summary>The trigger key was released.</summary>
    public Verdict TriggerUp(double now)
    {
        // An up we never saw the down for (key held across hook install, or the
        // release landed on the secure desktop): let the OS keep its own story
        // straight rather than eating a release it expects.
        if (!_held) return Verdict.Forward;

        var held = now - _pressedAt;
        var chorded = _chorded;
        var spent = _spent;
        _held = false;
        _chorded = false;
        _spent = false;

        if (chorded) return Verdict.Forward; // the OS saw our injected down; it needs the release
        if (spent || held >= TapMaxHold) return Verdict.Swallow;
        if (SingleTap) return Verdict.SwallowAndFire;
        _tapPending = true;
        _lastTapAt = now;
        return Verdict.Swallow;
    }

    /// <summary>A real, non-trigger key went down.</summary>
    public Verdict OtherKeyDown()
    {
        _tapPending = false; // an interleaved key breaks a double-tap pair
        if (!_held || _chorded) return Verdict.Forward;
        _chorded = true;
        _spent = true;
        return Verdict.SwallowAndReplay;
    }

    /// <summary>A click or wheel tick; only matters while the trigger is held.</summary>
    public void MouseChord()
    {
        if (_held) _spent = true;
    }

    /// <summary>Forget everything — the trigger key or hook changed.</summary>
    public void Reset()
    {
        _held = false;
        _pressedAt = 0;
        _tapPending = false;
        _lastTapAt = 0;
        _chorded = false;
        _spent = false;
    }
}
