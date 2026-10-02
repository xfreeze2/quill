import SwiftUI
import AppKit

// The look of the Quill window.
//
// Few rules, held everywhere:
//   • Content is the interface. Notes and lists are laid out like a page, not
//     stacked in boxes.
//   • One accent colour, for the one thing to press and for what is selected.
//     Everything else is neutral; colour is kept for people (speakers) and for
//     the red of a recording.
//   • System type at a small set of sizes: 12 for detail, 13–14 for reading,
//     15 for headings, 22 for a page, 28 for a note's title.
//   • Hairlines, not shadows. Two corner radii: 8 for controls, 12 for panels.

enum Palette {

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let accent = dynamic(light: rgb(0.31, 0.29, 0.90), dark: rgb(0.62, 0.62, 1.00))
    static let accentSoft = dynamic(light: rgb(0.31, 0.29, 0.90, 0.09), dark: rgb(0.62, 0.62, 1.00, 0.16))
    static let accentText = dynamic(light: rgb(0.27, 0.25, 0.78), dark: rgb(0.72, 0.72, 1.00))

    /// Where notes and lists are read.
    static let canvas = dynamic(light: rgb(1, 1, 1), dark: rgb(0.118, 0.118, 0.125))
    /// The list beside a note, and the sidebar's flat stand-in.
    static let panel = dynamic(light: rgb(0.968, 0.968, 0.974), dark: rgb(0.145, 0.145, 0.155))
    /// Fields and menus.
    static let surface = dynamic(light: rgb(1, 1, 1), dark: rgb(0.19, 0.19, 0.205))
    /// Wells: a search box, a text area, a chart's ground.
    static let sunken = dynamic(light: rgb(0, 0, 0, 0.04), dark: rgb(1, 1, 1, 0.06))
    static let hover = dynamic(light: rgb(0, 0, 0, 0.05), dark: rgb(1, 1, 1, 0.075))
    static let selected = dynamic(light: rgb(0, 0, 0, 0.075), dark: rgb(1, 1, 1, 0.11))
    static let hairline = dynamic(light: rgb(0, 0, 0, 0.08), dark: rgb(1, 1, 1, 0.10))

    static let record = dynamic(light: rgb(0.89, 0.22, 0.24), dark: rgb(1.0, 0.40, 0.42))
    static let positive = dynamic(light: rgb(0.13, 0.58, 0.36), dark: rgb(0.36, 0.80, 0.55))
    static let caution = dynamic(light: rgb(0.80, 0.50, 0.08), dark: rgb(0.98, 0.72, 0.30))

    /// One colour per voice, stable for the whole meeting. "You" is always the accent.
    private static let voices: [Color] = [
        dynamic(light: rgb(0.86, 0.38, 0.30), dark: rgb(1.00, 0.55, 0.47)),   // coral
        dynamic(light: rgb(0.13, 0.58, 0.50), dark: rgb(0.36, 0.82, 0.72)),   // teal
        dynamic(light: rgb(0.78, 0.52, 0.10), dark: rgb(0.98, 0.76, 0.35)),   // amber
        dynamic(light: rgb(0.74, 0.32, 0.62), dark: rgb(0.95, 0.52, 0.84)),   // orchid
        dynamic(light: rgb(0.20, 0.55, 0.82), dark: rgb(0.45, 0.76, 1.00)),   // sky
        dynamic(light: rgb(0.46, 0.60, 0.20), dark: rgb(0.70, 0.86, 0.40)),   // moss
        dynamic(light: rgb(0.55, 0.45, 0.80), dark: rgb(0.76, 0.68, 1.00)),   // lilac
    ]

    static func voice(_ id: String) -> Color {
        if id == "you" { return accent }
        if id.hasPrefix("s"), let n = Int(id.dropFirst()) { return voices[n % voices.count] }
        return Color.gray
    }
}

enum Layout {
    /// The strip at the top of the window where the traffic lights sit.
    static let titlebar: CGFloat = 40
    /// Widest a column of reading is allowed to get.
    static let reading: CGFloat = 720
}

extension Font {
    /// A page's or a note's title.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Surfaces

/// A quiet box for the few things that need one: an answer, a form.
struct Card<Content: View>: View {
    var padding: CGFloat
    var radius: CGFloat
    let content: Content

    init(padding: CGFloat = 16, radius: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.sunken))
    }
}

/// A vibrancy background — the sidebar's frosted material.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 10 : 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35))
            )
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Palette.selected : Palette.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Text-only, with a soft fill on hover. For the quiet actions on a row.
struct GhostButtonStyle: ButtonStyle {
    var tint: Color? = nil
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(tint ?? .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed || hovering ? Palette.hover : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isPressed || hovering ? Palette.hover : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Small pieces

/// Tabs as plain words with a line under the chosen one.
struct TabStrip<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String

    var body: some View {
        HStack(alignment: .bottom, spacing: 22) {
            ForEach(tabs, id: \.self) { tab in
                let isSelected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 8) {
                        Text(title(tab))
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .primary : .secondary)
                        Rectangle().fill(isSelected ? Palette.accent : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1).offset(y: 0) }
    }
}

/// A small tag. Used sparingly.
struct Chip: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// A key as it is printed on the keyboard.
struct Keycap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.primary)
            .frame(minWidth: 20)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }
}

struct SpeakerAvatar: View {
    var id: String
    var name: String
    var size: CGFloat = 28
    var ring = false

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        let tint = Palette.voice(id)
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(tint, lineWidth: ring ? 2 : 0).padding(ring ? -3 : 0))
    }
}

/// A little equaliser: how loud this source is right now.
struct LevelBars: View {
    var level: Float
    var tint: Color = Palette.accent
    private let shape: [CGFloat] = [0.55, 0.85, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<shape.count, id: \.self) { index in
                let height = 4 + 12 * CGFloat(min(1, max(0, level))) * shape[index]
                Capsule()
                    .fill(tint.opacity(level > 0.04 ? 0.95 : 0.35))
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct PulsingDot: View {
    var tint: Color = Palette.record
    var size: CGFloat = 8
    @State private var on = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 3).scaleEffect(on ? 1.6 : 1).opacity(on ? 0 : 0.8))
            .onAppear {
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A rounded search box.
struct SearchBox: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundColor(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.sunken))
    }
}

/// A heading above a block of settings or a list.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
    }
}

/// One line of settings: what it does, and the control for it.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 10)
    }
}

/// A hairline between rows.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(height: 1) }
}

// MARK: - Multi-line text

/// A text area with no chrome of its own — the system `TextEditor` paints an
/// opaque background on macOS 12 that fights the page.
struct NotesEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var font = NSFont.systemFont(ofSize: 14)
    var onChange: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = PlaceholderTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = font
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.placeholder = placeholder
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        view.placeholder = placeholder
        if view.string != text && !view.hasMarkedText() { view.string = text }
        view.font = font
        view.textColor = .labelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesEditor
        init(_ parent: NotesEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.onChange?(view.string)
        }
    }
}

final class PlaceholderTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                                     y: textContainerInset.height),
                         withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                                          .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

// MARK: - Helpers

enum Formatting {
    static func count(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "EEEEMMMMdy")
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today, " + time(date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, " + time(date)
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date) + ", " + time(date)
    }
}
