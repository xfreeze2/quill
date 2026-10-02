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
            SpeakerAvatar(id: turn.speaker, name: meeting.name(for: turn.speaker), size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    nameView
                    timeView
                }
                Text(turn.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isPlaying ? Palette.accentSoft : Color.clear))
        .padding(.horizontal, -8)
    }

    @ViewBuilder private var nameView: some View {
        let name = meeting.name(for: turn.speaker)
        if let onRename {
            Button {
                draft = meeting.hasCustomName(turn.speaker) ? name : ""
                renaming = true
            } label: {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.voice(turn.speaker))
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
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.voice(turn.speaker))
        }
    }

    @ViewBuilder private var timeView: some View {
        if canSeek {
            Button { onSeek(turn.start) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 7.5))
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

private struct RenameVoice: View {
    var defaultName: String
    @Binding var draft: String
    var done: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?").font(.system(size: 13, weight: .semibold))
            Text("Give the voice a name and every remark by it is updated. Give two voices the same name to join them.")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(defaultName, text: $draft, onCommit: { done(draft) })
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Reset") { done("") }.buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Done") { done(draft) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 270)
    }
}

/// What is being said this moment, not yet final.
struct LiveTurnRow: View {
    var meeting: Meeting
    var line: LiveLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(id: line.speaker, name: meeting.name(for: line.speaker), size: 30)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meeting.name(for: line.speaker)).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.voice(line.speaker).opacity(0.8))
                    Text("speaking…").font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Text(line.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// A banner for something the person should know.
struct Notice: View {
    var text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = Palette.caution

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(tint)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.28), lineWidth: 1))
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

struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.accent))
            }
            .buttonStyle(.plain)

            Text(Meeting.clock(player.position)).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                   in: 0...max(1, player.duration))
            Text(Meeting.clock(player.duration)).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)

            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : (player.rate == 1.5 ? "1.5×" : "2×"))
                    .font(.system(size: 12, weight: .semibold)).frame(width: 34)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Playback speed")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }
}
