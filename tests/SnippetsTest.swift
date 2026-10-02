// Voice shortcuts: saying a phrase types the longer text.
import Foundation

@main
enum SnippetsTest {
    static func main() {
        let check = Check()
        let link = Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/freeze")
        let email = Snippet(trigger: "my email", expansion: "freeze@example.com")
        let emailAddress = Snippet(trigger: "my email address", expansion: "freeze@example.com (work)")
        let signoff = Snippet(trigger: "sign off", expansion: "Best,\nFreeze")

        func expand(_ text: String, _ snippets: [Snippet]) -> String { Snippets.expand(text, using: snippets) }

        check.equal("nothing to expand", expand("Hello there.", [link]), "Hello there.")
        check.equal("no snippets at all", expand("Hello there.", []), "Hello there.")

        // The trigger is everything said: no stray punctuation after a link.
        check.equal("the whole utterance", expand("My calendar link.", [link]), "https://cal.example.com/freeze")
        check.equal("any capitalisation", expand("my CALENDAR link", [link]), "https://cal.example.com/freeze")

        // In the middle of a sentence the words around it stay.
        check.equal("inside a sentence", expand("Please book a time on my calendar link.", [link]),
                    "Please book a time on https://cal.example.com/freeze.")
        check.equal("punctuation inside the trigger's place", expand("Here is, my calendar link, thanks.", [link]),
                    "Here is, https://cal.example.com/freeze, thanks.")

        // The longer trigger wins.
        check.equal("longest trigger", expand("Send it to my email address.", [email, emailAddress]),
                    "Send it to freeze@example.com (work).")
        check.equal("shorter trigger alone", expand("Send it to my email.", [email, emailAddress]),
                    "Send it to freeze@example.com.")

        // Whole words only.
        check.equal("part of a word is not a trigger", expand("My emails are many.", [email]), "My emails are many.")

        // Several in one go.
        check.equal("two triggers", expand("Use my email and my calendar link.", [email, link]),
                    "Use freeze@example.com and https://cal.example.com/freeze.")

        // Multi-line expansions come through intact.
        check.equal("multi-line", expand("Sign off.", [signoff]), "Best,\nFreeze")
        check.equal("multi-line inside text", expand("Thanks so much, sign off", [signoff]),
                    "Thanks so much, Best,\nFreeze")

        // Apostrophes, either kind.
        let thanks = Snippet(trigger: "that's all", expansion: "Thanks!")
        check.equal("curly apostrophe", expand("That’s all.", [thanks]), "Thanks!")

        // Unusable snippets do nothing.
        check.equal("empty trigger ignored", expand("Hello there.", [Snippet(trigger: "  ", expansion: "x")]), "Hello there.")
        check.equal("empty expansion ignored", expand("Hello there.", [Snippet(trigger: "hello", expansion: "")]), "Hello there.")

        // Stored and read back.
        let suite = UserDefaults(suiteName: "quill-snippets-test-\(UUID().uuidString)")!
        check.isTrue("nothing stored yet", Snippets.load(suite).isEmpty)
        Snippets.save([link, Snippet(trigger: " ", expansion: "dropped")], suite)
        check.equal("round trip keeps the usable ones", Snippets.load(suite).map(\.trigger), ["my calendar link"])
        Snippets.save([], suite)
        check.isTrue("clearing removes them", suite.data(forKey: Snippets.key) == nil)

        check.finish()
    }
}
