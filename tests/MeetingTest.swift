// Meetings: who said what, the echo, the notes, the files.
import Foundation

@main
enum MeetingTest {
    static func word(_ text: String, _ start: Double, _ speaker: Int?) -> SpokenWord {
        SpokenWord(text: text, start: start, end: start + 0.3, speaker: speaker)
    }

    /// Words at 0.4 s apart from `start`, all by one voice.
    static func words(_ text: String, from start: Double, speaker: Int?) -> [SpokenWord] {
        text.split(separator: " ").enumerated().map { index, w in word(String(w), start + Double(index) * 0.4, speaker) }
    }

    static func main() {
        let check = Check()

        // ── One connection, two voices ───────────────────────────────────────────
        // The shape the live service really sends: chunks name nobody (or guess),
        // the message that closes the pause names the voices.
        let lane = LaneAssembler(voices: .several, base: 100, epoch: 0)
        let karen = "Okay, let's get started. The goal today is to decide the launch date."
        check.isTrue("interim text is not final", lane.apply(text: "Okay let's", words: [], kind: .interim).isEmpty)
        check.equal("it shows as live", lane.live?.text, "Okay let's")
        check.isTrue("a chunk is not final either",
                     lane.apply(text: karen, words: words(karen, from: 0.06, speaker: nil), kind: .chunkFinal).isEmpty)
        check.equal("the chunk is still live", lane.live?.text, karen)
        let closed = lane.apply(text: karen, words: words(karen, from: 0.06, speaker: 0), kind: .utteranceFinal)
        check.equal("the closing message makes one remark", closed.count, 1)
        check.equal("by the voice it named", closed.first?.speaker, "s0")
        check.equal("on the meeting's clock", closed.first.map { Int($0.start) }, 100)
        check.equal("with its own words", closed.first?.text, karen)
        check.isTrue("nothing is live afterwards", lane.live == nil)

        // Silence is empty chunks and empty drafts; they change nothing.
        check.isTrue("empty draft", lane.apply(text: "", words: [], kind: .interim).isEmpty)
        check.isTrue("empty chunk", lane.apply(text: "", words: [], kind: .chunkFinal).isEmpty)
        check.isTrue("empty draft does not make a live line", lane.live == nil)

        // Two people without a pause between them: one message, two remarks.
        let swap = words("Sounds good", from: 6.0, speaker: 1) + words("Great see you then", from: 7.0, speaker: 0)
        let split = lane.apply(text: swap.map(\.text).joined(separator: " "), words: swap, kind: .utteranceFinal)
        check.equal("a change of voice splits the message", split.map(\.speaker), ["s1", "s0"])
        check.equal("each keeps its own words", split.map(\.text), ["Sounds good", "Great see you then"])

        // A lone word the service attributes to someone else is wavering, not an interruption.
        let waver = words("I think Tuesday", from: 0, speaker: 1) + words("works", from: 2, speaker: 0)
            + words("but the design team needs time", from: 3, speaker: 1)
        let steady = LaneAssembler(voices: .several, base: 0, epoch: 0)
            .apply(text: waver.map(\.text).joined(separator: " "), words: waver, kind: .utteranceFinal)
        check.equal("one wavering word is absorbed", steady.count, 1)
        check.equal("into the voice around it", steady.first?.speaker, "s1")
        // …but a real reply of one word at the very end stays.
        let answer = words("Do you agree", from: 0, speaker: 0) + words("Yes", from: 2, speaker: 1)
        let kept = LaneAssembler(voices: .several, base: 0, epoch: 0)
            .apply(text: "Do you agree Yes", words: answer, kind: .utteranceFinal)
        check.equal("a one-word reply stays", kept.map(\.speaker), ["s0", "s1"])

        // Unlabelled words belong to whoever was speaking.
        let unlabelled = words("I think Tuesday works", from: 0, speaker: 1) + [word("days.", 2.0, nil)]
        let carried = LaneAssembler(voices: .several, base: 0, epoch: 0)
            .apply(text: "I think Tuesday works days.", words: unlabelled, kind: .utteranceFinal)
        check.equal("unlabelled words carry the voice on", carried.map(\.speaker), ["s1"])

        // The microphone is always you.
        let mic = LaneAssembler(voices: .one("you"), base: 0, epoch: 0)
        let mine = mic.apply(text: "Two more days sounds fine.", words: words("Two more days sounds fine.", from: 1, speaker: nil), kind: .utteranceFinal)
        check.equal("one known voice", mine.map(\.speaker), ["you"])

        // A connection that ends mid-thought keeps what it heard.
        let ending = LaneAssembler(voices: .several, base: 50, epoch: 2)
        _ = ending.apply(text: "We should also", words: words("We should also", from: 0, speaker: 1), kind: .chunkFinal)
        _ = ending.apply(text: "look at pricing", words: words("look at pricing", from: 2, speaker: 1), kind: .chunkFinal)
        let flushed = ending.flush()
        check.equal("flushing closes the chunks", flushed.map(\.text), ["We should also look at pricing"])
        check.equal("by the voice they carried", flushed.first?.speaker, "s1")
        check.equal("in its own epoch", flushed.first?.epoch, 2)
        check.isTrue("and flushing again finds nothing", ending.flush().isEmpty)

        // No word detail at all: the text still lands.
        let bare = LaneAssembler(voices: .several, base: 10, epoch: 0)
            .apply(text: "No timings were sent.", words: [], kind: .utteranceFinal)
        check.equal("text without words", bare.map(\.text), ["No timings were sent."])

        // ── The whole meeting ────────────────────────────────────────────────────
        let transcript = MeetingTranscript()
        transcript.add([Fragment(speaker: "s0", start: 0, end: 5, text: "Okay, let's get started.", epoch: 0),
                        Fragment(speaker: "s1", start: 6, end: 11, text: "I think Tuesday works.", epoch: 0)])
        transcript.add([Fragment(speaker: "you", start: 12, end: 15, text: "Thursday sounds reasonable to me.", epoch: 0)])
        check.equal("in order", transcript.utterances.map(\.speaker), ["s0", "s1", "you"])
        // A late arrival is slotted by time, not appended.
        transcript.add([Fragment(speaker: "s0", start: 5.5, end: 5.9, text: "Right.", epoch: 0)])
        check.equal("late arrival is placed by time", transcript.utterances.map(\.text).prefix(3).map { String($0.prefix(5)) },
                    ["Okay,", "Right", "I thi"])
        check.equal("ids never repeat", Set(transcript.utterances.map(\.id)).count, transcript.utterances.count)

        // The echo: your microphone hearing the call.
        let call = MeetingTranscript()
        call.add([Fragment(speaker: "s0", start: 20, end: 25, text: "Please send the updated schedule to everyone by tomorrow.", epoch: 0)])
        call.add([Fragment(speaker: "you", start: 20.4, end: 25.2, text: "Please send the updated schedule to everyone by tomorrow", epoch: 0)])
        check.equal("a mic echo of the call is dropped", call.utterances.count, 1)
        check.equal("the call's version is kept", call.utterances.first?.speaker, "s0")
        // And when the mic is heard first and the call a moment later.
        let late = MeetingTranscript()
        late.add([Fragment(speaker: "you", start: 30, end: 34, text: "One open question: do we need a beta", epoch: 0)])
        late.add([Fragment(speaker: "s0", start: 30.2, end: 34.5, text: "One open question, do we need a beta?", epoch: 0)])
        check.equal("the echo is removed when the call arrives second", late.utterances.map(\.speaker), ["s0"])
        // What you really say is not an echo.
        let own = MeetingTranscript()
        own.add([Fragment(speaker: "s0", start: 40, end: 44, text: "Daniel, can you send the schedule today?", epoch: 0)])
        own.add([Fragment(speaker: "you", start: 44.5, end: 47, text: "Yes I will send it this afternoon", epoch: 0)])
        check.equal("your own reply stays", own.utterances.count, 2)
        // Short words are never treated as echoes.
        let short = MeetingTranscript()
        short.add([Fragment(speaker: "s0", start: 50, end: 51, text: "Okay.", epoch: 0)])
        short.add([Fragment(speaker: "you", start: 50.5, end: 51.5, text: "Okay.", epoch: 0)])
        check.equal("two people can both say okay", short.utterances.count, 2)
        // Same words, far apart in time: two separate remarks.
        let apart = MeetingTranscript()
        apart.add([Fragment(speaker: "s0", start: 10, end: 14, text: "Let us circle back on this next week", epoch: 0)])
        apart.add([Fragment(speaker: "you", start: 300, end: 304, text: "Let us circle back on this next week", epoch: 0)])
        check.equal("repeated later is not an echo", apart.utterances.count, 2)

        // ── The meeting as a record ──────────────────────────────────────────────
        var meeting = Meeting(title: "Launch planning", createdAt: Date(timeIntervalSince1970: 1_790_000_000), capture: .call)
        meeting.utterances = [
            Utterance(id: 0, speaker: "s0", start: 0, end: 4, text: "Okay, let's get started."),
            Utterance(id: 1, speaker: "s0", start: 5, end: 9, text: "The goal is the launch date."),
            Utterance(id: 2, speaker: "s1", start: 10, end: 14, text: "Tuesday works for me."),
            Utterance(id: 3, speaker: "you", start: 15, end: 18, text: "Thursday, then."),
            Utterance(id: 4, speaker: "s1", start: 200, end: 204, text: "Back after a long gap."),
        ]
        meeting.endedAt = meeting.createdAt.addingTimeInterval(300)
        check.equal("default names", meeting.speakers.map { meeting.name(for: $0) }, ["Speaker 1", "Speaker 2", "You"])
        meeting.speakerNames["s1"] = "  Daniel "
        check.equal("a given name wins", meeting.name(for: "s1"), "Daniel")
        check.isTrue("it knows the name was given", meeting.hasCustomName("s1") && !meeting.hasCustomName("s0"))
        meeting.speakerNames["s1"] = "   "
        check.equal("a blank name falls back", meeting.name(for: "s1"), "Speaker 2")
        meeting.speakerNames["s1"] = "Daniel"

        let turns = meeting.turns()
        check.equal("remarks by one voice join", turns.count, 4)
        check.equal("a long gap starts a new turn", turns.map(\.speaker), ["s0", "s1", "you", "s1"])
        check.equal("joined text", turns[0].text, "Okay, let's get started. The goal is the launch date.")
        check.equal("the transcript as the summary reads it", meeting.transcriptLines()[1], "[0:10] Daniel: Tuesday works for me.")
        check.equal("duration from the clock", Int(meeting.duration), 300)
        check.equal("word count", meeting.wordCount, 4 + 6 + 4 + 2 + 5)
        check.equal("clock format", Meeting.clock(3725), "1:02:05")
        check.equal("short durations", Meeting.describe(duration: 20), "under a minute")
        check.equal("minutes", Meeting.describe(duration: 25 * 60), "25 min")
        check.equal("hours", Meeting.describe(duration: 65 * 60), "1 h 05 min")

        // A reconnect numbers the voices afresh; naming them alike puts them right.
        var rejoined = Meeting(title: "r")
        rejoined.utterances = [Utterance(id: 0, speaker: "s0", start: 0, end: 4, text: "Before."),
                               Utterance(id: 1, speaker: "s2", start: 5, end: 8, text: "After.")]
        check.equal("different voices are different turns", rejoined.turns().count, 2)
        rejoined.speakerNames = ["s0": "Karen", "s2": "Karen"]
        check.equal("one name is one person", rejoined.turns().map(\.text), ["Before. After."])
        let ids = LaneAssembler(voices: .several, base: 0, epoch: 1)
        ids.voiceName = { "s\($0 + 2)" }
        let renumbered = ids.apply(text: "Hello there.", words: words("Hello there.", from: 0, speaker: 0), kind: .utteranceFinal)
        check.equal("a lane can hand out its own ids", renumbered.map(\.speaker), ["s2"])

        // Markdown.
        meeting.userNotes = "Ask legal about the privacy notice."
        meeting.summary = MeetingSummary(overview: "Chose Thursday for launch.", keyPoints: ["Design needs two more days"],
                                         decisions: ["Launch on Thursday"],
                                         actionItems: [ActionItem(owner: "Daniel", task: "Send the schedule"),
                                                       ActionItem(owner: nil, task: "Check privacy notice", done: true)],
                                         openQuestions: ["Do we need a beta?"])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let markdown = MeetingMarkdown.render(meeting, dateStyle: formatter)
        check.isTrue("title", markdown.hasPrefix("# Launch planning\n"))
        check.isTrue("facts line", markdown.contains("5 min · Call on this Mac · Speaker 1, Daniel, You"))
        check.isTrue("overview", markdown.contains("Chose Thursday for launch."))
        check.isTrue("owner in bold", markdown.contains("- [ ] **Daniel** — Send the schedule"))
        check.isTrue("done item ticked, no owner", markdown.contains("- [x] Check privacy notice"))
        check.isTrue("my notes kept", markdown.contains("## My notes\n\nAsk legal"))
        check.isTrue("transcript with times", markdown.contains("**Daniel** (0:10)  \nTuesday works for me."))
        check.isTrue("transcript can be left out", !MeetingMarkdown.render(meeting, includeTranscript: false, dateStyle: formatter).contains("## Transcript"))

        // ── On disk ──────────────────────────────────────────────────────────────
        let dir = scratchDirectory("meetings")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        check.isTrue("saved", store.save(meeting))
        var other = Meeting(title: "Older", createdAt: meeting.createdAt.addingTimeInterval(-86_400))
        other.endedAt = other.createdAt
        store.save(other)
        let listed = store.all()
        check.equal("newest first", listed.map(\.title), ["Launch planning", "Older"])
        check.equal("it round-trips whole", listed.first, meeting)
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.folder(for: meeting.id).appendingPathComponent("meeting.json").path)[.posixPermissions] as? Int) ?? 0
        check.equal("private to the user", mode, 0o600)

        // A meeting file from some other version still opens.
        let sparse = store.folder(for: UUID())
        try? FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try? Data(#"{"title":"From elsewhere","createdAt":"2026-10-01T10:00:00Z","somethingNew":42}"#.utf8)
            .write(to: sparse.appendingPathComponent("meeting.json"))
        check.isTrue("unknown and missing fields are fine", store.all().contains { $0.title == "From elsewhere" })
        // A broken one is skipped, not fatal, and not deleted.
        let broken = store.folder(for: UUID())
        try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try? Data("{ nope".utf8).write(to: broken.appendingPathComponent("meeting.json"))
        check.equal("a broken file is skipped", store.all().count, 3)
        check.isTrue("and left where it is", FileManager.default.fileExists(atPath: broken.appendingPathComponent("meeting.json").path))

        // Quill quitting mid-meeting does not lose it.
        var open = Meeting(title: "Was recording", createdAt: Date(timeIntervalSince1970: 1_790_100_000))
        open.utterances = [Utterance(id: 0, speaker: "you", start: 0, end: 90, text: "Some words were said here.")]
        open.summaryState = .working
        store.save(open)
        let closedMeetings = store.closeInterrupted()
        check.isTrue("an unfinished meeting is closed", closedMeetings.contains { $0.id == open.id })
        let reopened = store.all().first { $0.id == open.id }
        check.equal("at the end of what was heard", reopened.map { Int($0.duration) }, 90)
        check.equal("a summary that never finished is not stuck", reopened?.summaryState, SummaryState.none)

        store.delete(meeting.id)
        check.isTrue("deleted", !store.all().contains { $0.id == meeting.id })

        // ── Summaries ────────────────────────────────────────────────────────────
        let reply = """
        Here are the notes:
        ```json
        {"title":"Launch date decision","overview":"The team settled the launch.","keyPoints":["Design needs two more days"],
         "decisions":"- Launch on Thursday\\n- Beta decided next week","actionItems":[{"owner":"Daniel","task":"Send the schedule by tomorrow"},
         {"owner":"Unassigned","task":"Check the privacy notice"},"Write up notes"],"openQuestions":[],
         "speakers":{"Speaker 2":"Daniel","Speaker 1":"Karen Lee","Speaker 3":"the guy from legal, probably","You":"Me"}}
        ```
        Hope that helps!
        """
        let parsed = SummaryParser.parse(reply)
        check.equal("title", parsed?.title, "Launch date decision")
        check.equal("a list given as one string is split", parsed?.summary.decisions, ["Launch on Thursday", "Beta decided next week"])
        check.equal("action owners", parsed?.summary.actionItems.map { $0.owner }, ["Daniel", nil, nil])
        check.equal("a bare string is a task", parsed?.summary.actionItems.last?.task, "Write up notes")
        check.isTrue("names that are not names are dropped", parsed?.speakers["Speaker 3"] == nil)
        check.equal("real names kept", parsed?.speakers["Speaker 1"], "Karen Lee")
        check.isTrue("no JSON at all", SummaryParser.parse("I'm sorry, I can't do that.") == nil)
        check.isTrue("empty JSON", SummaryParser.parse("{}") == nil)

        var named = Meeting(title: "x")
        named.utterances = [Utterance(id: 0, speaker: "s0", start: 0, end: 1, text: "a"),
                            Utterance(id: 1, speaker: "s1", start: 2, end: 3, text: "b"),
                            Utterance(id: 2, speaker: "you", start: 4, end: 5, text: "c")]
        named.speakerNames["s1"] = "Maria"
        let suggestions = SummaryParser.suggestions(["Speaker 1": "Karen Lee", "Speaker 2": "Daniel", "You": "Freeze"], for: named)
        check.equal("only voices still on automatic names get suggestions", suggestions, ["s0": "Karen Lee"])
        let duplicate = SummaryParser.suggestions(["Speaker 1": "Maria"], for: named)
        check.isTrue("a name already used is not suggested again", duplicate.isEmpty)

        let merged = SummaryParser.concatenate([
            ParsedSummary(title: "A", summary: MeetingSummary(overview: "One.", keyPoints: ["a"]), speakers: ["Speaker 1": "Karen"]),
            ParsedSummary(title: "B", summary: MeetingSummary(overview: "Two.", keyPoints: ["b"]), speakers: [:]),
        ])
        check.equal("parts joined", merged?.summary.keyPoints, ["a", "b"])
        check.equal("overviews joined", merged?.summary.overview, "One. Two.")

        let groups = SummaryPrompt.chunks(of: Array(repeating: String(repeating: "x", count: 99), count: 10), maxCharacters: 250)
        check.equal("long transcripts are split between remarks", groups.map(\.count), [2, 2, 2, 2, 2])
        check.equal("a short one is a single group", SummaryPrompt.chunks(of: ["a", "b"], maxCharacters: 250).count, 1)
        check.isTrue("my notes go in the prompt",
                     SummaryPrompt.user(title: "t", transcriptLines: ["[0:00] You: hi"], userNotes: "remember legal").contains("<my-notes>\nremember legal"))
        check.isTrue("no notes, no notes block",
                     !SummaryPrompt.user(title: "t", transcriptLines: ["[0:00] You: hi"], userNotes: "  ").contains("my-notes"))

        // ── Running a summary ────────────────────────────────────────────────────
        var talk = Meeting(title: "Weekly sync")
        talk.userNotes = "Remember the legal review."
        talk.utterances = (0..<6).map { index in
            Utterance(id: index, speaker: index % 2 == 0 ? "s0" : "s1", start: Double(index) * 10, end: Double(index) * 10 + 5,
                      text: "This is remark number \(index) about the launch plan.")
        }
        let good = #"{"title":"Sync","overview":"Talked launch.","keyPoints":["Launch"],"decisions":[],"actionItems":[],"openQuestions":[],"speakers":{}}"#

        func failure(_ r: Result<ParsedSummary, SummaryFailure>?) -> SummaryFailure? {
            if case .failure(let f)? = r { return f }
            return nil
        }
        func summaryOf(_ r: Result<ParsedSummary, SummaryFailure>?) -> ParsedSummary? {
            if case .success(let p)? = r { return p }
            return nil
        }

        func run(_ meeting: Meeting, maxCharacters: Int = 48_000, replies: @escaping (Int, String) -> Result<String, SummaryFailure>)
            -> (result: Result<ParsedSummary, SummaryFailure>?, prompts: [(system: String, user: String)]) {
            var prompts: [(system: String, user: String)] = []
            var result: Result<ParsedSummary, SummaryFailure>?
            let runner = SummaryRunner(maxCharacters: maxCharacters) { system, user, done in
                prompts.append((system, user))
                done(replies(prompts.count, user))
            }
            runner.run(meeting) { result = $0 }
            return (result, prompts)
        }

        let single = run(talk) { _, _ in .success(good) }
        check.equal("an ordinary meeting is one request", single.prompts.count, 1)
        check.isTrue("it is read", summaryOf(single.result)?.title == "Sync")
        check.isTrue("with your notes in it", single.prompts[0].user.contains("Remember the legal review."))

        var tinyMeeting = Meeting(title: "Tiny")
        tinyMeeting.utterances = [Utterance(id: 0, speaker: "you", start: 0, end: 1, text: "Hello there")]
        let tiny = run(tinyMeeting) { _, _ in .success(good) }
        check.isTrue("a few words are not summarised", failure(tiny.result) == .tooShort)
        check.equal("and nothing is sent", tiny.prompts.count, 0)

        let retried = run(talk) { count, _ in .success(count == 1 ? "Sorry, I can't." : good) }
        check.equal("an unreadable reply is asked for again", retried.prompts.count, 2)
        check.isTrue("firmly", retried.prompts[1].user.contains("ONLY the JSON object"))
        check.isTrue("and then read", summaryOf(retried.result) != nil)
        let hopeless = run(talk) { _, _ in .success("no json") }
        check.equal("twice is enough", hopeless.prompts.count, 2)
        check.isTrue("then it gives up", failure(hopeless.result) == .unreadable)

        let offline = run(talk) { _, _ in .failure(.network("No network connection")) }
        check.equal("a network failure is not retried", offline.prompts.count, 1)
        check.isTrue("and is reported as it was", failure(offline.result) == .network("No network connection"))

        let long = run(talk, maxCharacters: 120) { count, user in
            if user.contains("<part 1>") { return .success(#"{"title":"Whole","overview":"Joined.","keyPoints":["x"],"decisions":[],"actionItems":[],"openQuestions":[],"speakers":{}}"#) }
            return .success(good)
        }
        let groupsNeeded = SummaryPrompt.chunks(of: talk.transcriptLines(), maxCharacters: 120).count
        check.isTrue("a long meeting is split (\(groupsNeeded) parts)", groupsNeeded > 1)
        check.equal("a request each, and one to join them", long.prompts.count, groupsNeeded + 1)
        check.isTrue("the parts are told which they are", long.prompts[0].user.hasPrefix("This is part 1 of \(groupsNeeded)"))
        check.isTrue("your notes go to the joining", long.prompts.last?.user.contains("Remember the legal review.") == true)
        check.isTrue("the joined notes are used", summaryOf(long.result)?.title == "Whole")
        let joinFails = run(talk, maxCharacters: 120) { _, user in
            user.contains("<part 1>") ? .success("garbled") : .success(good)
        }
        check.isTrue("if the joining fails the parts are joined by hand", summaryOf(joinFails.result)?.summary.keyPoints.count == groupsNeeded)

        // ── Who spoke when ───────────────────────────────────────────────────────
        var convo = Meeting(title: "Map", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        convo.utterances = [
            Utterance(id: 0, speaker: "you", start: 0, end: 10, text: "one two three four five six seven eight nine ten"),
            Utterance(id: 1, speaker: "s0", start: 10.5, end: 20, text: "alpha beta gamma delta"),
            Utterance(id: 2, speaker: "you", start: 21, end: 30, text: "eleven twelve"),
            Utterance(id: 3, speaker: "s1", start: 50, end: 60, text: "late voice"),
            Utterance(id: 4, speaker: "s0", start: 60.5, end: 70, text: "more words here"),
        ]
        convo.speakerNames = ["s1": "Karen", "s0": "Karen"]
        convo.endedAt = convo.createdAt.addingTimeInterval(80)
        convo.chapters = [Chapter(title: "Start", start: 0), Chapter(title: "Later", start: 50)]
        let map = MeetingTimeline(convo)
        check.equal("a lane per person, in the order they first spoke", map.lanes.map(\.name), ["You", "Karen"])
        check.equal("two voices with one name are one person", map.lanes.last?.segments.count, 2)
        check.equal("remarks close together are one stretch", map.lanes.first?.segments, [
            MeetingTimeline.Segment(start: 0, end: 10), MeetingTimeline.Segment(start: 21, end: 30)])
        check.isTrue("shares add up to one", abs(map.lanes.map(\.share).reduce(0, +) - 1) < 0.0001)
        check.isTrue("you spoke 19 of 48.5 seconds", abs((map.lanes.first?.share ?? 0) - 19 / 48.5) < 0.01)
        check.equal("the length of the meeting", map.duration, 80)
        check.equal("chapters come along", map.chapters.map(\.title), ["Start", "Later"])
        check.equal("who was talking at 5s", map.speaker(at: 5)?.name, "You")
        check.equal("and at 65s", map.speaker(at: 65)?.name, "Karen")
        check.isTrue("and no one in a silence", map.speaker(at: 40) == nil)
        check.equal("a whole share", MeetingTimeline.percent(0.314), "31%")
        check.equal("a sliver", MeetingTimeline.percent(0.004), "<1%")
        check.isTrue("no talk, no lanes", MeetingTimeline(Meeting(title: "Empty")).isEmpty)

        // ── Chapters ─────────────────────────────────────────────────────────────
        let chaptered = SummaryParser.parse(#"{"title":"T","overview":"O","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"speakers":{},"chapters":[{"title":"Wrap-up","start":"1:02:03"},{"title":"Intro","start":"[0:05]"},{"title":"Middle","start":125},{"title":"Dupe","start":"0:05"},{"title":"","start":"3:00"},{"title":"No time"}]}"#)
        check.equal("chapters are read in order", chaptered?.chapters.map(\.title), ["Intro", "Middle", "Wrap-up"])
        check.equal("with their times", chaptered?.chapters.map(\.start), [5, 125, 3723])
        check.isTrue("a reply without chapters is fine", SummaryParser.parse(#"{"overview":"O"}"#)?.chapters.isEmpty == true)
        check.equal("a clock time", SummaryParser.seconds("12:03"), 723)
        check.isTrue("not a time", SummaryParser.seconds("soon") == nil)
        var withChapters = convo
        withChapters.summary = MeetingSummary(overview: "O.", keyPoints: ["k"])
        check.isTrue("topics reach the Markdown", MeetingMarkdown.render(withChapters).contains("### Topics\n\n- 0:00 — Start\n- 0:50 — Later"))
        let chapterFile = scratchDirectory("chapters")
        defer { try? FileManager.default.removeItem(at: chapterFile) }
        let chapterStore = MeetingStore(directory: chapterFile)
        withChapters.liveNotes = [LiveNote(time: 12, text: "Launch is Thursday.")]
        chapterStore.save(withChapters)
        check.equal("chapters and live notes round-trip", chapterStore.all().first, withChapters)
        var onlyNotes = convo
        onlyNotes.liveNotes = [LiveNote(time: 65, text: "Karen sends the list.")]
        check.isTrue("with no summary the live notes are the notes", MeetingMarkdown.render(onlyNotes).contains("## Notes\n\n- (1:05) Karen sends the list."))
        check.isTrue("with a summary they are not repeated", !MeetingMarkdown.render({ var m = withChapters; m.liveNotes = [LiveNote(time: 1, text: "ZZZ")]; return m }()).contains("ZZZ"))

        // ── Live notes ───────────────────────────────────────────────────────────
        check.equal("a note per line", LiveNotesParser.parse(#"{"notes":["Launch is Thursday.","- Daniel sends the schedule."]}"#),
                    ["Launch is Thursday.", "Daniel sends the schedule."])
        check.equal("nothing new is fine", LiveNotesParser.parse(#"Sure! {"notes": []}"#), [])
        check.equal("no more than three", LiveNotesParser.parse(#"{"notes":["a","b","c","d","e"]}"#)?.count, 3)
        check.equal("a list sent as one string", LiveNotesParser.parse(#"{"notes":"- one\n- two"}"#), ["one", "two"])
        check.isTrue("not the object asked for", LiveNotesParser.parse("I can't help with that.") == nil)
        check.isTrue("an object without notes", LiveNotesParser.parse(#"{"summary":"x"}"#) == nil)
        let notesPrompt = LiveNotesPrompt.user(previous: ["Launch is Thursday."], lines: ["[0:12] Karen: Hello."])
        check.isTrue("the notes so far go in", notesPrompt.contains("- Launch is Thursday."))
        check.isTrue("and the new talk", notesPrompt.contains("<new transcript>\n[0:12] Karen: Hello.\n</new transcript>"))
        check.isTrue("the first ask has no notes so far", !LiveNotesPrompt.user(previous: [], lines: ["x"]).contains("notes so far"))

        var pacer = LiveNotesPacer()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        check.isTrue("a first ask once there is enough said", pacer.shouldAsk(newWords: 40, now: t0))
        check.isTrue("not for a few words", !pacer.shouldAsk(newWords: 5, now: t0))
        pacer.began(now: t0)
        check.isTrue("not while one is out", !pacer.shouldAsk(newWords: 99, now: t0.addingTimeInterval(60)))
        pacer.ended(succeeded: true)
        check.isTrue("not again too soon", !pacer.shouldAsk(newWords: 99, now: t0.addingTimeInterval(20)))
        check.isTrue("but after the interval", pacer.shouldAsk(newWords: 99, now: t0.addingTimeInterval(46)))
        pacer.began(now: t0.addingTimeInterval(46))
        pacer.ended(succeeded: false)
        check.isTrue("a failure waits longer", !pacer.shouldAsk(newWords: 99, now: t0.addingTimeInterval(46 + 60)))
        check.isTrue("then tries again", pacer.shouldAsk(newWords: 99, now: t0.addingTimeInterval(46 + 91)))
        for _ in 0..<4 { pacer.began(now: t0); pacer.ended(succeeded: false) }
        check.isTrue("and gives up for good after repeated failures", pacer.gaveUp && !pacer.shouldAsk(newWords: 99, now: t0.addingTimeInterval(99_999)))

        // ── Asking about a meeting ───────────────────────────────────────────────
        let asked = MeetingAsk.user(meeting: withChapters, question: "Who is Karen?")
        check.isTrue("the question comes last", asked.hasSuffix("Question: Who is Karen?"))
        check.isTrue("the transcript is there", asked.contains("[0:00] You: one two three"))
        check.isTrue("and the summary", asked.contains("<summary>\nO.\n"))
        var huge = Meeting(title: "Huge")
        huge.utterances = (0..<400).map { Utterance(id: $0, speaker: $0 % 2 == 0 ? "you" : "s0", start: Double($0) * 10, end: Double($0) * 10 + 5, text: "line number \($0) has some words in it") }
        let trimmedAsk = MeetingAsk.user(meeting: huge, question: "?", maxCharacters: 3_000)
        check.isTrue("a long meeting is trimmed from the middle", trimmedAsk.contains("lines from the middle are left out"))
        check.isTrue("the beginning stays", trimmedAsk.contains("line number 0 "))
        check.isTrue("and the end", trimmedAsk.contains("line number 399 "))
        check.isTrue("and it fits", trimmedAsk.count < 4_000)

        check.finish()
    }
}
