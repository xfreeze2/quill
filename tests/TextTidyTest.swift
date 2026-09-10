// Foundation-only test for the mid-sentence capitalisation logic.
//   swiftc -o /tmp/quill-texttidy-test Sources/TextTidy.swift tests/TextTidyTest.swift
import Foundation

@main
enum TextTidyTest {
    static func main() {
        var failed = 0

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)")
                failed += 1
            }
        }

        func expectEqual(_ name: String, _ got: String, _ want: String) {
            if got == want {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)\n     got:  \(got.debugDescription)\n     want: \(want.debugDescription)")
                failed += 1
            }
        }

        func end(_ s: String) -> Int { s.utf16.count }

        // MARK: isContinuation — where does the text land?

        expect("continuation after a word", TextTidy.isContinuation(before: "so I was thinking ", at: end("so I was thinking ")))
        expect("continuation after a comma", TextTidy.isContinuation(before: "first, ", at: end("first, ")))
        expect("continuation after a colon", TextTidy.isContinuation(before: "note: ", at: end("note: ")))
        expect("not continuation at empty field", !TextTidy.isContinuation(before: "", at: 0))
        expect("not continuation at offset 0", !TextTidy.isContinuation(before: "hello", at: 0))
        expect("not continuation after a full stop", !TextTidy.isContinuation(before: "Done. ", at: end("Done. ")))
        expect("not continuation after question mark", !TextTidy.isContinuation(before: "Really? ", at: end("Really? ")))
        expect("not continuation after exclamation", !TextTidy.isContinuation(before: "Wow! ", at: end("Wow! ")))
        expect("not continuation after newline", !TextTidy.isContinuation(before: "line one\n", at: end("line one\n")))
        expect("not continuation after quoted sentence end",
               !TextTidy.isContinuation(before: "He said \"hello.\" ", at: end("He said \"hello.\" ")))
        expect("not continuation after parenthesised sentence end",
               !TextTidy.isContinuation(before: "(done.) ", at: end("(done.) ")))
        expect("continuation mid-text at caret", TextTidy.isContinuation(before: "abcdef", at: 3))
        expect("continuation after only-whitespace is false", !TextTidy.isContinuation(before: "   ", at: 3))

        // MARK: decapitalizeLead — lower the opener, keep the exceptions

        expectEqual("lower a plain opener", TextTidy.decapitalizeLead("So we could ship"), "so we could ship")
        expectEqual("lower The", TextTidy.decapitalizeLead("The cat"), "the cat")
        expectEqual("lower single A", TextTidy.decapitalizeLead("A thing"), "a thing")
        expectEqual("keep pronoun I", TextTidy.decapitalizeLead("I think"), "I think")
        expectEqual("keep I'm", TextTidy.decapitalizeLead("I'm sure"), "I'm sure")
        expectEqual("keep I'll", TextTidy.decapitalizeLead("I'll go"), "I'll go")
        expectEqual("keep acronym NASA", TextTidy.decapitalizeLead("NASA rocks"), "NASA rocks")
        expectEqual("keep acronym API", TextTidy.decapitalizeLead("API keys"), "API keys")
        expectEqual("already lowercase unchanged", TextTidy.decapitalizeLead("hello there"), "hello there")
        expectEqual("non-letter lead unchanged", TextTidy.decapitalizeLead("123 go"), "123 go")
        expectEqual("empty unchanged", TextTidy.decapitalizeLead(""), "")

        // MARK: applyContinuationCase — the combined behaviour the inserter uses

        expectEqual("append mid-sentence lowercases",
                    TextTidy.applyContinuationCase("So we could", existing: "I was thinking ", at: end("I was thinking ")),
                    "so we could")
        expectEqual("append after full stop keeps capital",
                    TextTidy.applyContinuationCase("Great idea", existing: "Done. ", at: end("Done. ")),
                    "Great idea")
        expectEqual("insert into empty field keeps capital",
                    TextTidy.applyContinuationCase("Hello world", existing: "", at: 0),
                    "Hello world")
        expectEqual("append mid-sentence keeps I capital",
                    TextTidy.applyContinuationCase("I think so", existing: "you know ", at: end("you know ")),
                    "I think so")

        if failed > 0 {
            print("\n\(failed) failed")
            exit(1)
        }
        print("\nall passed")
    }
}
