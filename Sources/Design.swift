import SwiftUI
import AppKit

// The look of the Quill window: one quiet palette with a single ink-blue accent,
// a serif for headlines and numbers so it reads like a notebook rather than a
// control panel, and plain system type for everything you actually read.

enum Palette {

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let accent = dynamic(light: rgb(0.30, 0.32, 0.84), dark: rgb(0.60, 0.62, 1.00))
    static let accentSoft = dynamic(light: rgb(0.30, 0.32, 0.84, 0.10), dark: rgb(0.60, 0.62, 1.00, 0.16))
    static let accentText = dynamic(light: rgb(0.24, 0.26, 0.72), dark: rgb(0.70, 0.72, 1.00))

    /// The window behind everything.
    static let canvas = dynamic(light: rgb(0.962, 0.960, 0.955), dark: rgb(0.105, 0.105, 0.115))
    /// Cards and panels sitting on the canvas.
    static let surface = dynamic(light: rgb(1, 1, 1), dark: rgb(0.150, 0.150, 0.165))
    /// Inset areas: fields, wells, hover fills.
    static let sunken = dynamic(light: rgb(0, 0, 0, 0.045), dark: rgb(1, 1, 1, 0.065))
    static let hover = dynamic(light: rgb(0, 0, 0, 0.06), dark: rgb(1, 1, 1, 0.09))
    static let hairline = dynamic(light: rgb(0, 0, 0, 0.085), dark: rgb(1, 1, 1, 0.10))

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

extension Font {
    /// Headlines and big numbers: a serif, for the notebook feel.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat
    var radius: CGFloat
    let content: Content

    init(padding: CGFloat = 18, radius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 8, x: 0, y: 2)
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.80 : 1) : 0.4))
            )
            .shadow(color: tint.opacity(isEnabled ? 0.28 : 0), radius: 6, x: 0, y: 2)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Palette.hover : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.hairline, lineWidth: 1)
            )
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
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed || hovering ? Palette.hover : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(configuration.isPressed || hovering ? Palette.hover : Color.clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Small pieces

struct Chip: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
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
            .frame(minWidth: 22)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.06), radius: 0, x: 0, y: 1)
    }
}

struct SpeakerAvatar: View {
    var id: String
    var name: String
    var size: CGFloat = 30

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
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(width: size, height: size)
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
                let height = 4 + 14 * CGFloat(min(1, max(0, level))) * shape[index]
                Capsule()
                    .fill(tint.opacity(level > 0.04 ? 0.95 : 0.35))
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct PulsingDot: View {
    var tint: Color = Palette.record
    @State private var on = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 4).scaleEffect(on ? 1.5 : 1).opacity(on ? 0 : 0.8))
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
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Palette.accentSoft).frame(width: 64, height: 64)
                Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundColor(Palette.accent)
            }
            Text(title).font(.display(19))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 6)
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
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.sunken))
    }
}

/// A heading above a block of settings or a list.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundColor(.secondary)
    }
}

/// One line of a settings card: what it does, and the control for it.
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
                Text(title).font(.system(size: 13.5, weight: .medium))
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
        .padding(.vertical, 11)
    }
}

/// A hairline between rows inside a card.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(height: 1) }
}

// MARK: - Multi-line text

/// A text area with no chrome of its own — the system `TextEditor` paints an
/// opaque background on macOS 12 that fights a card.
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

extension View {
    /// Runs `action` whenever the pointer enters or leaves, and reports which.
    func hovering(_ binding: Binding<Bool>) -> some View {
        onHover { binding.wrappedValue = $0 }
    }
}

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

    static func greeting(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: now) {
        case 5..<12:  return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default:      return "Still up"
        }
    }
}
