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
