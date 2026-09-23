import Cocoa
import QuartzCore

/// Double-tap the trigger: hear what the Mac is playing — or the microphone —
/// show it as it is said, and translate it as it is said.
///
/// One long-lived speech-to-text stream, language auto-detected. Each segment
/// the service hears is translated while it is still being spoken (a draft,
/// refreshed as it grows) and again the moment the service closes it, so a long
/// sentence is readable before the speaker reaches its end.
final class LiveTranslation: NSObject {

    enum Source: String, CaseIterable {
        case system
        case microphone

        var title: String {
            switch self {
            case .system:     return "System audio"
            case .microphone: return "Microphone"
            }
        }
    }

    /// Target languages for the menus, as (name, code).
    var languages: [(String, String)] = []
    /// Menu-bar icon and menu need refreshing.
    var onStateChange: () -> Void = {}

    // Self-test hooks.
    var sourceOverride: (() -> AudioSource)?
    var onSegmentTranslated: ((LiveSegment) -> Void)?
    /// Lets a self-test screenshot its own panel without touching the saved setting.
    var capturableForTest = false
    var panelWindowNumber: Int? { panel.windowNumber }
    func panelSnapshot() -> Data? { panel.snapshotPNG() }
    func setLayoutForTest(_ layout: TranslatorPanel.Layout) { panel.setLayout(layout) }

    private(set) var isRunning = false
    private(set) var lastSessionText: String?

    var segmentCount: Int { transcript.visibleSegments.count }
    /// What the panel shows, in order — for the self-test's summary.
    var shownLines: [(original: String, translation: String)] {
        transcript.visibleSegments.map { ($0.original, $0.sameLanguage ? "=" : $0.translation) }
    }
    var translatedCount: Int { transcript.visibleSegments.filter { $0.translationIsFinal }.count }

    private let panel = TranslatorPanel()
    private let translator = Translator()
    private var transcript = LiveTranscript()
    /// On-device language guesses, by segment.
    private var guesses: [Int: (code: String, confidence: Double)] = [:]
    private var retries: [Int: Int] = [:]
    private var reported: Set<Int> = []

    private var audio: AudioSource?
    private var client: STTClient?
    private var draining: [STTClient] = []
    private var generation = 0
    private var socketOpen = false
    private var socketStartedAt = Date()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var recentFailures: [Date] = []
    private var retryWork: DispatchWorkItem?
    /// What the live socket's auto-detection locked onto with the first speech
    /// it heard. It does not follow a change of language — Japanese on a socket
    /// that locked onto Spanish came back romanised — so a sentence in another
    /// language earns a fresh socket, which detects again.
    private var socketLanguage: String?
    /// Set when a socket was opened for a specific language rather than left
    /// to detect; reconnects and rotations keep it.
    private var socketLanguageChosen: String?
    private var relockReason: String?
    /// Finished sentences in a row spoken in something other than the lock.
    private var offLockStreak = 0
    private var lastRotationAt = Date.distantPast
    private var lastRehearAt = Date.distantPast
    private var lastGapRehearAt = Date.distantPast
    private var gapCooldown: TimeInterval = 30
    /// Set by a gap re-hearing, cleared when its socket produces any words.
    private var gapRehearFoundNothing = false
    private var lastDroppedCheckAt = Date.distantPast
    private var lastSocketMessageAt = Date()
    /// Where the live socket's last transcribed word ended, on its clock.
    private var lastHeardEnd: Double = 0

    /// The live socket's recent audio, so a sentence can be heard again.
    private var sentAudio: [Data] = []
    private var sentBytes = 0
    private var keptFrom = 0
    private static let keepSent = 16_000 * 2 * 40

    private var tick: Timer?
    private var startedAt = Date()
    private var lastLoudAt = Date()
    private var problem: (message: String, action: (title: String, run: () -> Void)?)?
    private var panelWired = false

