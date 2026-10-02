import Cocoa

// Listening to a meeting: one speech connection per source of sound, kept alive
// for as long as the meeting lasts, and everything they hear gathered into one
// transcript with a name against every remark.

// MARK: - One source of sound

/// A single source of audio — the microphone, or what the Mac is playing — and
/// the speech connection that turns it into words.
///
/// It follows the reliability pattern live translation settled on: audio is held
/// while there is no connection and sent when one opens, a dropped connection is
/// reopened at once and then with backoff, and a long-running one is swapped
/// for a fresh one during a pause so no sentence is split between the two.
///
/// Unlike translation it swaps rarely. The service numbers the voices it hears
/// afresh on every connection, so each swap is a chance to lose track of who is
/// who; the lane hands every connection's voices ids of their own, and the
/// person can name two of them alike to put it right.
final class LaneTranscriber {

    let name: String
    let voices: LaneAssembler.Voices
    private let language: String
    private let clock: () -> Double

    var onFragments: ([Fragment]) -> Void = { _ in }
    var onLive: (LiveLine?) -> Void = { _ in }
    /// A message for the person while the lane cannot hear, or nil once it can.
    var onProblem: (String?) -> Void = { _ in }

    private final class Link {
        let client = STTClient()
        let epoch: Int
        var assembler: LaneAssembler?
        var openedAt = Date()
        var isOpen = false
        init(epoch: Int) { self.epoch = epoch }
    }

    private var current: Link?
    private var draining: [Link] = []
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var fedBytes = 0
    private var origin: Double?
    private var epochs = 0
    private var voiceIDs: [String: Int] = [:]
    private var running = true
    private var retryWork: DispatchWorkItem?
    private var recentFailures: [Date] = []
    private var lastLoudAt = Date()
    private var lastLive: LiveLine?
    private var stopped: (() -> Void)?
    private var stopTimeout: DispatchWorkItem?

    /// A minute of 16 kHz PCM16: what is held while there is no connection.
    private static let maxPending = 16_000 * 2 * 60

    /// How long a connection lives before it is swapped at the next pause, and
    /// the longest it may go on if no pause comes.
    private let swapAfter: Double
    private let swapNoLaterThan: Double

    init(name: String, voices: LaneAssembler.Voices, language: String = "auto", clock: @escaping () -> Double) {
        self.name = name
        self.voices = voices
        self.language = language
        self.clock = clock
        switch voices {
        case .one:     (swapAfter, swapNoLaterThan) = (300, 540)
        case .several: (swapAfter, swapNoLaterThan) = (1_200, 1_500)
        }
    }

    // MARK: Audio in

    func noteLevel(_ level: Float) {
        if level > 0.05 { lastLoudAt = Date() }
    }

    func feed(_ data: Data) {
        guard running else { return }
        if origin == nil { origin = clock() }
        fedBytes += data.count
        if let link = current, link.isOpen {
            link.client.send(pcm: data)
        } else {
            pending.append(data)
            pendingBytes += data.count
            while pendingBytes > Self.maxPending, !pending.isEmpty { pendingBytes -= pending.removeFirst().count }
        }
        // Only now: the service drops a connection that goes a minute without audio.
        if current == nil, retryWork == nil { openSocket() }
    }

    /// Once a second.
    func tick() {
        guard running, let link = current, link.isOpen, let assembler = link.assembler else { return }
        let age = Date().timeIntervalSince(link.openedAt)
        if age > swapAfter, assembler.live == nil, Date().timeIntervalSince(lastLoudAt) > 1.0 {
            rotate(reason: "\(Int(age))s old, pause in speech")
        } else if age > swapNoLaterThan {
            rotate(reason: "\(Int(age))s old, no pause came")
        }
    }

    // MARK: Connections

