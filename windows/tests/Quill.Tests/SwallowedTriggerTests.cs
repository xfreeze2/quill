using Quill;
using Xunit;
using static Quill.SwallowedTrigger.Verdict;

namespace Quill.Tests;

/// <summary>
/// The trigger keys the OS itself reacts to (Right Win opens the Start menu on
/// release, Right Alt arms the menu bar) must have their events swallowed, not
/// just observed — and deliberate chords must still reach the OS via replay.
/// </summary>
public class SwallowedTriggerTests
{
    static SwallowedTrigger Single() => new() { SingleTap = true };
    static SwallowedTrigger Double() => new() { SingleTap = false };

    [Fact]
    public void ABareTapFiresAndTheOsNeverSeesTheKey()
    {
        var t = Single();
        Assert.Equal(Swallow, t.TriggerDown(0));
        Assert.Equal(SwallowAndFire, t.TriggerUp(0.10));
    }

    [Fact]
    public void AutoRepeatDoesNotRestartTheHoldClock()
    {
        // Held modifiers auto-repeat their down events. If a repeat reset the
        // press time, releasing after a long hold would read as a quick tap.
        var t = Single();
        Assert.Equal(Swallow, t.TriggerDown(0));
        Assert.Equal(Swallow, t.TriggerDown(0.5));
        Assert.Equal(Swallow, t.TriggerDown(2.9));
        Assert.Equal(Swallow, t.TriggerUp(3.0));
    }

    [Fact]
    public void ALongHoldIsNotATapAndStaysInvisible()
    {
        var t = Single();
        Assert.Equal(Swallow, t.TriggerDown(0));
        // The OS never saw the down, so it must not see an orphan up either.
        Assert.Equal(Swallow, t.TriggerUp(0.9));
    }

    [Fact]
    public void AChordReplaysTheTriggerThenForwardsTheRest()
    {
        var t = Single();
        Assert.Equal(Swallow, t.TriggerDown(0));
        Assert.Equal(SwallowAndReplay, t.OtherKeyDown()); // Win+L: inject Win, then L
        Assert.Equal(Forward, t.OtherKeyDown());          // Win now really down; pass keys through
        Assert.Equal(Forward, t.TriggerUp(0.2));          // the OS needs the release it believes in
    }

    [Fact]
    public void AfterAChordTheNextTapStartsClean()
    {
        var t = Single();
        t.TriggerDown(0);
        t.OtherKeyDown();
        t.TriggerUp(0.2);
        Assert.Equal(Swallow, t.TriggerDown(1.0));
        Assert.Equal(SwallowAndFire, t.TriggerUp(1.1));
    }

    [Fact]
    public void AMouseClickWhileHeldSpendsTheTap()
    {
        var t = Single();
        t.TriggerDown(0);
        t.MouseChord();
        Assert.Equal(Swallow, t.TriggerUp(0.1));
    }

    [Fact]
    public void AChordIsStillHonouredAfterAMouseClick()
    {
        var t = Single();
        t.TriggerDown(0);
        t.MouseChord();
        Assert.Equal(SwallowAndReplay, t.OtherKeyDown());
    }

    [Fact]
    public void AMouseClickWithNothingHeldChangesNothing()
    {
        var t = Single();
        t.MouseChord();
        Assert.Equal(Swallow, t.TriggerDown(0));
        Assert.Equal(SwallowAndFire, t.TriggerUp(0.1));
    }

    [Fact]
    public void AnUpWithoutADownIsForwarded()
    {
        // The key was already held when the hook went in (or its release landed
        // on the secure desktop): let the OS keep its own story straight.
        var t = Single();
        Assert.Equal(Forward, t.TriggerUp(1.0));
    }

    [Fact]
    public void DoubleTapFiresOnTheSecondDownAndSwallowsEverything()
    {
        var t = Double();
        Assert.Equal(Swallow, t.TriggerDown(0));
        Assert.Equal(Swallow, t.TriggerUp(0.1));
        Assert.Equal(SwallowAndFire, t.TriggerDown(0.3));
        Assert.Equal(Swallow, t.TriggerUp(0.4)); // the firing press's release is not another tap
    }

    [Fact]
    public void TwoSlowTapsDoNotFire()
    {
        var t = Double();
        t.TriggerDown(0);
        t.TriggerUp(0.1);
        Assert.Equal(Swallow, t.TriggerDown(0.9));
        Assert.Equal(Swallow, t.TriggerUp(1.0));
    }

    [Fact]
    public void AKeyBetweenTapsBreaksThePair()
    {
        var t = Double();
        t.TriggerDown(0);
        t.TriggerUp(0.1);
        Assert.Equal(Forward, t.OtherKeyDown()); // trigger not held: none of our business
        Assert.Equal(Swallow, t.TriggerDown(0.3));
        Assert.Equal(Swallow, t.TriggerUp(0.4));
    }

    [Fact]
    public void AChordOnTheFirstPressBreaksTheDoublePair()
    {
        var t = Double();
        t.TriggerDown(0);
        Assert.Equal(SwallowAndReplay, t.OtherKeyDown());
        Assert.Equal(Forward, t.TriggerUp(0.1));
        Assert.Equal(Swallow, t.TriggerDown(0.3)); // not a second tap
    }

    [Fact]
    public void ALongFirstPressDoesNotCountAsTheFirstTap()
    {
        var t = Double();
        t.TriggerDown(0);
        Assert.Equal(Swallow, t.TriggerUp(0.8)); // a hold, not a tap
        Assert.Equal(Swallow, t.TriggerDown(1.0));
        Assert.Equal(Swallow, t.TriggerUp(1.1)); // first tap of a fresh pair
        Assert.Equal(SwallowAndFire, t.TriggerDown(1.3));
    }

    [Fact]
    public void ResetForgetsAHeldKey()
    {
        var t = Single();
        t.TriggerDown(0);
        t.Reset();
        Assert.False(t.IsHeld);
        Assert.Equal(Forward, t.TriggerUp(0.1)); // stale release passes through
    }
}
