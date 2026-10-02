import SwiftUI

// Small drawings of what a screen will look like once there is something on it.
// They fill the first-run pages so an empty app shows what it does instead of
// showing a blank.

/// A card with a drawing on top and two lines under it. In a narrow window the
/// drawing moves to the side.
struct ShowcaseCard<Drawing: View>: View {
    var title: String
    var caption: String
    var compact = false
    let drawing: Drawing

    init(title: String, caption: String, compact: Bool = false, @ViewBuilder drawing: () -> Drawing) {
        self.title = title
        self.caption = caption
        self.compact = compact
        self.drawing = drawing()
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(caption).font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var frame: some View {
        drawing
            .padding(10)
            .frame(maxWidth: .infinity)
            .frame(width: compact ? 168 : nil, height: compact ? 84 : 98)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.sunken))
    }

    var body: some View {
        Panel(padding: 12, radius: 12) {
            if compact {
                HStack(alignment: .center, spacing: 14) {
                    frame
                    texts
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    frame
                    texts.padding(.bottom, 2)
                }
            }
        }
    }
}

/// Three voices taking turns along a timeline.
struct VoiceMapSketch: View {
    private let lanes: [(id: String, segments: [(Double, Double)])] = [
        ("you", [(0.02, 0.16), (0.52, 0.60), (0.82, 0.96)]),
        ("s0", [(0.18, 0.36), (0.62, 0.74)]),
        ("s1", [(0.38, 0.50), (0.76, 0.80)]),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                HStack(spacing: 8) {
                    Circle().fill(Palette.voice(lane.id)).frame(width: 12, height: 12)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            ForEach(Array(lane.segments.enumerated()), id: \.offset) { _, segment in
                                Capsule()
                                    .fill(Palette.voice(lane.id))
                                    .frame(width: max(5, proxy.size.width * (segment.1 - segment.0)))
                                    .offset(x: proxy.size.width * segment.0)
                            }
                        }
                    }
                    .frame(height: 10)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// A few timestamped lines of notes.
struct NotesSketch: View {
    private let lines: [(String, String)] = [
        ("0:42", "Launch moves to the 14th"),
        ("1:15", "Priya owns the pricing page"),
        ("2:03", "Budget is capped at 8k"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.0)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 26, alignment: .leading)
                    Text(line.1)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A question and its answer.
struct AskSketch: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text("What did I agree to do?")
                .font(.system(size: 11.5))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.accentSoft))
                .foregroundColor(Palette.accentText)
            Text("Send the revised pricing to Priya by Friday.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}
