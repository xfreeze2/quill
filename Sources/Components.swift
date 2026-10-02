import SwiftUI
import AppKit

// The pieces that make Quill look like an app rather than a page: a grounded
// background with white panels on it, colour-tiled icons, stat tiles, and the
// app icons of wherever you dictated.

extension Palette {
    /// Behind a page that is made of panels.
    static let ground = dynamic(light: rgb(0.953, 0.953, 0.962), dark: rgb(0.098, 0.098, 0.106))
    /// A panel on the ground.
    static let card = dynamic(light: rgb(1, 1, 1), dark: rgb(0.165, 0.165, 0.178))
}

/// The colours of the little icon tiles. Solid and saturated in both appearances,
/// because the glyph on them is always white.
enum Tile: CaseIterable {
    case indigo, coral, teal, slate, amber, green, rose, sky

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    var top: Color {
        switch self {
        case .indigo: return Tile.c(0.43, 0.41, 0.98)
        case .coral:  return Tile.c(1.00, 0.55, 0.42)
        case .teal:   return Tile.c(0.22, 0.76, 0.70)
        case .slate:  return Tile.c(0.62, 0.64, 0.70)
        case .amber:  return Tile.c(1.00, 0.72, 0.24)
        case .green:  return Tile.c(0.34, 0.80, 0.52)
        case .rose:   return Tile.c(0.98, 0.45, 0.62)
        case .sky:    return Tile.c(0.36, 0.70, 1.00)
        }
    }

    var bottom: Color {
        switch self {
        case .indigo: return Tile.c(0.30, 0.28, 0.88)
        case .coral:  return Tile.c(0.93, 0.38, 0.28)
        case .teal:   return Tile.c(0.08, 0.58, 0.54)
        case .slate:  return Tile.c(0.46, 0.48, 0.54)
        case .amber:  return Tile.c(0.96, 0.58, 0.10)
        case .green:  return Tile.c(0.16, 0.64, 0.38)
        case .rose:   return Tile.c(0.90, 0.30, 0.48)
        case .sky:    return Tile.c(0.16, 0.52, 0.92)
        }
    }

    /// The colour as text or a line, readable in both appearances.
    var ink: Color { bottom }
}

extension AppModel.Section {
    var tile: Tile {
        switch self {
        case .meetings:  return .indigo
        case .dictation: return .coral
        case .translate: return .teal
        case .settings:  return .slate
        }
    }
}

/// A rounded square with a white glyph, in the manner of the Mac's own settings.
struct IconTile: View {
    var symbol: String
    var tile: Tile = .indigo
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [tile.top, tile.bottom], startPoint: .top, endPoint: .bottom))
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).stroke(Color.black.opacity(0.10), lineWidth: 0.5))
    }
}

/// A white panel on the ground, with a hairline edge.
struct Panel<Content: View>: View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }
}

/// The ground of a page made of panels, with a wash of the page's colour at the top.
struct PageGround: View {
    var tint: Tile = .indigo

    var body: some View {
        ZStack(alignment: .top) {
            Palette.ground
            LinearGradient(colors: [tint.top.opacity(0.16), tint.top.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 280)
        }
        .ignoresSafeArea()
    }
}

/// The top of a page: its icon, its name, one line about it, and what you can do.
struct PageHeader<Trailing: View>: View {
    var symbol: String
    var tile: Tile
    var title: String
    var subtitle: String
    let trailing: Trailing

    init(symbol: String, tile: Tile, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tile = tile
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, tile: tile, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(symbol: String, tile: Tile, title: String, subtitle: String) {
        self.init(symbol: symbol, tile: tile, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A number, and what it counts.
struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var tile: Tile

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                IconTile(symbol: symbol, tile: tile, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(label).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// A heading for a group of rows inside a page of panels.
struct GroupHeading: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 4)
    }
}

// MARK: - App icons

/// The icon of an app you dictated into, when it can be found on this Mac.
enum AppIcons {
    private static var found: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(for name: String) -> NSImage? {
        if let image = found[name] { return image }
        if missing.contains(name) { return nil }
        var image: NSImage?
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            image = running.icon
        }
        if image == nil {
            let home = NSHomeDirectory() + "/Applications"
            for directory in ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities", home] {
                let path = "\(directory)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    image = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        if let image { found[name] = image } else { missing.insert(name) }
        return image
    }
}

/// An app's icon, or a coloured initial when there isn't one to be had.
struct AppAvatar: View {
    var name: String?
    var size: CGFloat = 30

    private var tile: Tile {
        let hash = (name ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Tile.allCases[hash % Tile.allCases.count]
    }

    var body: some View {
        if let name, let icon = AppIcons.icon(for: name) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let name, let first = name.first {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [tile.top, tile.bottom], startPoint: .top, endPoint: .bottom))
                Text(String(first).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)
        } else {
            IconTile(symbol: "text.cursor", tile: .slate, size: size)
        }
    }
}

// MARK: - Keys

/// A key as a physical key: a face with a thicker edge underneath.
struct KeyIllustration: View {
    var text: String
    var size: CGFloat = 54

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
            .foregroundColor(.primary)
            .frame(width: size * 1.15, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Palette.card)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(width: size * 0.9, height: 2).offset(y: 4)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 0, x: 0, y: 3)
    }
}
