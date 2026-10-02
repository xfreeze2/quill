import SwiftUI
import AVFoundation

// Pieces shared by the live view and the finished meeting.

/// One person's turn at talking.
struct TurnRow: View {
    var meeting: Meeting
    var turn: Meeting.Turn
    var isPlaying = false
    var canSeek = false
    var onSeek: (Double) -> Void = { _ in }
    /// Passing this makes the name clickable, to give the voice a real name.
    var onRename: ((String) -> Void)? = nil

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(id: turn.speaker, name: meeting.name(for: turn.speaker), size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    nameView
                    timeView
                }
                Text(turn.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isPlaying ? Palette.accentSoft : Color.clear))
        .padding(.horizontal, -10)
    }

    @ViewBuilder private var nameView: some View {
        let name = meeting.name(for: turn.speaker)
        if let onRename {
            Button {
                draft = meeting.hasCustomName(turn.speaker) ? name : ""
                renaming = true
            } label: {
                Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Palette.voice(turn.speaker))
            }
            .buttonStyle(.plain)
            .help("Rename this voice")
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                RenameVoice(defaultName: Meeting.defaultName(for: turn.speaker), draft: $draft) { final in
                    onRename(final)
                    renaming = false
                }
            }
        } else {
            Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Palette.voice(turn.speaker))
        }
    }

    @ViewBuilder private var timeView: some View {
        if canSeek {
            Button { onSeek(turn.start) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 7))
                    Text(Meeting.clock(turn.start)).font(.system(size: 11.5).monospacedDigit())
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Play from here")
        } else {
            Text(Meeting.clock(turn.start)).font(.system(size: 11.5).monospacedDigit()).foregroundColor(.secondary)
        }
    }
}

/// What is being said this moment, not yet final.
struct LiveTurnRow: View {
    var meeting: Meeting
    var line: LiveLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(id: line.speaker, name: meeting.name(for: line.speaker), size: 26)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.name(for: line.speaker)).font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Palette.voice(line.speaker).opacity(0.8))
                Text(line.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

/// Something the person should know.
struct Notice: View {
    var text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = Palette.caution

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(tint).padding(.top, 1)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
    }
}

// MARK: - Playback

/// Plays back the kept recording, and tells the transcript where it is.
final class MeetingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var rate: Float = 1

    let duration: Double
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL?) {
        if let url, let player = try? AVAudioPlayer(contentsOf: url) {
            self.player = player
            duration = player.duration
        } else {
            duration = 0
        }
        super.init()
        player?.delegate = self
        player?.enableRate = true
        player?.prepareToPlay()
    }

    deinit { stop() }

    var isReady: Bool { player != nil }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { play() }
    }

    func play(from time: Double? = nil) {
        guard let player else { return }
        if let time { player.currentTime = max(0, min(duration, time)) }
        player.rate = rate
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.position = player.currentTime
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, time))
        position = player.currentTime
    }

    func cycleRate() {
        rate = rate < 1.25 ? 1.5 : (rate < 1.75 ? 2 : 1)
        if player?.isPlaying == true { player?.rate = rate }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.timer?.invalidate()
            self?.timer = nil
            self?.position = 0
            player.currentTime = 0
        }
    }
}

// MARK: - Asking

/// The back-and-forth with one meeting. Kept while the meeting is open.
final class AskThread: ObservableObject {

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: String?
        var failure: String?
    }

    @Published private(set) var exchanges: [Exchange] = []
    @Published private(set) var busy = false

    func ask(_ question: String, about meeting: Meeting) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        let exchange = Exchange(question: trimmed)
        exchanges.append(exchange)
        busy = true
        MeetingSummarizer.chat(system: MeetingAsk.system, user: MeetingAsk.user(meeting: meeting, question: trimmed),
                               maxTokens: 1_200) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, let index = self.exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
                self.busy = false
                switch result {
                case .success(let text):
                    self.exchanges[index].answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .failure(let failure):
                    self.exchanges[index].failure = failure.message
                }
            }
        }
    }

    func clear() {
        exchanges = []
    }
}
