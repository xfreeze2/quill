import SwiftUI
import AppKit

/// The Quill window. The app lives in the menu bar and is a Dock app only while
/// this window is open — close it and Quill goes back to being quiet.
final class MainWindow: NSObject, NSWindowDelegate {

    static let shared = MainWindow()

    private var window: NSWindow?
    private let model = AppModel.shared

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ section: AppModel.Section? = nil) {
        if let section { model.open(section) }
        NSApp.setActivationPolicy(.regular)

        if window == nil { window = makeWindow() }
        guard let window else { return }

        model.startMonitoring()
        Log.write("window shown — \(model.section.title)")
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Quill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RootView(model: model))
        window.setFrameAutosaveName("QuillMainWindow")
        if !window.setFrameUsingName("QuillMainWindow") { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.stopMonitoring()
        // Back to a menu-bar app. A recording keeps going: the icon turns red.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Layout

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 228)
                    .background(
                        SidebarBackground().ignoresSafeArea()
                    )
                Rectangle().fill(Palette.hairline).frame(width: 1).ignoresSafeArea()
                ZStack(alignment: .bottom) {
                    page
                    if let toast = model.toast {
                        ToastView(text: toast)
                            .padding(.bottom, 22)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.toast)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .home:       HomeView(model: model)
        case .history:    HistoryView(model: model)
        case .meetings:   MeetingsView(model: model)
        case .vocabulary: VocabularyView(model: model)
        case .settings:   SettingsView(model: model)
        }
    }
}

/// The sidebar's frosted glass — a flat tint when drawn off screen, where the
/// window server has nothing to blur.
struct SidebarBackground: View {
    static var flat = false

    var body: some View {
        if Self.flat {
            Palette.sunken.background(Palette.canvas)
        } else {
            VisualEffect(material: .sidebar)
        }
    }
}

struct ToastView: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.82)))
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.trigger) private var triggerRaw = Trigger.control.rawValue
    @AppStorage(Defaults.singleTap) private var singleTap = true

    private var trigger: Trigger { Trigger(rawValue: triggerRaw) ?? .control }
    private let top: [AppModel.Section] = [.home, .history, .meetings, .vocabulary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                LogoMark(size: 26)
                Text("Quill").font(.display(21))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(top) { section in
                    SidebarRow(section: section, isSelected: model.section == section,
                               badge: section == .meetings && model.isRecordingMeeting) {
                        model.open(section)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            if let session = model.session, session.isActive {
                RecordingCard(model: model, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            DictateHint(trigger: trigger, singleTap: singleTap)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            SidebarRow(section: .settings, isSelected: model.section == .settings, badge: !model.access.isComplete) {
                model.open(.settings)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }
}

struct SidebarRow: View {
    var section: AppModel.Section
    var isSelected: Bool
    var badge = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14.5, weight: .medium))
                    .frame(width: 22)
                    .foregroundColor(isSelected ? Palette.accent : .secondary)
                Text(section.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? Palette.accentText : .primary)
                Spacer()
                if badge { Circle().fill(Palette.record).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Palette.accentSoft : (hovering ? Palette.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DictateHint: View {
    var trigger: Trigger
    var singleTap: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.accent)
                Text("Dictate anywhere").font(.system(size: 12, weight: .semibold))
            }
            HStack(spacing: 8) {
                Keycap(text: trigger.shortTitle)
                Text(trigger == .f5 ? "Press to start and stop" : (singleTap ? "Tap to start and stop" : "Double-tap to start and stop"))
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }
}

private struct RecordingCard: View {
    @ObservedObject var model: AppModel
    let session: MeetingSession

    var body: some View {
        let _ = model.tick
        Button { model.openMeeting(session.meeting.id) } label: {
            HStack(spacing: 10) {
                PulsingDot()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording").font(.system(size: 12, weight: .semibold))
                    Text(Meeting.clock(session.elapsed))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { model.stopMeeting() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.record))
                }
                .buttonStyle(.plain)
                .help("Stop and write up the notes")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.record.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.record.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The nib mark used in the sidebar.
struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.38, blue: 0.95), Color(red: 0.55, green: 0.33, blue: 0.92)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "waveform")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.36, green: 0.38, blue: 0.95).opacity(0.35), radius: 4, x: 0, y: 2)
    }
}
