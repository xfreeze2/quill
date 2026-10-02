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

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live translation").font(.system(size: 26, weight: .semibold))
                    Text("Watching a video or on a call in another language? Quill translates what it hears as it's said.")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
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
                    }
                    Spacer()
                }

                VStack(spacing: 0) {
                    RowDivider()
                    SettingRow("Translate into") {
                        Picker("", selection: $target) {
                            ForEach(Languages.all.filter { $0.1 != "auto" }, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    RowDivider()
                    SettingRow("Listen to") {
                        Picker("", selection: $source) {
                            Text("Everything the Mac plays").tag("system")
                            Text("Microphone").tag("microphone")
                        }
                        .labelsHidden().frame(width: 190)
                    }
                    RowDivider()
                    SettingRow("Show only the translation") {
                        Toggle("", isOn: Binding(
                            get: { layout == TranslatorPanel.Layout.translationOnly.rawValue },
                            set: { layout = $0 ? TranslatorPanel.Layout.translationOnly.rawValue : TranslatorPanel.Layout.both.rawValue }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingRow("Hide from screen sharing", detail: "Keeps the window out of shares and recordings.") {
                        Toggle("", isOn: $hide).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                }

                if singleTap && doubleTap {
                    HStack(spacing: 6) {
                        Text("Or double-tap").foregroundColor(.secondary)
                        Keycap(text: trigger.shortTitle)
                        Text("anywhere to start and stop.").foregroundColor(.secondary)
                    }
                    .font(.system(size: 12.5))
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.horizontal, 40)
            Spacer(minLength: 24)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
