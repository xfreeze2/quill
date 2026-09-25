// Compile with LiveText.swift only — not part of the app bundle.
//   swiftc -o /tmp/quill-live-test Sources/LiveText.swift tests/LiveTextTest.swift
import Foundation

@main
enum LiveTextTest {
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

        func expectEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got == want {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)\n     got:  \(got)\n     want: \(want)")
                failed += 1
            }
        }

        // MARK: Segments

        func interim(_ t: inout LiveTranscript, _ text: String, _ g: Int = 0) -> LiveTranscript.Update? {
            t.apply(generation: g, text: text, kind: .interim)
        }
        func close(_ t: inout LiveTranscript, _ text: String, _ g: Int = 0) -> LiveTranscript.Update? {
            t.apply(generation: g, text: text, kind: .chunkFinal)
        }
        func pause(_ t: inout LiveTranscript, _ text: String, _ g: Int = 0) -> LiveTranscript.Update? {
            t.apply(generation: g, text: text, kind: .utteranceFinal)
        }

        do {
            // The exact sequence the live service sent for two Spanish sentences
            // spoken without a pause, then a pause.
            var t = LiveTranscript()
            _ = close(&t, "Buenos días a todos.")
            _ = interim(&t, "Hoy va")
            _ = interim(&t, "Hoy vamos a hablar del lanzamiento del cohete")
            _ = interim(&t, "Hoy vamos a hablar del lanzamiento del cohete y de lo que aprendimos en la última prueba. El motor funcionó perfectamente durante tres")
            let second = close(&t, "Hoy vamos a hablar del lanzamiento del cohete y de lo que aprendimos en la última prueba. El motor funcionó perfectamente durante tres minutos.")
            let repeatAtPause = pause(&t, "Buenos días a todos. Hoy vamos a hablar del lanzamiento del cohete y de lo que aprendimos en la última prueba. El motor funcionó perfectamente durante tres minutos.")
            expectEqual("two sentences stay two sentences", t.segments.count, 2)
            expectEqual("…the first is untouched", t.segments[0].original, "Buenos días a todos.")
            expectEqual("…the second closes when its own final arrives", second?.becameFinal, true)
            expect("…the repeat at the pause changes nothing", repeatAtPause == nil)
            expect("…and both are final", t.segments.allSatisfy(\.isFinal))

            _ = interim(&t, "Okay, that sounds.")
            _ = close(&t, "Okay, that sounds good. Let's meet again next week.")
            _ = pause(&t, "Okay, that sounds good. Let's meet again next week.")
            expectEqual("the next utterance is a third sentence", t.segments.map(\.original).last, "Okay, that sounds good. Let's meet again next week.")
            expectEqual("…and nothing is duplicated", t.segments.count, 3)
        }

        do {
            var t = LiveTranscript()
            _ = interim(&t, "Hola")
            _ = interim(&t, "Hola a todos")
            expectEqual("interim text grows one sentence", t.segments.map(\.original), ["Hola a todos"])
            expect("…which is still open", t.hasOpenSegment(generation: 0))
            _ = interim(&t, "Otra conexión", 1)
            expectEqual("a second socket keeps its own sentence", t.segments.count, 2)
            expectEqual("…without touching the first", t.segments[0].original, "Hola a todos")
        }

        do {
            var t = LiveTranscript()
            let empty = interim(&t, "   ")
            expect("an empty interim never creates a sentence", empty == nil && t.segments.isEmpty)
            _ = interim(&t, "Bonjour")
            _ = interim(&t, "")
            _ = close(&t, "")
            expectEqual("an empty close never wipes words", t.segments[0].original, "Bonjour")
            expect("…but does close the sentence", t.segments[0].isFinal)
        }

        do {
            var t = LiveTranscript()
            _ = close(&t, "Erste Hälfte.")
            _ = interim(&t, "Zweite Hälf")
            let update = pause(&t, "Erste Hälfte. Zweite Hälfte, ganz.")
            expectEqual("a pause closes a sentence whose own close never came", update?.becameFinal, true)
            expectEqual("…with the words the pause adds", t.segments[1].original, "Zweite Hälfte, ganz.")
        }

        do {
            var t = LiveTranscript()
            let only = pause(&t, "Nur am Ende gesendet.")
            expectEqual("a pause with nothing closed before it is a sentence", only?.becameFinal, true)
            expectEqual("…kept once", t.segments.count, 1)
        }

        do {
            var t = LiveTranscript()
            _ = interim(&t, "Guten Morgen wie geht")
            let closed = t.finaliseOpen(generation: 0)
            expectEqual("a dead socket's open sentence is closed, not lost", closed, [0])
            expect("…and is final", t.segments[0].isFinal && !t.hasOpenSegment(generation: 0))
        }

        do {
            // Japanese heard by a socket that locked onto Spanish, then heard again.
            var t = LiveTranscript()
            _ = t.apply(generation: 0, text: "Buenos días a todos.", kind: .chunkFinal, audioStart: 0.02)
            _ = t.apply(generation: 0, text: "Hasta no caiga, todos santini.", kind: .chunkFinal, audioStart: 10.8)
            _ = t.apply(generation: 0, text: "Okay, that", kind: .interim, audioStart: 18.3)
            expectEqual("where each sentence's audio began is kept", t.segments.map(\.audioStart), [0.02, 10.8, 18.3])

            let marked = t.markReplacing(from: 1)
            expectEqual("the misheard sentence and what followed it are marked", marked, [1, 2])
            expect("…and still shown until the new words come", t.visibleSegments.count == 3)
            expect("…but never sent for translation meanwhile", t.request(for: 1, now: 1) == nil)
            expect("…and the old socket's open sentence is let go", !t.hasOpenSegment(generation: 0))

            t.commitReplacement()
            _ = t.apply(generation: 1, text: "明日の会議は午後三時に始まります。", kind: .chunkFinal, audioStart: 0.4)
            expectEqual("once the new socket answers, only its words remain",
                        t.visibleSegments.map(\.original), ["Buenos días a todos.", "明日の会議は午後三時に始まります。"])
            expect("the copied session leaves the misheard words out", !t.plainText().contains("santini"))
            let next = t.request(for: 3, now: 5)
            expectEqual("…and so does the context sent with the next request", next?.context, ["Buenos días a todos."])
        }

        do {
            var t = LiveTranscript()
            _ = t.apply(generation: 0, text: "Una frase.", kind: .chunkFinal, audioStart: 1)
            _ = t.markReplacing(from: 0)
            t.cancelReplacement()
            expect("if hearing it again fails, the original stays", t.visibleSegments.count == 1 && !t.isReplacing)
        }

        // MARK: When to translate

        do {
            var t = LiveTranscript()
            _ = interim(&t, "Hola")
            expect("a short draft is not sent", t.request(for: 0, now: 10) == nil)

            _ = interim(&t, "Hola a todos y bienvenidos")
            let draft = t.request(for: 0, now: 10)
            expectEqual("a long enough draft is sent", draft?.isFinal, false)
            expect("only one draft in flight", t.request(for: 0, now: 20) == nil)

            t.receive(id: 0, revision: draft!.revision, text: "Hello everyone and welcome", language: "es", done: true)
            _ = interim(&t, "Hola a todos y bienvenidos al programa")
            expect("drafts are spaced out", t.request(for: 0, now: 10.5) == nil)
            expect("…then the next one goes", t.request(for: 0, now: 11.3) != nil)

            _ = close(&t, "Hola a todos y bienvenidos al programa de hoy.")
            let final = t.request(for: 0, now: 11.4)
            expectEqual("the final is sent at once, whatever is in flight", final?.isFinal, true)

            let staleApplied = t.receive(id: 0, revision: final!.revision - 1, text: "stale draft", language: nil, done: true)
            expect("a superseded draft cannot overwrite", !staleApplied && t.segments[0].translation == "Hello everyone and welcome")

            t.receive(id: 0, revision: final!.revision, text: "Hello everyone and welcome to", language: nil, done: false)
            expectEqual("streamed text shows as it arrives", t.segments[0].translation, "Hello everyone and welcome to")
            expect("…but is not final yet", !t.segments[0].translationIsFinal)
            t.receive(id: 0, revision: final!.revision, text: "Hello everyone and welcome to today's show.", language: nil, done: true)
            expect("the finished reply is final", t.segments[0].translationIsFinal)
            expect("and it is never sent twice", t.request(for: 0, now: 30) == nil)
        }

        do {
            var t = LiveTranscript()
            _ = interim(&t, "Esto es una prueba larga")
            let draft = t.request(for: 0, now: 1)!
            t.receive(id: 0, revision: draft.revision, text: "This is a long test", language: "es", done: true)
            _ = close(&t, "Esto es una prueba larga")
            expect("a draft for exactly the final words is reused, not re-sent", t.request(for: 0, now: 5) == nil)
            expect("…and counts as final", t.segments[0].translationIsFinal)
        }

        do {
            var t = LiveTranscript()
            _ = close(&t, "First sentence here.")
            _ = close(&t, "Second sentence here.")
            _ = close(&t, "Third sentence here.")
            _ = close(&t, "Fourth one.")
            let request = t.request(for: 3, now: 1)
            expectEqual("the two previous sentences travel as context",
                        request?.context, ["Second sentence here.", "Third sentence here."])
        }

        do {
            var t = LiveTranscript()
            _ = close(&t, "Already in English, nothing to do.")
            t.markSameLanguage(0, language: "en")
            expect("same-language speech is never sent", t.request(for: 0, now: 1) == nil)
            expectEqual("…and shows as itself", t.segments[0].translation, "Already in English, nothing to do.")
        }

        do {
            var t = LiveTranscript()
            _ = close(&t, "Una frase terminada.")
            let first = t.request(for: 0, now: 1)!
            t.requestFailed(id: 0, revision: first.revision)
            expect("a failed final is retried", t.request(for: 0, now: 2) != nil)
        }

        do {
            var t = LiveTranscript()
            _ = close(&t, "Primera frase completa.")
            _ = close(&t, "Segunda frase completa.")
            _ = close(&t, "Tercera frase completa.")
            for id in 0..<3 {
                let r = t.request(for: id, now: 1)!
                t.receive(id: id, revision: r.revision, text: "English \(id)", language: "es", done: true)
            }
            let redo = t.invalidateTranslations(last: 2)
            expectEqual("a new target re-translates the last sentences", redo, [1, 2])
            expect("…which are sent again", t.request(for: 2, now: 2) != nil)
            expect("…and older ones are left alone", t.request(for: 0, now: 2) == nil)
            let staleApplied = t.receive(id: 1, revision: 1, text: "old language", language: nil, done: true)
            expect("a reply in the old language is dropped", !staleApplied)
        }

        // MARK: Reply parsing

        func parse(_ raw: String, complete: Bool = true) -> [String] {
            let r = TranslationReply.parse(raw, complete: complete)
            return [r.language ?? "-", r.text]
        }

        expectEqual("code line then translation", parse("es\nHello there"), ["es", "Hello there"])
        expectEqual("region suffix is dropped", parse("pt-BR\nGood morning"), ["pt", "Good morning"])
        expectEqual("bracketed code", parse("[fr]\nThank you"), ["fr", "Thank you"])
        expectEqual("a reply without a code line is all translation", parse("Hello there, friend"), ["-", "Hello there, friend"])
        expectEqual("a finished one-word reply is not mistaken for a code", parse("No"), ["-", "No"])
        expectEqual("while streaming, a possible code is held back", parse("es", complete: false), ["-", ""])
        expectEqual("while streaming, text after the code shows", parse("de\nGood mor", complete: false), ["de", "Good mor"])
        expectEqual("quotes are stripped", parse("ja\n\"See you tomorrow\""), ["ja", "See you tomorrow"])
        expectEqual("a leading blank line is tolerated", parse("\nzh\nHello"), ["zh", "Hello"])

        // MARK: Stream lines

        if case .content(let text) = StreamLine.parse(#"data: {"choices":[{"delta":{"content":"Hola"}}]}"#) {
            expectEqual("stream content", text, "Hola")
        } else {
            expect("stream content", false)
        }
        if case .done = StreamLine.parse("data: [DONE]") { expect("stream done", true) } else { expect("stream done", false) }
        if case .ignore = StreamLine.parse(": keep-alive") { expect("comments ignored", true) } else { expect("comments ignored", false) }
        if case .ignore = StreamLine.parse(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) {
            expect("role-only delta ignored", true)
        } else {
            expect("role-only delta ignored", false)
        }

        print(failed == 0 ? "\nall passed" : "\n\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
