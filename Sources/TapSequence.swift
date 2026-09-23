import Foundation

/// Tells a lone tap of the trigger from the second tap of a double tap.
///
/// The first tap always acts at once — dictation must never wait to find out
/// whether a second tap is coming, because that wait lands on every single
/// dictation. So a double tap is recognised only after the fact, on the second
/// release, and the caller undoes whatever the first tap began.
///
/// The input-activity counter is compared across the gap, so ⌃-tap, a
/// keystroke, a click, then ⌃-tap is two single taps rather than a double.
struct TapSequence {

    enum Kind: Equatable { case single, double }

    /// Longest pause between letting go of the first tap and pressing the second.
    var maxGap: TimeInterval = 0.35

    private var lastTapEndedAt: TimeInterval = 0
    private var activityAtLastTap: UInt64 = 0

    /// A qualifying tap has just been released.
    mutating func tap(pressedAt: TimeInterval, releasedAt: TimeInterval,
                      activityAtPress: UInt64, activityAtRelease: UInt64) -> Kind {
        let gap = pressedAt - lastTapEndedAt
        let followsQuickly = lastTapEndedAt > 0 && gap >= 0 && gap <= maxGap
        let nothingInBetween = activityAtPress == activityAtLastTap
        if followsQuickly && nothingInBetween {
            lastTapEndedAt = 0
            return .double
        }
        lastTapEndedAt = releasedAt
        activityAtLastTap = activityAtRelease
        return .single
    }

    /// Something that was not a clean tap happened; the next tap starts afresh.
    mutating func reset() {
        lastTapEndedAt = 0
    }
}
