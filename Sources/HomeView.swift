import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.trigger) private var triggerRaw = Trigger.control.rawValue
    @AppStorage(Defaults.singleTap) private var singleTap = true
    @AppStorage(Defaults.liveDoubleTap) private var liveDoubleTap = true

    private var trigger: Trigger { Trigger(rawValue: triggerRaw) ?? .control }
    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if !model.access.isComplete { setupCard }
                if let version = model.access.updateVersion { updateCard(version) }
                actions
                stats
                HStack(alignment: .top, spacing: 18) {
                    recentDictations
                    recentMeetings
                }
            }
            .padding(.horizontal, 38)
            .padding(.top, 14)
            .padding(.bottom, 40)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(firstName.isEmpty ? Formatting.greeting() : "\(Formatting.greeting()), \(firstName)")
                .font(.display(34))
            Text(summaryLine).font(.system(size: 14.5)).foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var summaryLine: String {
        let stats = model.stats
        if stats.wordsToday > 0 {
            return "You've dictated \(Formatting.count(stats.wordsToday)) word\(stats.wordsToday == 1 ? "" : "s") today."
        }
        if stats.dictations > 0 { return "Nothing dictated yet today. Quill is listening for your trigger key." }
        return "Speak anywhere, take meeting notes, translate what you hear. Quill is ready."
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 16) {
            ActionCard(symbol: "mic.fill", tint: Palette.accent, title: "Dictate anywhere",
                       message: "Speak and the words land in whatever app you're in, with punctuation and your own spelling.") {
                HStack(spacing: 8) {
                    Keycap(text: trigger.shortTitle)
                    Text(trigger == .f5 ? "Press to start and stop"
                         : (singleTap ? "Tap to start and stop" : "Double-tap to start and stop"))
                        .font(.system(size: 12.5)).foregroundColor(.secondary)
                }
            }
            ActionCard(symbol: "person.2.wave.2", tint: Color(red: 0.55, green: 0.33, blue: 0.92), title: "Meeting notes",
                       message: "Capture a call or a room. Quill writes down who said what, then summarises it.") {
                if model.isRecordingMeeting {
                    Button { if let id = model.session?.meeting.id { model.openMeeting(id) } } label: {
                        HStack(spacing: 7) { PulsingDot(); Text("Recording — open") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("New meeting") { model.newMeeting() }
                        .buttonStyle(PrimaryButtonStyle(tint: Color(red: 0.50, green: 0.32, blue: 0.88)))
                }
            }
            ActionCard(symbol: "translate", tint: Palette.positive, title: "Live translation",
                       message: "Hear any language on a call or video, translated as it's spoken.") {
                HStack(spacing: 10) {
                    Button(model.liveRunning ? "Stop" : "Start") { model.bridge.toggleLive() }
                        .buttonStyle(SecondaryButtonStyle())
                    if singleTap, liveDoubleTap, trigger != .f5 {
                        HStack(spacing: 5) {
                            Text("or double-tap").font(.system(size: 12)).foregroundColor(.secondary)
                            Keycap(text: trigger.shortTitle)
                        }
                    }
                }
            }
        }
    }

    private var stats: some View {
        let s = model.stats
        return HStack(spacing: 16) {
            StatCard(value: Formatting.count(s.wordsToday), label: "Words today")
            StatCard(value: Formatting.count(s.wordsThisWeek), label: "Words this week")
            StatCard(value: s.streakDays == 0 ? "—" : "\(s.streakDays)", label: s.streakDays == 1 ? "Day streak" : "Day streak",
                     footnote: s.streakDays > 1 ? "days in a row" : nil)
            StatCard(value: s.wordsPerMinute.map { "\($0)" } ?? "—", label: "Words per minute", footnote: s.wordsPerMinute == nil ? "after a few dictations" : "speaking pace")
        }
    }

    private var recentDictations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Recent dictations")
                Spacer()
                if !model.entries.isEmpty {
                    Button("See all") { model.open(.history) }.buttonStyle(GhostButtonStyle(tint: Palette.accentText))
                }
            }
            Card(padding: 0) {
                if model.entries.isEmpty {
                    Text("What you dictate will appear here, ready to copy.")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .padding(18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.entries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider() }
                            Button { model.copy(entry.text, message: "Copied to clipboard") } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.text).font(.system(size: 13.5)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(meta(entry)).font(.system(size: 11.5)).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func meta(_ entry: DictationEntry) -> String {
        var parts = [Formatting.shortDate(entry.date)]
        if let app = entry.app { parts.append(app) }
        parts.append("\(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Recent meetings")
                Spacer()
                if !model.meetings.isEmpty {
                    Button("See all") { model.open(.meetings) }.buttonStyle(GhostButtonStyle(tint: Palette.accentText))
                }
            }
            Card(padding: 0) {
                if model.meetings.isEmpty {
                    VStack(spacing: 10) {
                        Text("Meeting notes you take will be kept here, with the transcript and summary.")
                            .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button("Start a meeting") { model.newMeeting() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .padding(18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.meetings.prefix(4).enumerated()), id: \.element.id) { index, meeting in
                            if index > 0 { RowDivider() }
                            Button { model.openMeeting(meeting.id) } label: {
                                HStack(spacing: 11) {
                                    MeetingGlyph(meeting: meeting, live: model.session?.meeting.id == meeting.id)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(meeting.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                        Text(MeetingRow.subtitle(meeting)).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var setupCard: some View {
        let missing: [String] = [
            model.access.microphone != .authorized ? "microphone" : nil,
            model.access.accessibility ? nil : "Accessibility",
            model.access.account == nil ? "a Grok sign-in or API key" : nil,
        ].compactMap { $0 }
        return HStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 22)).foregroundColor(Palette.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setting up").font(.system(size: 14, weight: .semibold))
                Text("Quill still needs \(list(missing)) to work properly.")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Open setup") { model.bridge.openSetup() }.buttonStyle(PrimaryButtonStyle(tint: Palette.caution))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.caution.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.caution.opacity(0.30), lineWidth: 1))
    }

    private func updateCard(_ version: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundColor(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quill \(version) is available").font(.system(size: 14, weight: .semibold))
                Text("You're on \(Build.version).").font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            Spacer()
            Button("See what's new") { model.bridge.openUpdatePage() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.accentSoft))
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return "nothing"
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}

private struct ActionCard<Footer: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String
    let footer: Footer

    init(symbol: String, tint: Color, title: String, message: String, @ViewBuilder footer: () -> Footer) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.footer = footer()
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.14))
                    Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundColor(tint)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.display(18))
                    Text(message).font(.system(size: 12.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                footer
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        }
    }
}

private struct StatCard: View {
    var value: String
    var label: String
    var footnote: String? = nil

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.display(32)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.system(size: 12.5, weight: .medium))
                Text(footnote ?? " ").font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