    /// Twenty seconds of 16 kHz PCM16 — what is held while there is no socket.
    private static let maxPending = 16_000 * 2 * 20

    private var source: Source {
        Source(rawValue: UserDefaults.standard.string(forKey: Defaults.liveSource) ?? "") ?? .system
    }

    private var target: String {
        UserDefaults.standard.string(forKey: Defaults.liveTarget) ?? "en"
    }

    private var layout: TranslatorPanel.Layout {
        TranslatorPanel.Layout(rawValue: UserDefaults.standard.string(forKey: Defaults.liveLayout) ?? "") ?? .both
    }

    // MARK: Start and stop

    @objc func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        wirePanel()

        isRunning = true
        transcript = LiveTranscript()
        guesses = [:]
        retries = [:]
        reported = []
        generation = 0
        pending = []
        pendingBytes = 0
        recentFailures = []
        problem = nil
        startedAt = Date()
        lastLoudAt = Date()
        lastRehearAt = .distantPast
        lastRotationAt = .distantPast
        lastGapRehearAt = .distantPast
        gapCooldown = 30
        gapRehearFoundNothing = false
        lastSocketMessageAt = Date()

        panel.setLayout(layout)
        applyCapturePrivacy()
        panel.setSource(source.title)
        panel.setTarget(LanguageGuess.name(target))
        panel.setHeard(nil)
        panel.setElapsed(0)
        panel.setActivity(.connecting)
        panel.render(originals: [], translations: [])
        refreshNotice()
        panel.show()
        onStateChange()

