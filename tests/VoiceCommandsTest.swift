// Compile with Commands.swift only — not part of the app bundle.
//   swiftc -o /tmp/quill-cmd-test Sources/Commands.swift tests/VoiceCommandsTest.swift
import Foundation

enum Log {
    static func write(_ message: String) {}
}

@main
enum VoiceCommandsTest {
    static func main() {
        var failed = 0

        func expect(_ name: String, _ cond: @autoclosure () -> Bool) {
            if cond() {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)")
                failed += 1
            }
        }

        // Mirrors main.swift: fire on the first matching partial, then never again.
        func fired(on partials: [String]) -> Int {
            var didRun = false
            var count = 0
            for text in partials where !text.isEmpty {
                if !didRun, VoiceCommands.containsOpenGrok(text) {
                    didRun = true
                    count += 1
                }
            }
            return count
        }

        func expectEqual(_ name: String, _ got: String, _ want: String) {
            if got == want {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)\n     got:  \(got.debugDescription)\n     want: \(want.debugDescription)")
                failed += 1
            }
        }

        // Command only when it is the first thing said.
        expect("start: open Grok", VoiceCommands.containsOpenGrok("open Grok, write a haiku"))
        expect("start: Open Grok Build", VoiceCommands.containsOpenGrok("Open Grok Build then write"))
        expect("start: please open grok", VoiceCommands.containsOpenGrok("please open grok"))
        expect("start: launch grok", VoiceCommands.containsOpenGrok("launch grok"))
        expect("start: start up the grok", VoiceCommands.containsOpenGrok("start up the grok"))
        expect("start: open croc", VoiceCommands.containsOpenGrok("open croc"))
        expect("start: open grock", VoiceCommands.containsOpenGrok("open grock"))
        expect("start: leading punct", VoiceCommands.containsOpenGrok("  open Grok, hello"))

        // Mid-sentence must never fire — that is the bug this release fixes.
        expect("mid: should not fire", !VoiceCommands.containsOpenGrok("I think we should open Grok now"))
        expect("mid: then open grok", !VoiceCommands.containsOpenGrok("write this then open grok"))
        expect("mid: please later", !VoiceCommands.containsOpenGrok("and then please open grok"))
        expect("mid: open grok build later",
               !VoiceCommands.containsOpenGrok("can you open Grok Build after this"))
        expect("unrelated open", !VoiceCommands.containsOpenGrok("open the document"))
        // Real phrases from the dictation that hit the old bug.
        expect("mid: spoken report",
               !VoiceCommands.containsOpenGrok(
                "It opens croc. But the problem is If somebody's already in the middle of talking"))
        expect("mid: whenever somebody says",
               !VoiceCommands.containsOpenGrok("In the middle whenever somebody says open Grok"))
        expect("start-with-Grok is not a command",
               !VoiceCommands.containsOpenGrok("Grok, then it shouldn't open"))

        // How the app actually sees speech: growing partials, fire at most once.
        expect("stream mid never fires",
               fired(on: ["I think",
                          "I think we should",
                          "I think we should open",
                          "I think we should open Grok",
                          "I think we should open Grok and try that"]) == 0)
        expect("stream start fires once",
               fired(on: ["open",
                          "open Grok",
                          "open Grok, write me a haiku"]) == 1)
        expect("stream start after please",
               fired(on: ["please", "please open", "please open grok"]) == 1)

        // Strip only the leading command; leave mid-sentence words alone.
        expectEqual("strip start",
                    VoiceCommands.strip("open Grok, write a haiku"),
                    "write a haiku")
        expectEqual("strip start build",
                    VoiceCommands.strip("open Grok Build, then write me a haiku about rockets"),
                    "then write me a haiku about rockets")
        expectEqual("strip mid unchanged",
                    VoiceCommands.strip("I think we should open Grok now"),
                    "I think we should open Grok now")
        expectEqual("strip later unchanged",
                    VoiceCommands.strip("write this then open grok"),
                    "write this then open grok")

        if failed > 0 {
            print("\n\(failed) failed")
            exit(1)
        }
        print("\nall passed")
    }
}
