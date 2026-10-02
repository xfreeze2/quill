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
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Quill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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
                    .frame(width: 196)
                    .background(SidebarBackground().ignoresSafeArea())
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
        case .meetings:  MeetingsView(model: model)
        case .dictation: DictationView(model: model)
        case .translate: TranslateView(model: model)
        case .settings:  SettingsView(model: model)
        }
    }
}

/// The sidebar's frosted glass — a flat tint when drawn off screen, where the
/// window server has nothing to blur.
struct SidebarBackground: View {
    static var flat = false

    var body: some View {
        if Self.flat {
            Palette.panel
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
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.black.opacity(0.82)))
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    private let top: [AppModel.Section] = [.meetings, .dictation, .translate]

    /// The recording is already on screen, so the sidebar needn't repeat it.
    private func watching(_ session: MeetingSession) -> Bool {
        model.section == .meetings && !model.composingMeeting && model.selectedMeetingID == session.meeting.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: Layout.titlebar + 8)

            VStack(spacing: 2) {
                ForEach(top) { section in
                    SidebarRow(section: section, isSelected: model.section == section,
                               badge: section == .translate && model.liveRunning ? Palette.positive : nil) {
                        model.open(section)
                    }
                }
            }

            Spacer(minLength: 12)

            if let session = model.session, session.isActive, !watching(session) {
                RecordingPill(model: model, session: session)
                    .padding(.bottom, 8)
            }

            SidebarRow(section: .settings, isSelected: model.section == .settings,
                       badge: model.access.isComplete ? nil : Palette.caution) {
                model.open(.settings)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }
}

struct SidebarRow: View {
    var section: AppModel.Section
    var isSelected: Bool
    var badge: Color? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13.5, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(isSelected ? .primary : .secondary)
                Text(section.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                Spacer()
                if let badge { Circle().fill(badge).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecordingPill: View {
    @ObservedObject var model: AppModel
    let session: MeetingSession

    var body: some View {
        let _ = model.tick
        HStack(spacing: 9) {
            PulsingDot()
            Text(Meeting.clock(session.elapsed))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            Spacer()
            Button { model.stopMeeting() } label: {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.record))
            }
            .buttonStyle(.plain)
            .help("Stop and write up the notes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.record.opacity(0.10)))
        .contentShape(Rectangle())
        .onTapGesture { model.openMeeting(session.meeting.id) }
    }
}
