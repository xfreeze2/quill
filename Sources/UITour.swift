import SwiftUI
import AppKit

/// QUILL_SELFTEST_UI=<folder> draws every screen of the window into PNGs, in
/// light and dark, from invented data in a scratch folder — nothing of yours is
/// read or changed. It is how the design is checked on a Mac whose display is off.
///
/// QUILL_SELFTEST_UI_MEETING=<mic.pcm>:<system.pcm> then runs a whole meeting
/// through the same model the window uses and draws it while live and when done.
enum UITour {

    private static func out(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    /// Work that has to wait for the interface to settle, run one step at a time
    /// from the main queue. Nothing here spins the run loop: a nested loop inside a
    /// main-queue block starves the very network callbacks a live meeting needs.
    private final class Steps {
        private var items: [(TimeInterval, () -> Void)] = []
        func after(_ delay: TimeInterval, _ work: @escaping () -> Void) { items.append((delay, work)) }
        func run(then done: @escaping () -> Void) {
            guard !items.isEmpty else { return done() }
            let (delay, work) = items.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                work()
                self.run(then: done)
            }
        }
    }

    private static var stage: StageWindow?

    static func run(directory: String) {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SidebarBackground.flat = true

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quill-ui-\(getpid())")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let model = AppModel(historyURL: scratch.appendingPathComponent("history.json"),
                             meetingsDirectory: scratch.appendingPathComponent("Meetings"))
        let ids = seed(model)
        let blank = AppModel(historyURL: scratch.appendingPathComponent("blank-history.json"),
                             meetingsDirectory: scratch.appendingPathComponent("BlankMeetings"))
        blank.snippets = []

        let steps = Steps()
        let size = CGSize(width: 1180, height: 780)
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            func page(_ name: String, _ section: AppModel.Section, width: CGFloat? = nil, height: CGFloat = 780, using chosen: AppModel? = nil,
                      prepare: @escaping (AppModel) -> Void = { _ in }) {
                let shown = chosen ?? model
                shoot("\(name)-\(tag)", size: CGSize(width: width ?? size.width, height: height), dark: dark, folder: folder, steps: steps) {
                    shown.section = section
                    prepare(shown)
                    return AnyView(RootView(model: shown))
                }
            }
            page("first-meetings", .meetings, using: blank) { $0.composingMeeting = true; $0.selectedMeetingID = nil }
            page("first-dictation", .dictation, using: blank) { $0.dictationTab = .history }
            page("first-vocabulary", .dictation, using: blank) { $0.dictationTab = .vocabulary }
            page("first-translation", .translate, using: blank)
            page("tasks", .meetings) { $0.composingMeeting = false; $0.showingTasks = true }
            page("meetings-summary", .meetings, height: 1280) { $0.showingTasks = false; $0.composingMeeting = false; $0.selectedMeetingID = ids.roadmap }
            page("meetings-people", .meetings) { $0.showingTasks = false; $0.composingMeeting = false; $0.selectedMeetingID = ids.design }
            page("meetings-failed", .meetings) { $0.showingTasks = false; $0.selectedMeetingID = ids.coffee }
            page("meetings-new", .meetings) { $0.showingTasks = false; $0.composingMeeting = true }
            page("dictation-history", .dictation) { $0.dictationTab = .history }
            page("dictation-vocabulary", .dictation) { $0.dictationTab = .vocabulary }
            page("translation", .translate)
            page("settings", .settings, height: 1500)
            page("min-meetings", .meetings, width: 980, height: 640) { $0.showingTasks = false; $0.composingMeeting = true }
            page("min-dictation", .dictation, width: 980, height: 640) { $0.dictationTab = .history }
            page("min-translation", .translate, width: 980, height: 640)
            page("palette", .meetings) { $0.showingSearch = true; $0.searchSeed = "" }
            page("palette-search", .meetings) { $0.showingSearch = true; $0.searchSeed = "beta" }
            page("palette-reset", .meetings) { $0.showingSearch = false; $0.searchSeed = "" }

