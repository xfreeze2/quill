import Foundation

/// The little assertion kit the newer tests share. Prints `ok` / `FAIL` per check
/// and exits non-zero from `finish()` if any failed.
final class Check {
    private(set) var failed = 0

    func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want {
            print("ok   \(name)")
        } else {
            print("FAIL \(name)\n     got:  \(got)\n     want: \(want)")
            failed += 1
        }
    }

    func isTrue(_ name: String, _ value: Bool) {
        equal(name, value, true)
    }

    func finish() -> Never {
        if failed > 0 {
            print("\n\(failed) failed")
            exit(1)
        }
        print("\nall passed")
        exit(0)
    }
}

/// A scratch directory that is removed when the test ends.
func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-test-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