    private func openSocket() {
        retryWork = nil
        guard running else { return }
        guard let creds = Auth.current() else {
            onProblem("No Grok sign-in found — run `grok` once, or add an xAI API key in Settings")
            return
        }
        let link = Link(epoch: epochs)
        epochs += 1
        current = link

        link.client.onReady = { [weak self, weak link] in
            guard let self, let link, link === self.current else { return }
            link.isOpen = true
            link.openedAt = Date()
            // The connection's clock starts at the first byte it is sent.
            let base = (self.origin ?? self.clock()) + Double(self.fedBytes - self.pendingBytes) / Double(AudioArchive.bytesPerSecond)
            let assembler = LaneAssembler(voices: self.voices, base: base, epoch: link.epoch)
            let epoch = link.epoch
            assembler.voiceName = { [weak self] index in self?.voiceID(epoch: epoch, index: index) ?? "s\(index)" }
            link.assembler = assembler
            for chunk in self.pending { link.client.send(pcm: chunk) }
            if self.pendingBytes > 0 {
                Log.write("meeting[\(self.name)]: connection open, sent \(self.pendingBytes / AudioArchive.bytesPerSecond)s held audio")
            }
            self.pending.removeAll()
            self.pendingBytes = 0
            self.onProblem(nil)
        }
        link.client.onSegment = { [weak self, weak link] segment in
            guard let self, let link else { return }
            self.heard(link, segment)
        }
        link.client.onFailure = { [weak self, weak link] failure in
            guard let self, let link else { return }
            self.ended(link, failure: failure)
        }
        link.client.onComplete = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.ended(link, failure: nil)
        }
        link.client.connect(token: creds.token, language: language, diarize: { if case .several = voices { return true } else { return false } }())
    }

    private func heard(_ link: Link, _ segment: STTClient.Segment) {
        guard let assembler = link.assembler else { return }
        let kind: StreamKind = !segment.isFinal ? .interim : (segment.speechFinal ? .utteranceFinal : .chunkFinal)
        let words = segment.words.map { SpokenWord(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker) }
        let fragments = assembler.apply(text: segment.text, words: words, kind: kind)
        if !fragments.isEmpty { onFragments(fragments) }
        publishLive()
    }

    private func publishLive() {
        let live = current?.assembler?.live
        if live != lastLive {
            lastLive = live
            onLive(live)
        }
    }

    private func ended(_ link: Link, failure: STTClient.Failure?) {
        let leftover = link.assembler?.flush() ?? []
        if !leftover.isEmpty { onFragments(leftover) }
        draining.removeAll { $0 === link }

        if link === current {
            current = nil
            if running {
                Log.write("meeting[\(name)]: speech-to-text ended — \(failure?.message ?? "closed by the server")")
                publishLive()
                if failure == .unauthorized {
                    onProblem(STTClient.Failure.unauthorized.message)
                    reconnect(atLeast: 15)
                } else {
                    reconnect()
                }
            }
        }
        finishStoppingIfDone()
    }

    private func reconnect(atLeast minimum: TimeInterval = 0) {
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        let attempt = recentFailures.count
        let delay: TimeInterval = max(minimum, attempt <= 1 ? 0 : min(10, pow(2, Double(attempt - 1))))
        if attempt >= 3, minimum == 0 { onProblem("Reconnecting…") }
        let work = DispatchWorkItem { [weak self] in self?.openSocket() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rotate(reason: String) {
        guard running, let old = current, old.isOpen else { return }
        Log.write("meeting[\(name)]: new speech-to-text connection — \(reason)")
        draining.append(old)
        old.client.doneGrace = 6
        old.client.finish()
        current = nil
        openSocket()
    }

    /// The id a voice goes by in the meeting. Never repeats across connections.
    private func voiceID(epoch: Int, index: Int) -> String {
        let key = "\(epoch):\(index)"
        if let known = voiceIDs[key] { return "s\(known)" }
        let id = voiceIDs.count
        voiceIDs[key] = id
        return "s\(id)"
    }

    // MARK: Ending

    /// Stops listening; what the service is still working out is waited for.
    func stop(_ done: @escaping () -> Void) {
        guard running else { return done() }
        running = false
        retryWork?.cancel()
        retryWork = nil
        stopped = done

        if let link = current {
            // Even a connection still opening is asked to finish: it holds the request
            // until it is up, so the audio waiting for it is still heard.
            draining.append(link)
            link.client.doneGrace = 4
            link.client.finish()
        }
        guard !draining.isEmpty else { return finishStoppingIfDone() }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for link in self.draining {
                link.client.cancel()
                let leftover = link.assembler?.flush() ?? []
                if !leftover.isEmpty { self.onFragments(leftover) }
            }
            self.draining.removeAll()
            self.finishStoppingIfDone()
        }
        stopTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func finishStoppingIfDone() {
        guard !running, draining.isEmpty, let done = stopped else { return }
        stopped = nil
        stopTimeout?.cancel()
        stopTimeout = nil
        current = nil
        lastLive = nil
        onLive(nil)
        done()
    }
}

// MARK: - A whole meeting

/// Records one meeting: starts the sources of sound, gathers what they hear,
/// keeps it safe on disk as it goes, and ends cleanly.
final class MeetingSession {

    enum Phase: Equatable {
        case starting
        case recording
        case stopping
        case finished
        case failed(String)
    }

    private(set) var meeting: Meeting
    private(set) var phase: Phase = .starting
    /// Things the person should know: a source that cannot be heard, a connection being retried.
    private(set) var notices: [String: String] = [:]
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var startedAt = Date()
    let keepsAudio: Bool
    let store: MeetingStore

    var onChange: () -> Void = {}
    var onFinished: (Meeting) -> Void = { _ in }

    /// A stand-in for real capture, used by the self-test.
    struct Sources {
        var mic: AudioSource
        var system: AudioSource?
    }

    private let capture: MeetingCapture
    private let language: String
    private let testSources: Sources?
    private let transcript = MeetingTranscript()
    private var lanes: [LaneTranscriber] = []
    private var audios: [AudioSource] = []
    private var liveLines: [String: LiveLine] = [:]
    private var archive: AudioArchive?
    private var timer: Timer?
    private var dirty = false
    private var lastSavedAt = Date.distantPast

    init(store: MeetingStore, capture: MeetingCapture, keepAudio: Bool, language: String = "auto", testSources: Sources? = nil) {
        self.store = store
        self.capture = capture
        self.keepsAudio = keepAudio
        self.language = language
        self.testSources = testSources
        meeting = Meeting(title: Meeting.defaultTitle(for: Date()), createdAt: Date(), capture: capture)
    }

    var elapsed: TimeInterval { phase == .finished ? meeting.duration : Date().timeIntervalSince(startedAt) }

    var isActive: Bool {
        switch phase {
        case .starting, .recording: return true
        default: return false
        }
    }

    /// What is being said right now, one line per source, in the order they began.
    var live: [LiveLine] {
        lanes.compactMap { liveLines[$0.name] }
    }

    // MARK: Start

    func start() {
        Recorder.micAuthorization { [weak self] granted in
            guard let self, self.phase == .starting else { return }
            guard granted else {
                self.fail("Quill isn't allowed to use the microphone. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone.")
                return
            }
            if let test = self.testSources {
                self.begin(mic: test.mic, system: test.system)
            } else if self.capture == .call {
                self.resolveSystemAudio()
            } else {
                self.begin(mic: Recorder(), system: nil)
            }
        }
    }

    private func resolveSystemAudio() {
        guard #available(macOS 14.2, *) else {
            notices["call"] = "Hearing the other side of a call needs macOS 14.2 or newer. Quill is listening to the microphone only."
            return begin(mic: Recorder(), system: nil)
        }
        func go() {
            let system = SystemAudio()
            system.onRestart = { reason in Log.write("meeting: system audio rebuilt — \(reason)") }
            begin(mic: Recorder(), system: system)
        }
        func refuse() {
            notices["call"] = "Quill isn't allowed to hear the Mac's audio, so the other side of the call is missing. "
                + "Turn on Quill under “System Audio Recording Only” in System Settings."
            begin(mic: Recorder(), system: nil)
        }
        switch SystemAudioPermission.status {
        case .granted: go()
        case .denied:  refuse()
        case .unknown:
            SystemAudioPermission.request { [weak self] granted in
                guard let self, self.phase == .starting else { return }
                granted ? go() : refuse()
            }
        }
    }

    private func begin(mic: AudioSource, system: AudioSource?) {
        startedAt = Date()
        meeting.createdAt = startedAt
        meeting.title = Meeting.defaultTitle(for: startedAt)
        let clock: () -> Double = { [weak self] in Date().timeIntervalSince(self?.startedAt ?? Date()) }

        // The microphone is you only if the call's audio is heard separately;
        // otherwise it hears the whole room, and the voices are told apart.
        let micLane = LaneTranscriber(name: "mic", voices: system != nil ? .one("you") : .several, language: language, clock: clock)
        var sources: [(AudioSource, LaneTranscriber)] = [(mic, micLane)]
        if let system {
            sources.append((system, LaneTranscriber(name: "call", voices: .several, language: language, clock: clock)))
        }

        if keepsAudio {
            archive = AudioArchive(folder: store.folder(for: meeting.id))
        }

        var started: [AudioSource] = []
        for (index, (source, lane)) in sources.enumerated() {
            lane.onFragments = { [weak self] in self?.add($0) }
            lane.onLive = { [weak self, weak lane] line in
                guard let self, let lane else { return }
                self.liveLines[lane.name] = line
                self.onChange()
            }
            lane.onProblem = { [weak self, weak lane] message in
                guard let self, let lane else { return }
                self.notices[lane.name] = message
                self.onChange()
            }
            source.onPCM = { [weak self, weak lane, weak source] data in
                DispatchQueue.main.async {
                    guard let self, let lane, let source, self.audios.contains(where: { $0 === source }) else { return }
                    lane.feed(data)
                    self.archive?.append(lane: index, pcm: data)
                }
            }
            source.onLevel = { [weak self, weak lane, weak source] level in
                DispatchQueue.main.async {
                    guard let self, let lane, let source, self.audios.contains(where: { $0 === source }) else { return }
                    lane.noteLevel(level)
                    if lane.name == "mic" { self.micLevel = level } else { self.systemLevel = level }
                }
            }
            audios.append(source)
            do {
                try source.start()
                started.append(source)
                lanes.append(lane)
            } catch {
                audios.removeAll { $0 === source }
                Log.write("meeting: \(lane.name) audio failed to start — \(error.localizedDescription)")
                if lane.name == "mic" {
                    started.forEach { $0.stop() }
                    audios.removeAll()
                    return fail(error.localizedDescription)
                }
                notices[lane.name] = "Couldn't hear the call: \(error.localizedDescription)"
            }
        }

        phase = .recording
        store.save(meeting)
        Log.write("meeting started — \(capture.rawValue), audio \(keepsAudio ? "kept" : "not kept")")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        onChange()
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        onChange()
    }

    // MARK: While it runs

    private func add(_ fragments: [Fragment]) {
        guard transcript.add(fragments) else { return }
        meeting.utterances = transcript.utterances
        dirty = true
        onChange()
    }

    func setNotes(_ text: String) {
        guard text != meeting.userNotes else { return }
        meeting.userNotes = text
        dirty = true
    }

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meeting.title = trimmed
        meeting.titleIsAutomatic = false
        dirty = true
        onChange()
    }

    private func tick() {
        lanes.forEach { $0.tick() }
        if dirty, Date().timeIntervalSince(lastSavedAt) > 10 {
            store.save(meeting)
            dirty = false
            lastSavedAt = Date()
        }
    }

    // MARK: End

    /// Stops listening, waits for the last words, and saves. `onFinished` follows.
    func stop() {
        guard phase == .recording else {
            if phase == .starting { phase = .failed("Stopped before it began") ; onChange() }
            return
        }
        phase = .stopping
        store.save(meeting)
        audios.forEach { $0.stop() }
        audios.removeAll()
        micLevel = 0
        systemLevel = 0
        onChange()

        let group = DispatchGroup()
        for lane in lanes {
            group.enter()
            lane.stop { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.meeting.endedAt = Date()
            self.meeting.utterances = self.transcript.utterances
            self.store.save(self.meeting)
            if let archive = self.archive {
                archive.finish { [weak self] kept in
                    guard let self else { return }
                    self.meeting.hasAudio = kept
                    self.conclude()
                }
            } else {
                self.conclude()
            }
        }
    }

    private func conclude() {
        timer?.invalidate()
        timer = nil
        store.save(meeting)
        phase = .finished
        Log.write("meeting finished — \(Int(meeting.duration))s, \(meeting.utterances.count) remarks, "
                  + "\(meeting.speakers.count) voice(s)\(meeting.hasAudio ? ", audio kept" : "")")
        onChange()
        onFinished(meeting)
    }
}