        guard let creds = Auth.current() else {
            report("No Grok sign-in found — run `grok` once, or add an xAI API key from the menu")
            return
        }
        Log.write("live translation started — source=\(source.rawValue) target=\(target)")
        translator.warm(token: creds.token)
        startAudio()

        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.onTick()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        retryWork?.cancel()
        retryWork = nil
        tick?.invalidate()
        tick = nil
        stopAudio()
        client?.cancel()
        client = nil
        draining.forEach { $0.cancel() }
        draining.removeAll()
        translator.cancelAll()
        pending.removeAll()
        pendingBytes = 0
        if !transcript.segments.isEmpty { lastSessionText = transcript.plainText() }
        panel.hide()
        Log.write("live translation stopped after \(Int(Date().timeIntervalSince(startedAt)))s — "
            + "\(transcript.segments.count) segments")
        onStateChange()
    }

    // MARK: Audio

    private func startAudio() {
        if let sourceOverride {
            begin(sourceOverride())
            return
        }
        switch source {
        case .system:
            guard #available(macOS 14.2, *) else {
                report("Hearing system audio needs macOS 14.2 or newer",
                       action: ("Use the microphone", { [weak self] in self?.switchSource(to: .microphone) }))
                return
            }
            switch SystemAudioPermission.status {
            case .granted:
                beginSystemAudio()
            case .denied:
                reportSystemAudioDenied()
            case .unknown:
                SystemAudioPermission.request { [weak self] granted in
                    guard let self, self.isRunning, self.source == .system, self.audio == nil else { return }
                    granted ? self.beginSystemAudio() : self.reportSystemAudioDenied()
                }
            }
        case .microphone:
            Recorder.micAuthorization { [weak self] granted in
                guard let self, self.isRunning, self.source == .microphone, self.audio == nil else { return }
                guard granted else {
                    self.report("Quill isn't allowed to use the microphone",
                                action: ("Open Settings", { Inserter.openPrivacyPane("Privacy_Microphone") }))
                    return
                }
                self.begin(Recorder())
            }
        }
    }

    private func beginSystemAudio() {
        guard #available(macOS 14.2, *) else { return }
        let capture = SystemAudio()
        capture.onRestart = { [weak self] reason in
            Log.write("live: system audio rebuilt — \(reason)")
            self?.flash(reason == "output device changed" ? "Switched output" : "Reconnected audio")
        }
        begin(capture)
    }

    private func reportSystemAudioDenied() {
        report("Quill isn't allowed to hear system audio. In Settings, turn on Quill under "
               + "\u{201C}System Audio Recording Only\u{201D}.",
               action: ("Open Settings", { SystemAudioPermission.openSettings() }))
    }

    private func begin(_ source: AudioSource) {
        source.onPCM = { [weak self, weak source] data in
            DispatchQueue.main.async {
                guard let self, let source, source === self.audio else { return }
                self.feed(data)
            }
        }
        source.onLevel = { [weak self, weak source] level in
            DispatchQueue.main.async {
                guard let self, let source, source === self.audio else { return }
                self.panel.setLevel(level)
                if level > 0.05 { self.lastLoudAt = Date() }
            }
        }
        audio = source
        do {
            try source.start()
            clearProblem()
            // Only now: the service drops a socket that goes a minute without
            // audio, which is exactly what waiting on a permission prompt did.
            if client == nil, retryWork == nil { openSocket() }
        } catch {
            audio = nil
            Log.write("live: audio failed to start — \(error.localizedDescription)")
            report(error.localizedDescription)
        }
    }

    private func stopAudio() {
        audio?.stop()
        audio = nil
        panel.setLevel(0)
    }

    private func feed(_ data: Data) {
        guard isRunning else { return }
        if socketOpen, let client {
            send(data, to: client)
            return
        }
        pending.append(data)
        pendingBytes += data.count
        while pendingBytes > Self.maxPending, !pending.isEmpty {
            pendingBytes -= pending.removeFirst().count
        }
    }

    /// A socket's clock is the audio it has been sent, so a byte offset into
    /// what it was sent is a time on that clock.
    private func send(_ data: Data, to client: STTClient) {
        client.send(pcm: data)
        sentAudio.append(data)
        sentBytes += data.count
        while sentBytes - keptFrom > Self.keepSent, !sentAudio.isEmpty {
            keptFrom += sentAudio.removeFirst().count
        }
    }

    // MARK: Speech-to-text

    /// `language` nil leaves detection to the service.
    private func openSocket(language: String? = nil) {
        retryWork = nil
        guard isRunning else { return }
        guard let creds = Auth.current() else {
            report("No Grok sign-in found — run `grok` once, or add an xAI API key from the menu")
            return
        }
        let client = STTClient()
        let generation = self.generation
        self.client = client
        socketOpen = false
        socketStartedAt = Date()
        socketLanguage = language
        socketLanguageChosen = language
        relockReason = nil
        offLockStreak = 0
        sentAudio = []
        sentBytes = 0
        keptFrom = 0
        lastHeardEnd = 0
        lastSocketMessageAt = Date()

        client.onReady = { [weak self, weak client] in
            guard let self, let client, client === self.client else { return }
            self.socketOpen = true
            for chunk in self.pending { self.send(chunk, to: client) }
            if !self.pending.isEmpty {
                Log.write("live: socket open, flushed \(self.pendingBytes / 32_000)s of held audio")
            }
            self.pending.removeAll()
            self.pendingBytes = 0
            if self.audio != nil { self.panel.setActivity(.listening) }
        }
        client.onSegment = { [weak self] segment in
            self?.heard(generation: generation, segment)
        }
        client.onFailure = { [weak self, weak client] failure in
            guard let self, let client else { return }
            self.socketEnded(client, generation: generation, failure: failure)
        }
        client.onComplete = { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.socketEnded(client, generation: generation, failure: nil)
        }
        client.connect(token: creds.token, language: language ?? "auto")
    }

    /// A socket finished. A retired one is simply done; the live one dying
    /// means reconnecting — at once the first time, then backing off — while
    /// the audio keeps being held so nothing said in the gap is lost.
    private func socketEnded(_ ended: STTClient, generation: Int, failure: STTClient.Failure?) {
        closeOpenSegments(of: generation)
        guard ended === client else {
            draining.removeAll { $0 === ended }
            return
        }
        guard isRunning else { return }

        client = nil
        socketOpen = false
        self.generation += 1
        Log.write("live: speech-to-text ended — \(failure?.message ?? "closed by the server")")
        if transcript.isReplacing {
            transcript.cancelReplacement()
            render()
        }

        if failure == .unauthorized {
            report(STTClient.Failure.unauthorized.message)
            return
        }

        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        let attempt = recentFailures.count
        let delay: TimeInterval = attempt <= 1 ? 0 : min(10, pow(2, Double(attempt - 1)))
        panel.setActivity(.connecting)
        if attempt >= 3 { flash("Reconnecting…") }

        let language = socketLanguageChosen
        let work = DispatchWorkItem { [weak self] in self?.openSocket(language: language) }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Long calls outlast what one socket should be trusted with. Swap in a new
    /// one during a pause, so no sentence is split between the two; the old one
    /// is told the audio is done and finishes what it was transcribing.
    private func rotateSocket(reason: String, language: String?) {
        guard let old = client, socketOpen else { return }
        Log.write("live: new speech-to-text socket — \(reason)")
        draining.append(old)
        old.doneGrace = 6
        old.finish()
        client = nil
        generation += 1
        lastRotationAt = Date()
        openSocket(language: language)
    }

    /// Checked once a sentence is translated, against two measured failures.
    ///
    /// Words written in a different language from the one spoken — Japanese
    /// written out in Latin letters, or as Spanish-sounding nonsense, by a socket
    /// that had locked onto Spanish — are wrong, so that sentence is heard again
    /// by a socket set to the language it was spoken in. The on-device detector
    /// reads the script; the translator recognises the speech behind it.
    ///
    /// A plain change of language usually transcribes fine — English followed by
    /// Spanish or Japanese both came back right — so there the words are left
    /// alone and a fresh, auto-detecting socket takes over at the next pause.
    ///
    /// Both need a real sentence. In an 18-minute Vietnamese call with English
    /// words mixed in, single short phrases tripped these every few minutes.
    private func checkLanguage(of id: Int, spoken: String?) {
        guard let spoken, let segment = transcript.segment(id), segment.generation == generation,
              segment.wordCount >= 3 else { return }
        let locked = socketLanguage ?? "auto"

        if let written = guesses[id], written.confidence >= 0.6, written.code != spoken,
           languages.contains(where: { $0.1 == spoken }), let start = segment.audioStart,
           rehear(from: start - 0.3, replacing: id, language: spoken,
                  reason: "spoken \(spoken), written as \(written.code)") {
            offLockStreak = 0
            return
        }
        guard locked != "auto", spoken != locked else {
            offLockStreak = 0
            return
        }
        offLockStreak += 1
        guard offLockStreak >= 2, relockReason == nil else { return }
        relockReason = "\(offLockStreak) sentences of \(spoken) on a socket locked to \(locked)"
    }

    /// Send the live socket's audio from `start` (its clock) on to a new socket,
    /// which takes over; the sentences from `id` on give way once it answers.
    /// `language` nil lets the new socket detect for itself.
    private func rehear(from start: Double, replacing id: Int?, language: String?, reason: String) -> Bool {
        guard socketOpen, let old = client, Date().timeIntervalSince(lastRehearAt) > 15 else { return false }
        let from = max(0, Int(start * 32_000)) & ~1
        guard from >= keptFrom, from < sentBytes else { return false }

        let replay = sentSlices(from: from, to: sentBytes)
        let bytes = replay.reduce(0) { $0 + $1.count }
        let marked = id.map { transcript.markReplacing(from: $0) } ?? []
        Log.write("live: hearing \(String(format: "%.1f", Double(bytes) / 32_000))s again as \(language ?? "auto") — "
            + "\(reason); \(marked.count) sentence(s) replaced")

        // Everything it heard from that sentence on is replayed, so nothing it
        // still has to say is needed.
        old.cancel()
        client = nil
        generation += 1
        lastRehearAt = Date()
        lastRotationAt = Date()
        pending = replay + pending
        pendingBytes += bytes
        openSocket(language: language)
        return true
    }

    /// The part of what the live socket was sent between two byte offsets.
    private func sentSlices(from: Int, to: Int) -> [Data] {
        var out: [Data] = []
        var offset = keptFrom
        for chunk in sentAudio {
            let end = offset + chunk.count
            defer { offset = end }
            guard end > from, offset < to else { continue }
            let lower = max(from, offset) - offset
            let upper = min(to, end) - offset
            out.append(lower == 0 && upper == chunk.count ? chunk : chunk.subdata(in: lower..<upper))
        }
        return out
    }

    /// Seconds of speech-level sound between two points on the live socket's
    /// clock, judged in 100 ms frames.
    private func speechSeconds(from start: Double, to end: Double) -> Double {
        let from = max(keptFrom, Int(start * 32_000) & ~1)
        let to = min(sentBytes, Int(end * 32_000) & ~1)
        guard to > from else { return 0 }
        var audio = Data()
        sentSlices(from: from, to: to).forEach { audio.append($0) }
        var loudFrames = 0
        audio.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var index = 0
            while index + 1600 <= samples.count {
                var sum: Float = 0
                for i in index..<(index + 1600) {
                    let v = Float(samples[i]) / 32_768
                    sum += v * v
                }
                if sqrt(sum / 1600) > 0.015 { loudFrames += 1 }
                index += 1600
            }
        }
        return Double(loudFrames) * 0.1
    }

    /// Speech the socket heard and never wrote down at all: seconds of sound
    /// between the last transcribed word and this chunk's first. A socket that
    /// had locked onto Spanish did exactly this with a Japanese sentence — a
    /// draft of "Hashtag OK.", retracted, then nothing. The gap and this chunk
    /// go to a fresh, auto-detecting socket.
    private func checkForUnheardSpeech(before segment: STTClient.Segment, id: Int) {
        let previousEnd = lastHeardEnd
        if let end = segment.lastWordEnd { lastHeardEnd = max(lastHeardEnd, end) }
        guard let first = segment.firstWordAt, first - previousEnd >= 3, gapRehearAllowed else { return }
        let speech = speechSeconds(from: previousEnd, to: first)
        // Measured: the sentences a socket actually dropped left 3–6 s of sound;
        // fillers, laughter and crosstalk in a real call left under 2 s.
        guard speech >= 2.5 else { return }
        rehearGap(from: previousEnd, replacing: id,
                  reason: String(format: "%.1fs of sound before it was never transcribed", speech))
    }

    /// The same, for speech at the end with nothing after it to reveal the gap:
    /// sound was heard, then quiet, the socket has said nothing since, and none
    /// of it was written down. A socket that locked onto Spanish dropped a whole
    /// English sentence this way.
    private func checkForDroppedSpeech() {
        guard socketOpen, gapRehearAllowed,
              Date().timeIntervalSince(lastLoudAt) > 2.5,
              Date().timeIntervalSince(lastSocketMessageAt) > 2.5,
              Date().timeIntervalSince(lastDroppedCheckAt) > 1 else { return }
        lastDroppedCheckAt = Date()
        let speech = speechSeconds(from: lastHeardEnd, to: Double(sentBytes) / 32_000)
        guard speech >= 2.2 else { return }
        rehearGap(from: lastHeardEnd, replacing: transcript.openSegment(generation: generation),
                  reason: String(format: "%.1fs of sound at the end was never transcribed", speech))
    }

    /// Music and noise look like speech to a level meter, and re-hearing them
    /// finds nothing. Each re-hearing that finds nothing doubles the wait
    /// before the next; one that recovers words resets it.
    private var gapRehearAllowed: Bool {
        Date().timeIntervalSince(lastGapRehearAt) > gapCooldown
    }

    private func rehearGap(from start: Double, replacing id: Int?, reason: String) {
        guard rehear(from: max(0, start - 0.2), replacing: id, language: nil, reason: reason) else { return }
        if gapRehearFoundNothing { gapCooldown = min(240, gapCooldown * 2) }
        gapRehearFoundNothing = true
        lastGapRehearAt = Date()
    }

    private func closeOpenSegments(of generation: Int) {
        let closed = transcript.finaliseOpen(generation: generation)
        guard !closed.isEmpty else { return }
        closed.forEach(considerTranslation)
        render()
    }

    // MARK: Segments

    private let traceSegments = ProcessInfo.processInfo.environment["QUILL_TRACE_LIVE"] != nil

    private func heard(generation: Int, _ segment: STTClient.Segment) {
        let kind: LiveTranscript.Kind = !segment.isFinal ? .interim
            : (segment.speechFinal ? .utteranceFinal : .chunkFinal)
        if traceSegments {
            FileHandle.standardError.write(Data("  seg g\(generation) \(kind) [\(segment.language ?? "-")] \(segment.text)\n".utf8))
        }
        if generation == self.generation {
            lastSocketMessageAt = Date()
            if let language = segment.language { socketLanguage = LanguageGuess.base(language) }
            if gapRehearFoundNothing, !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
                gapRehearFoundNothing = false
                gapCooldown = 30
            }
        }
        guard isRunning else { return }
        // The socket hearing a sentence again has started answering; the words
        // it is replacing give way.
        if generation == self.generation, transcript.isReplacing,
           !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript.commitReplacement()
        }
        guard let update = transcript.apply(generation: generation, text: segment.text, kind: kind,
                                            audioStart: segment.firstWordAt)
        else { return }
        if kind == .chunkFinal, generation == self.generation {
            checkForUnheardSpeech(before: segment, id: update.id)
            guard generation == self.generation else {
                render()
                return
            }
        }
        if update.textChanged, let segment = transcript.segment(update.id),
           let guess = LanguageGuess.detect(segment.original) {
            guesses[update.id] = guess
        }
        considerTranslation(update.id)
        render()
    }

    private func isTargetLanguage(_ id: Int, strict: Bool) -> Bool {
        guard let guess = guesses[id] else { return false }
        return guess.code == LanguageGuess.base(target) && guess.confidence >= (strict ? 0.85 : 0.6)
    }

    private func considerTranslation(_ id: Int) {
        guard isRunning, let segment = transcript.segment(id), !segment.sameLanguage else { return }

        // Already in the language being translated into: show it as it is.
        if isTargetLanguage(id, strict: true), segment.wordCount >= 3 {
            guard segment.isFinal else { return }
            transcript.markSameLanguage(id, language: LanguageGuess.base(target))
            if let done = transcript.segment(id) { announce(done) }
            checkLanguage(of: id, spoken: LanguageGuess.base(target))
            return
        }

        guard let request = transcript.request(for: id, now: CACurrentMediaTime()),
              let token = Auth.current()?.token else { return }
        translator.translate(request, into: target, token: token)
    }

    private func received(_ delta: Translator.Delta) {
        guard isRunning,
              transcript.receive(id: delta.id, revision: delta.revision, text: delta.text,
                                 language: delta.language, done: delta.done)
        else { return }
        if delta.done, let segment = transcript.segment(delta.id), segment.translationIsFinal {
            retries[delta.id] = nil
            announce(segment)
            checkLanguage(of: segment.id, spoken: segment.language)
        }
        render()
    }

    private func translationFailed(id: Int, revision: Int, message: String, unauthorized: Bool) {
        guard isRunning else { return }
        transcript.requestFailed(id: id, revision: revision)
        if unauthorized {
            report("Grok session expired — open Grok Build once to refresh")
            return
        }
        let attempts = (retries[id] ?? 0) + 1
        retries[id] = attempts
        guard attempts <= 2 else {
            flash("Translation unavailable")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempts)) { [weak self] in
            self?.considerTranslation(id)
        }
    }

    private func announce(_ segment: LiveSegment) {
        guard !reported.contains(segment.id) else { return }
        reported.insert(segment.id)
        onSegmentTranslated?(segment)
    }

    // MARK: Timing

    private func onTick() {
        guard isRunning else { return }
        panel.setElapsed(Date().timeIntervalSince(startedAt))

        // Partials can pause mid-sentence while the service works; the draft
        // should not wait for the next one to arrive.
        if let last = transcript.segments.last, !last.isFinal {
            considerTranslation(last.id)
        }

        guard socketOpen else { return }
        checkForDroppedSpeech()
        guard socketOpen else { return }
        let age = Date().timeIntervalSince(socketStartedAt)
        let wantsRelock = relockReason != nil && Date().timeIntervalSince(lastRotationAt) > 12
        guard wantsRelock || age > 270 else { return }

        if wantsRelock, let reason = relockReason, isBetweenSentences {
            rotateSocket(reason: reason, language: nil)
        } else if age > 270, isBetweenSentences, Date().timeIntervalSince(lastLoudAt) > 1.0 {
            rotateSocket(reason: "\(Int(age))s old, pause in speech", language: socketLanguageChosen)
        } else if age > 540 {
            rotateSocket(reason: "\(Int(age))s old, no pause came", language: socketLanguageChosen)
        }
    }

    /// Everything the live socket has heard is written down: no sentence open,
    /// and no speech-level sound after its last transcribed word. Swapping
    /// sockets any earlier strands the words in between on the old one.
    private var isBetweenSentences: Bool {
        guard !transcript.hasOpenSegment(generation: generation) else { return false }
        let now = Double(sentBytes) / 32_000
        return speechSeconds(from: lastHeardEnd, to: now) < 0.3
    }

    // MARK: Panel

    private func render() {
        let segments = transcript.visibleSegments.suffix(60)
        let lastID = segments.last?.id

        let originals = segments.map {
            TranslatorPanel.Line(text: $0.original, isCurrent: $0.id == lastID, isDraft: !$0.isFinal)
        }

        var translations: [TranslatorPanel.Line] = []
        for segment in segments {
            var text = segment.translation
            var draft = !segment.translationIsFinal
            if text.isEmpty, isTargetLanguage(segment.id, strict: false) {
                text = segment.original
                draft = !segment.isFinal
            }
            if text.isEmpty, segment.isFinal { text = "…" }
            guard !text.isEmpty else { continue }
            translations.append(TranslatorPanel.Line(text: text, isCurrent: false, isDraft: draft))
        }
        if let last = translations.popLast() {
            translations.append(TranslatorPanel.Line(text: last.text, isCurrent: true, isDraft: last.isDraft))
        }
        panel.render(originals: originals, translations: translations)

        // A two-word draft the service is about to retract ("Hashtag OK.") is
        // not evidence of anything; only the translator's reading, or a confident
        // guess from a real sentence, names the language.
        let heard = segments.reversed().lazy.compactMap { segment -> String? in
            if let language = segment.language { return language }
            guard let guess = self.guesses[segment.id], guess.confidence >= 0.8, segment.wordCount >= 3 else { return nil }
            return guess.code
        }.first
        panel.setHeard(heard.map(LanguageGuess.name))
        refreshNotice()
    }

    private func report(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        Log.write("live: \(message)")
        problem = (message, action)
        panel.setActivity(.stopped)
        refreshNotice()
    }

    private func clearProblem() {
        problem = nil
        panel.setActivity(socketOpen ? .listening : .connecting)
        refreshNotice()
    }

    private func refreshNotice() {
        if let problem {
            panel.setNotice(problem.message, action: problem.action)
        } else if transcript.segments.isEmpty {
            let hint = source == .system
                ? "Listening to everything your Mac plays — a call, a video. Speech shows up here as it is said."
                : "Listening to the microphone. Speech shows up here as it is said."
            panel.setNotice(hint)
        } else {
            panel.setNotice(nil)
        }
    }

    private func flash(_ message: String) {
        panel.flash(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.panel.setSource(self.source.title)
        }
    }

    private func wirePanel() {
        guard !panelWired else { return }
        panelWired = true

        translator.onDelta = { [weak self] delta in self?.received(delta) }
        translator.onFailure = { [weak self] id, revision, message, unauthorized in
            self?.translationFailed(id: id, revision: revision, message: message, unauthorized: unauthorized)
        }

        panel.onClose = { [weak self] in self?.stop() }
        panel.onCopy = { [weak self] in self?.copySession() }
        panel.onToggleLayout = { [weak self] in self?.toggleLayout() }
        panel.sourceMenu = { [weak self] in self?.sourceMenu() ?? NSMenu() }
        panel.targetMenu = { [weak self] in self?.targetMenu() ?? NSMenu() }
    }

    // MARK: Choices

    func sourceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in Source.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(pickSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == source ? .on : .off
            if option == .system {
                item.toolTip = "Everything your Mac plays: calls, videos, browser tabs"
            }
            menu.addItem(item)
        }
        return menu
    }

    func targetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (name, code) in languages {
            let item = NSMenuItem(title: name, action: #selector(pickTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = code == target ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = Source(rawValue: raw) else { return }
        switchSource(to: option)
    }

    @objc private func pickTarget(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        setTarget(code)
    }

    func switchSource(to option: Source) {
        UserDefaults.standard.set(option.rawValue, forKey: Defaults.liveSource)
        panel.setSource(option.title)
        guard isRunning else { return }
        Log.write("live: listening to \(option.rawValue)")
        stopAudio()
        problem = nil
        refreshNotice()
        startAudio()
    }

    func setTarget(_ code: String) {
        let changed = code != target
        UserDefaults.standard.set(code, forKey: Defaults.liveTarget)
        panel.setTarget(LanguageGuess.name(code))
        guard isRunning, changed else { return }
        Log.write("live: translating into \(code)")
        for id in transcript.invalidateTranslations(last: 2) {
            reported.remove(id)
            considerTranslation(id)
        }
        render()
    }

    @objc func toggleLayout() {
        let next: TranslatorPanel.Layout = layout == .both ? .translationOnly : .both
        UserDefaults.standard.set(next.rawValue, forKey: Defaults.liveLayout)
        panel.setLayout(next)
    }

    func applyCapturePrivacy() {
        panel.setHiddenFromCapture(Defaults.bool(Defaults.liveHideFromCapture) && !capturableForTest)
    }

    private func copySession() {
        let text = transcript.plainText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied")
    }

    func copyLastSession() {
        let text = isRunning ? transcript.plainText() : (lastSessionText ?? "")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Self-test source

/// Plays a 16 kHz mono PCM16 file into live translation at real-time speed, so
/// the socket → transcript → translation path can be checked without a call.
final class PCMFileSource: AudioSource {

    var onPCM: (Data) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    var onFinished: () -> Void = {}

    private let pcm: Data
    private var offset = 0
    private var timer: Timer?

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        pcm = data
    }

    var seconds: Int { pcm.count / 32_000 }

    func start() throws {
        let chunk = 3_200    // 100 ms
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.offset < self.pcm.count else {
                timer.invalidate()
                self.onFinished()
                return
            }
            let end = min(self.offset + chunk, self.pcm.count)
            let slice = self.pcm.subdata(in: self.offset..<end)
            self.offset = end
            self.onLevel(Self.level(of: slice))
            self.onPCM(slice)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private static func level(of data: Data) -> Float {
        data.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for s in samples {
                let v = Float(s) / 32_768
                sum += v * v
            }
            return min(1, sqrt(sum / Float(samples.count)) * 14)
        }
    }
}
