// Compile with TapSequence.swift only — not part of the app bundle.
//   swiftc -o /tmp/quill-tap-test Sources/TapSequence.swift tests/TapSequenceTest.swift
import Foundation

@main
enum TapSequenceTest {
    static func main() {
        var failed = 0

        func expect(_ name: String, _ got: [TapSequence.Kind], _ want: [TapSequence.Kind]) {
            if got == want {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)\n     got:  \(got)\n     want: \(want)")
                failed += 1
            }
        }

        /// Each tap is (pressed, released, activity counter at press, at release).
        func run(_ taps: [(Double, Double, UInt64, UInt64)]) -> [TapSequence.Kind] {
            var sequence = TapSequence()
            return taps.map { sequence.tap(pressedAt: $0.0, releasedAt: $0.1,
                                           activityAtPress: $0.2, activityAtRelease: $0.3) }
        }

        expect("one tap is a single tap",
               run([(10.00, 10.08, 5, 5)]),
               [.single])

        expect("two quick taps are a double",
               run([(10.00, 10.08, 5, 5), (10.20, 10.27, 5, 5)]),
               [.single, .double])

        expect("a slow second tap is another single",
               run([(10.00, 10.08, 5, 5), (10.60, 10.68, 5, 5)]),
               [.single, .single])

        expect("gap exactly at the limit still counts",
               run([(10.00, 10.10, 5, 5), (10.45, 10.52, 5, 5)]),
               [.single, .double])

        expect("a keystroke between the taps breaks the double",
               run([(10.00, 10.08, 5, 5), (10.20, 10.27, 6, 6)]),
               [.single, .single])

        expect("a third quick tap starts over rather than making another double",
               run([(10.00, 10.08, 5, 5), (10.20, 10.27, 5, 5), (10.40, 10.47, 5, 5)]),
               [.single, .double, .single])

        expect("two doubles in a row",
               run([(10.00, 10.08, 5, 5), (10.20, 10.27, 5, 5),
                    (12.00, 12.08, 5, 5), (12.20, 12.27, 5, 5)]),
               [.single, .double, .single, .double])

        do {
            var sequence = TapSequence()
            _ = sequence.tap(pressedAt: 10.00, releasedAt: 10.08, activityAtPress: 5, activityAtRelease: 5)
            sequence.reset()
            let second = sequence.tap(pressedAt: 10.20, releasedAt: 10.27, activityAtPress: 5, activityAtRelease: 5)
            expect("a chord in between (reset) breaks the double", [second], [.single])
        }

        print(failed == 0 ? "\nall passed" : "\n\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
