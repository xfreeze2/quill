import SwiftUI

/// Live translation: listen to speech on the Mac and show it in your language,
/// in a small window that floats over everything.
struct TranslateView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.singleTap) private var singleTap = true
    @AppStorage(Defaults.trigger) private var triggerRaw = Trigger.control.rawValue
    @AppStorage(Defaults.liveTarget) private var target = "en"
    @AppStorage(Defaults.liveSource) private var source = "system"
    @AppStorage(Defaults.liveLayout) private var layout = "both"
    @AppStorage(Defaults.liveHideFromCapture) private var hide = true
    @AppStorage(Defaults.liveDoubleTap) private var doubleTap = true

    private var trigger: Trigger { Trigger(rawValue: triggerRaw) ?? .control }
    private var running: Bool { model.liveRunning }
    private var translationOnly: Bool { layout == TranslatorPanel.Layout.translationOnly.rawValue }
    private var targetName: String { Languages.all.first { $0.1 == target }?.0 ?? "English" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(symbol: "captions.bubble.fill", tile: .teal, title: "Live translation",
                           subtitle: "Translates what your Mac plays, as it's said.")

                HStack(alignment: .top, spacing: 16) {
                    controls
                        .frame(width: 340)
                    VStack(spacing: 14) {
                        preview
                        uses
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, Layout.titlebar - 4)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(PageGround(tint: .teal))
    }

    // MARK: Controls

    private var controls: some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { model.bridge.toggleLive() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                            Text(running ? "Stop" : "Start")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: running ? Palette.record : Palette.accent, large: true))
                    if running {
                        HStack(spacing: 7) {
                            PulsingDot(tint: Palette.positive, size: 7)
                            Text("Translating").font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    } else if singleTap && doubleTap {
                        HStack(spacing: 5) {
                            Text("or double-tap").foregroundColor(.secondary)
                            Keycap(text: trigger.shortTitle)
                        }
                        .font(.system(size: 12.5))
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)

                RowDivider()

                VStack(spacing: 0) {
                    SettingRow("Translate into") {
                        Picker("", selection: $target) {
                            ForEach(Languages.all.filter { $0.1 != "auto" }, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    RowDivider()
                    SettingRow("Listen to") {
                        Picker("", selection: $source) {
                            Text("The Mac's sound").tag("system")
                            Text("Microphone").tag("microphone")
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    RowDivider()
                    SettingRow("Only the translation") {
                        Toggle("", isOn: Binding(
                            get: { translationOnly },
                            set: { layout = $0 ? TranslatorPanel.Layout.translationOnly.rawValue : TranslatorPanel.Layout.both.rawValue }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingRow("Hide from screen sharing", detail: "Keeps the window out of shares and recordings.") {
                        Toggle("", isOn: $hide).toggleStyle(.switch).labelsHidden()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Preview

    private static let samples: [String: String] = [
        "en": "Hello, how are you today?",
        "es": "Hola, ¿cómo estás hoy?",
        "fr": "Bonjour, comment allez-vous aujourd'hui ?",
        "de": "Hallo, wie geht es Ihnen heute?",
        "it": "Ciao, come stai oggi?",
        "pt": "Olá, como você está hoje?",
        "ja": "こんにちは、今日はお元気ですか？",
        "ko": "안녕하세요, 오늘 어떠세요?",
        "zh": "你好，你今天好吗？",
        "hi": "नमस्ते, आप आज कैसे हैं?",
        "ru": "Здравствуйте, как вы сегодня?",
        "nl": "Hallo, hoe gaat het vandaag?",
        "tr": "Merhaba, bugün nasılsınız?",
        "ar": "مرحباً، كيف حالك اليوم؟",
    ]

    /// A stand-in for the floating window, drawn over a stand-in for the video it
    /// would be sitting on.
    private var preview: some View {
        let said = target == "fr" ? Self.samples["es"]! : Self.samples["fr"]!
        let shown = Self.samples[target] ?? Self.samples["en"]!
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Tile.teal.bottom.opacity(0.9), Tile.sky.bottom.opacity(0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 54)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.positive).frame(width: 6, height: 6)
                        Text(targetName.uppercased())
                            .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    if !translationOnly {
                        Text(said)
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Text(shown)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.74)))
                .padding(12)
            }
            .frame(height: 188)
            Text("This is the window you'll see, floating over whatever is playing.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var uses: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                use("play.rectangle.fill", .coral, "Videos and livestreams", "In any language, in any app or browser.")
                use("video.fill", .indigo, "Calls with people who speak another language", "Quill hears the call and writes it in yours.")
            }
        }
    }

    private func use(_ symbol: String, _ tile: Tile, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            IconTile(symbol: symbol, tile: tile, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