            for (name, tab) in [("transcript", MeetingDetailView.Tab.transcript), ("ask", .ask), ("notes", .notes)] {
                shoot("meeting-\(name)-\(tag)", size: CGSize(width: 768, height: 780), dark: dark, folder: folder, steps: steps) {
                    model.composingMeeting = false
                    guard let meeting = model.meeting(ids.roadmap) else { return AnyView(EmptyView()) }
                    return AnyView(ZStack { Palette.canvas; MeetingDetailView(model: model, meeting: meeting, tab: tab) })
                }
            }
        }

        steps.run {
            if let spec = ProcessInfo.processInfo.environment["QUILL_SELFTEST_UI_MEETING"] {
                liveMeeting(spec: spec, model: model, folder: folder, scratch: scratch)
            } else {
                out("UI TOUR: done — \(folder.path)")
                try? FileManager.default.removeItem(at: scratch)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Drawing

    /// Draws a screen: build it, give it a moment to lay out, then capture.
    private static func shoot(_ name: String, size: CGSize, dark: Bool, folder: URL, steps: Steps,
                              build: @escaping () -> AnyView) {
        steps.after(0) {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = StageWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                     backing: .buffered, defer: false)
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: build())
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            // Far off any screen, but "in front", so controls draw as they do in a
            // window you are looking at rather than the greyed-out inactive state.
            window.setFrame(NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: size), display: false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            stage = window
        }
        steps.after(0.7) {
            guard let window = stage, let host = window.contentView else { return }
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let url = folder.appendingPathComponent(name + ".png")
                    try? png.write(to: url)
                    out("UI TOUR: \(url.lastPathComponent)  \(Int(size.width))×\(Int(size.height))")
                }
            } else {
                out("UI TOUR: could not draw \(name)")
            }
            window.orderOut(nil)
            window.contentView = nil
            stage = nil
        }
    }

    private final class StageWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    // MARK: Invented data

    private struct Seeded { var roadmap: UUID; var design: UUID; var coffee: UUID }

    private static func seed(_ model: AppModel) -> Seeded {
        let now = Date()
        func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
            now.addingTimeInterval(-(days * 86_400 + hours * 3_600 + minutes * 60))
        }
        let dictations: [(String, String?, Double, Date)] = [
            ("Can you send me the latest numbers before the call? I want to look them over first.", "Slack", 6, ago(days: 4, hours: 3)),
            ("Thanks for the quick turnaround. I'll review the draft this afternoon and send comments by end of day.", "Mail", 9, ago(days: 3, hours: 1)),
            ("Remember to renew the domain before the end of the month and check that auto-renew is on.", "Notes", 7, ago(days: 2, hours: 5)),
            ("Refactor the settings screen so each section is its own view, and add a preview for dark mode.", "Cursor", 8, ago(days: 1, hours: 2)),
            ("Hi Sam, quick update: the beta build is out, and the first round of feedback looks really encouraging.", "Messages", 8, ago(days: 1, hours: 1)),
            ("Dinner at eight on Friday works for me. Should I book the table, or are you handling it?", "Messages", 7, ago(hours: 5)),
            ("I think the onboarding is too long. Let's cut it down to three steps and move the rest into the app.", "Notion", 11, ago(hours: 3)),
            ("Agenda for tomorrow: roadmap, hiring plan, and the launch checklist.", "Notes", 5, ago(hours: 1)),
            ("Looks good to me. Ship it.", "GitHub", 2, ago(minutes: 25)),
        ]
        for item in dictations {
            _ = model.history.add(text: item.0, app: item.1, seconds: item.2, date: item.3)
        }
        model.reloadHistory()
        model.snippets = [
            Snippet(trigger: "my email", expansion: "alex@example.com"),
            Snippet(trigger: "calendar link", expansion: "https://cal.example.com/alex"),
            Snippet(trigger: "thanks sign off", expansion: "Thanks so much,\nAlex"),
        ]

        // A call between three people.
        var roadmap = Meeting(title: "Q4 roadmap review", createdAt: ago(hours: 20), capture: .call)
        let script: [(String, Double, Double, String)] = [
            ("you", 2, 9, "Okay, thanks for joining everyone. Let's go through the Q4 roadmap and decide what we're cutting."),
            ("s0", 10, 24, "I'll start with search. The new ranking model is ready for beta, and early numbers show clicks up about eleven percent."),
            ("s1", 25, 38, "That's great. My worry is the mobile app, we're two weeks behind and the design review is still open."),
            ("s0", 39, 50, "If we push mobile to the first sprint of January, we keep search on track for the end of October."),
            ("you", 51, 58, "I'm fine with that. Daniel, can you confirm the January date with the design team?"),
            ("s1", 59, 70, "Yes, I'll talk to them tomorrow. We should also decide who owns the launch checklist."),
            ("you", 71, 79, "I'll take the launch checklist. Karen, please send the beta invite list by Friday."),
            ("s0", 80, 90, "Will do. One open question: do we announce at the conference or wait for the blog post?"),
            ("s1", 91, 102, "I'd wait for the blog post. The conference demo isn't stable enough to show yet."),
            ("you", 103, 110, "Agreed. Let's revisit that next week once the demo is more stable."),
        ]
        for (index, line) in script.enumerated() {
            roadmap.utterances.append(Utterance(id: index, speaker: line.0, start: line.1, end: line.2, text: line.3))
        }
        roadmap.speakerNames = ["s0": "Karen", "s1": "Daniel"]
        roadmap.endedAt = roadmap.createdAt.addingTimeInterval(118)
        roadmap.titleIsAutomatic = false
        roadmap.summaryState = .ready
        roadmap.chapters = [
            Chapter(title: "Search ranking is ready for beta", start: 10),
            Chapter(title: "Mobile slips to January", start: 25),
            Chapter(title: "Who owns the launch checklist", start: 59),
            Chapter(title: "Announce at the conference, or the blog?", start: 80),
        ]
        roadmap.userNotes = "Follow up with design about the mobile review.\nBlog post goes out before the conference."
        roadmap.summary = MeetingSummary(
            overview: "The team reviewed the Q4 roadmap. Search ranking is ready for beta, mobile is two weeks behind and moves to January, and the announcement waits for the blog post.",
            keyPoints: [
                "The new search ranking model is ready for beta, with clicks up about 11% in early numbers.",
                "The mobile app is two weeks behind and the design review is still open.",
                "The conference demo isn't stable enough to show yet.",
            ],
            decisions: [
                "Push the mobile launch to the first sprint of January so search stays on track for end of October.",
                "Announce through the blog post rather than at the conference.",
            ],
            actionItems: [
                ActionItem(owner: "Daniel", task: "Confirm the January date with the design team.", done: true),
                ActionItem(owner: "You", task: "Own the launch checklist."),
                ActionItem(owner: "Karen", task: "Send the beta invite list by Friday."),
            ],
            openQuestions: ["Should the announcement wait for the blog post, or happen at the conference?"])
        model.store.save(roadmap)

        // A shorter one whose voices have not been named yet.
        var design = Meeting(title: "Weekly design sync", createdAt: ago(days: 2, hours: 4), capture: .room)
        design.utterances = [
            Utterance(id: 0, speaker: "s0", start: 3, end: 12, text: "The new onboarding tested well, people finished it in under a minute."),
            Utterance(id: 1, speaker: "s1", start: 13, end: 22, text: "Great. Priya, can you send the final icons to engineering today?"),
            Utterance(id: 2, speaker: "s0", start: 23, end: 28, text: "Yes, I'll export them this afternoon."),
        ]
        design.endedAt = design.createdAt.addingTimeInterval(900)
        design.summaryState = .ready
        design.summary = MeetingSummary(
            overview: "A short design sync. Onboarding tested well and the final icons go to engineering today.",
            keyPoints: ["People finished the new onboarding in under a minute."],
            decisions: [],
            actionItems: [ActionItem(owner: "Priya", task: "Export the final icons and send them to engineering.")],
            openQuestions: [])
        design.suggestedNames = ["s0": "Priya"]
        model.store.save(design)

        // One whose summary did not come through.
        var coffee = Meeting(title: "Meeting · coffee with Sam", createdAt: ago(days: 5, hours: 2), capture: .room)
        coffee.utterances = [Utterance(id: 0, speaker: "s0", start: 4, end: 20, text: "We talked about the beta, the hiring plan and whether to move the launch to the spring.")]
        coffee.endedAt = coffee.createdAt.addingTimeInterval(2_400)
        coffee.summaryState = .failed
        coffee.summaryError = "Couldn't reach Grok to write the summary. Check your connection and try again."
        model.store.save(coffee)

        model.reloadMeetings()
        return Seeded(roadmap: roadmap.id, design: design.id, coffee: coffee.id)
    }

    // MARK: A whole meeting through the window's own model

    private static func liveMeeting(spec: String, model: AppModel, folder: URL, scratch: URL) {
        let paths = spec.split(separator: ":").map(String.init)
        guard let micPath = paths.first, let mic = PCMFileSource(path: micPath) else {
            out("UI TOUR: cannot read \(spec)")
            NSApp.terminate(nil)
            return
        }
        let system = paths.count > 1 ? PCMFileSource(path: paths[1]) : nil
        var remaining = system == nil ? 1 : 2
        let ended = {
            remaining -= 1
            guard remaining == 0 else { return }
            out("UI TOUR: audio ended — stopping the meeting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.stopMeeting() }
        }
        mic.onFinished = ended
        system?.onFinished = ended

        model.startMeeting(capture: system == nil ? .room : .call, keepAudio: true, language: "auto",
                           testSources: .init(mic: mic, system: system))
        guard let id = model.session?.meeting.id else {
            out("UI TOUR: the meeting did not start")
            NSApp.terminate(nil)
            return
        }
        model.selectedMeetingID = id
        model.section = .meetings
        out("UI TOUR: meeting started — \(mic.seconds)s of audio")

        let deadline = Date().addingTimeInterval(Double(mic.seconds) + 90)
        var drewLive = false

        func finish() {
            guard let meeting = model.meeting(id) else {
                out("UI TOUR: the meeting vanished")
                NSApp.terminate(nil)
                return
            }
            out("UI TOUR: finished — \(meeting.utterances.count) remarks, voices \(meeting.speakers.map { meeting.name(for: $0) }), "
                + "summary \(meeting.summaryState.rawValue), audio kept \(meeting.hasAudio), title “\(meeting.title)”")
            if let error = meeting.summaryError { out("UI TOUR: summary error — \(error)") }
            out("UI TOUR: \(meeting.liveNotes.count) live notes, \(meeting.chapters.count) topics")
            meeting.liveNotes.forEach { out("UI TOUR: note [\(Meeting.clock($0.time))] \($0.text)") }
            meeting.chapters.forEach { out("UI TOUR: topic [\(Meeting.clock($0.start))] \($0.title)") }
            if let summary = meeting.summary {
                out("UI TOUR: overview — \(summary.overview)")
                summary.actionItems.forEach { out("UI TOUR: action [\($0.owner ?? "-")] \($0.task)") }
                out("UI TOUR: suggested names \(meeting.suggestedNames)")
            }
            model.composingMeeting = false
            let steps = Steps()
            for dark in [false, true] {
                shoot("finished-\(dark ? "dark" : "light")", size: CGSize(width: 1180, height: 780), dark: dark, folder: folder, steps: steps) {
                    AnyView(RootView(model: model))
                }
            }
            steps.run {
                try? FileManager.default.removeItem(at: scratch)
                NSApp.terminate(nil)
            }
        }

        func poll() {
            let count = model.session?.meeting.utterances.count ?? 0
            if !drewLive, count >= 3 {
                drewLive = true
                out("UI TOUR: drawing the live meeting with \(count) remarks")
                let steps = Steps()
                for dark in [false, true] {
                    shoot("live-\(dark ? "dark" : "light")", size: CGSize(width: 1180, height: 780), dark: dark, folder: folder, steps: steps) {
                        AnyView(RootView(model: model))
                    }
                }
                steps.run { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll) }
                return
            }
            let done = model.session == nil && !model.summarizing.contains(id)
                && (model.meeting(id)?.summaryState == .ready || model.meeting(id)?.summaryState == .failed)
            if done || Date() > deadline { finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }
}
