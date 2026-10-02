import Cocoa

/// Self-test entry points that exercise the real speech service end to end, run
/// by launching the app with an environment variable. They print to stderr and
/// quit; none of them touch the user's saved settings or history.
enum SelfTests {

    private static func out(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// QUILL_SELFTEST_STT_RAW=<file.pcm> — stream a 16 kHz mono PCM16 file to the
    /// speech service in real time and print every finished chunk with its words.
    /// QUILL_SELFTEST_DIARIZE=1 asks the service to tell the voices apart.
    static func speechRaw(path: String) {
        guard let creds = Auth.current(), let file = PCMFileSource(path: path) else {
            out("STT RAW: no sign-in, or cannot read \(path)")
            NSApp.terminate(nil)
            return
        }
        let diarize = ProcessInfo.processInfo.environment["QUILL_SELFTEST_DIARIZE"] != nil
        let client = STTClient()
        let began = Date()
        out("STT RAW: \(file.seconds)s of audio, diarize=\(diarize)")

        client.onSegment = { segment in
            guard segment.isFinal else { return }
            let kind = segment.speechFinal ? "UTTERANCE" : "chunk    "
            let at = String(format: "%5.1f", Date().timeIntervalSince(began))
            out("[\(at)] \(kind) \(segment.text.debugDescription)")
            let words = segment.words.map {
                "\($0.text.debugDescription)@\(String(format: "%.2f", $0.start))#\($0.speaker.map(String.init) ?? "-")"
            }
            out("         \(words.joined(separator: " "))")
        }
        client.onFailure = { failure in
            out("STT RAW: failed — \(failure.message)")
            NSApp.terminate(nil)
        }
        client.onComplete = { _ in
            out("STT RAW: done")
            NSApp.terminate(nil)
        }
        client.onReady = {
            file.onPCM = { client.send(pcm: $0) }
            file.onFinished = { client.finish() }
            try? file.start()
        }
        client.doneGrace = 5
        client.connect(token: creds.token, language: "auto", diarize: diarize)
    }

    /// QUILL_SELFTEST_MEETING_LIVE=<call|room>:<seconds> — record a meeting from the
    /// real microphone and, for a call, the real system audio, for that long.
    /// QUILL_SELFTEST_SAY="text" has the Mac speak while it runs, which both the
    /// microphone and the system-audio tap then hear. Scratch folder only.
    static func meetingLive(spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let capture: MeetingCapture = parts.first == "room" ? .room : .call
        let seconds = Double(parts.dropFirst().first ?? "") ?? 25
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quill-meeting-live-\(getpid())")
        let store = MeetingStore(directory: directory)
        let keepAudio = ProcessInfo.processInfo.environment["QUILL_SELFTEST_KEEP_AUDIO"] != nil
        let session = MeetingSession(store: store, capture: capture, keepAudio: keepAudio)
        out("MEETING LIVE: \(capture.rawValue) for \(Int(seconds))s, audio kept: \(keepAudio)")

        var shown = 0
        var lastPhase = ""
        var lastNotices: [String: String] = [:]
        var peakMic: Float = 0
        var peakSystem: Float = 0
        session.onChange = {
            peakMic = max(peakMic, session.micLevel)
            peakSystem = max(peakSystem, session.systemLevel)
            let phase = "\(session.phase)"
            if phase != lastPhase { lastPhase = phase; out("MEETING LIVE: phase → \(phase)") }
            if session.notices != lastNotices {
                lastNotices = session.notices
                session.notices.forEach { out("MEETING LIVE: notice [\($0.key)] \($0.value)") }
            }
            let utterances = session.meeting.utterances
            while shown < utterances.count {
                let u = utterances[shown]
                out(String(format: "[%5.1f] %-9@ %@", u.start, session.meeting.name(for: u.speaker) as NSString, u.text))
                shown += 1
            }
            if case .failed(let message) = session.phase {
                out("MEETING LIVE: failed — \(message)")
                NSApp.terminate(nil)
            }
        }
        session.onFinished = { meeting in
            out("MEETING LIVE: finished — \(meeting.utterances.count) remarks, voices \(meeting.speakers.map { meeting.name(for: $0) }), "
                + "audio kept = \(meeting.hasAudio), levels mic \(String(format: "%.3f", peakMic)) system \(String(format: "%.3f", peakSystem))")
            meeting.transcriptLines().forEach { out("  " + $0) }
            if keepAudio {
                let url = store.audioURL(for: meeting.id)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                out("MEETING LIVE: recording is \(size) bytes")
            }
            try? FileManager.default.removeItem(at: directory)
            NSApp.terminate(nil)
        }
        session.start()

        if let phrase = ProcessInfo.processInfo.environment["QUILL_SELFTEST_SAY"], !phrase.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-v", "Samantha", phrase]
                try? say.run()
                out("MEETING LIVE: the Mac is speaking")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { session.stop() }
    }

    /// QUILL_SELFTEST_MEETING=<mic.pcm>:<system.pcm> — record a meeting from two
    /// files, played in real time as the microphone and the call, then summarise
    /// it, and print who said what and what the notes came to. The meeting goes in a
    /// scratch folder, never the real library. QUILL_SELFTEST_KEEP_AUDIO=1 also
    /// keeps and checks the recording.
    static func meeting(spec: String) {
        let paths = spec.split(separator: ":").map(String.init)
        guard let micPath = paths.first, let mic = PCMFileSource(path: micPath) else {
            out("MEETING: cannot read the microphone file in \(spec)")
            NSApp.terminate(nil)
            return
        }
        let system = paths.count > 1 ? PCMFileSource(path: paths[1]) : nil
        let keepAudio = ProcessInfo.processInfo.environment["QUILL_SELFTEST_KEEP_AUDIO"] != nil
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quill-meeting-test-\(getpid())")
        let store = MeetingStore(directory: directory)
        let session = MeetingSession(store: store, capture: system == nil ? .room : .call, keepAudio: keepAudio,
                                     testSources: .init(mic: mic, system: system))
        let began = Date()
        out("MEETING: \(mic.seconds)s of microphone\(system.map { ", \($0.seconds)s of call" } ?? ""), audio kept: \(keepAudio)")

        var remaining = system == nil ? 1 : 2
        let filesEnded = {
            remaining -= 1
            guard remaining == 0 else { return }
            out("MEETING: audio ended after \(Int(Date().timeIntervalSince(began)))s, stopping")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { session.stop() }
        }
        mic.onFinished = filesEnded
        system?.onFinished = filesEnded

        var shown = 0
        session.onChange = {
            let utterances = session.meeting.utterances
            while shown < utterances.count {
                let u = utterances[shown]
                out(String(format: "[%5.1f] %-9@ %@", u.start, session.meeting.name(for: u.speaker) as NSString, u.text))
                shown += 1
            }
            if case .failed(let message) = session.phase {
                out("MEETING: failed — \(message)")
                NSApp.terminate(nil)
            }
        }
        session.onFinished = { meeting in
            out("MEETING: \(meeting.utterances.count) remarks, voices: \(meeting.speakers.map { meeting.name(for: $0) })")
            if keepAudio {
                let url = store.audioURL(for: meeting.id)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                out("MEETING: audio kept = \(meeting.hasAudio), \(size) bytes for \(Int(meeting.duration))s")
            }
            out("MEETING: summarising…")
            MeetingSummarizer.summarize(meeting) { result in
                switch result {
                case .failure(let failure):
                    out("MEETING: summary failed — \(failure.message)")
                case .success(let parsed):
                    out("MEETING: title: \(parsed.title ?? "-")")
                    out("  overview: \(parsed.summary.overview)")
                    parsed.summary.keyPoints.forEach { out("  point: \($0)") }
                    parsed.summary.decisions.forEach { out("  decision: \($0)") }
                    parsed.summary.actionItems.forEach { out("  action: [\($0.owner ?? "-")] \($0.task)") }
                    parsed.summary.openQuestions.forEach { out("  question: \($0)") }
                    out("  names found: \(parsed.speakers)")
                    out("  suggested for voices: \(SummaryParser.suggestions(parsed.speakers, for: meeting))")
                }
                try? FileManager.default.removeItem(at: directory)
                NSApp.terminate(nil)
            }
        }
        session.start()
    }
}
