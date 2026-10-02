import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.keepHistory) private var keepHistory = true
    @State private var query = ""
    @State private var limit = 80
    @State private var confirmClear = false

    private var results: [DictationEntry] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? model.entries : model.history.search(query)
    }

    private var groups: [(day: Date, entries: [DictationEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [DictationEntry]] = [:]
        for entry in results.prefix(limit) {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 38)
                .padding(.top, 22)
                .padding(.bottom, 16)

            if model.entries.isEmpty {
                EmptyState(symbol: "text.quote", title: "Nothing dictated yet",
                           message: keepHistory
                           ? "Tap your trigger key anywhere and start talking. Everything you dictate is kept here, on this Mac, so you can find it again."
                           : "Keeping dictations is turned off. Turn it on in Settings and what you dictate will be kept here.",
                           actionTitle: keepHistory ? nil : "Open Settings",
                           action: keepHistory ? nil : { model.open(.settings) })
            } else if results.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing you dictated matches “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(groups, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 9) {
                                SectionLabel(text: Formatting.day(group.day))
                                Card(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                            if index > 0 { RowDivider() }
                                            EntryRow(model: model, entry: entry)
                                        }
                                    }
                                }
                            }
                        }
                        if results.count > limit {
                            Button("Show older dictations") { limit += 120 }
                                .buttonStyle(SecondaryButtonStyle())
                                .frame(maxWidth: .infinity)
                        }
                        footer
                    }
                    .padding(.horizontal, 38)
                    .padding(.bottom, 36)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .alert(isPresented: $confirmClear) {
            Alert(title: Text("Delete all dictations?"),
                  message: Text("This removes every dictation Quill has kept on this Mac. It can't be undone."),
                  primaryButton: .destructive(Text("Delete All")) { model.clearHistory() },
                  secondaryButton: .cancel())
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictations").font(.display(30))
                Text(subtitle).font(.system(size: 13.5)).foregroundColor(.secondary)
            }
            Spacer()
            SearchBox(text: $query, prompt: "Search dictations")
                .frame(width: 250)
            Menu {
                Button("Delete all…") { confirmClear = true }
                Divider()
                Button("Show in Finder") { model.revealDataFolder() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .disabled(model.entries.isEmpty)
        }
    }

    private var subtitle: String {
        let s = model.stats
        if model.entries.isEmpty { return "A private record of what you've said." }
        return "\(Formatting.count(s.dictations)) dictation\(s.dictations == 1 ? "" : "s") · \(Formatting.count(s.words)) words, kept only on this Mac"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock").font(.system(size: 11))
            Text(keepHistory ? "Stored in a private file on this Mac. Nothing here is uploaded."
                 : "Keeping dictations is off. New ones aren't saved.")
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

private struct EntryRow: View {
    @ObservedObject var model: AppModel
    var entry: DictationEntry
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(Formatting.time(entry.date))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text)
                    .font(.system(size: 14))
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let app = entry.app { Chip(text: app, symbol: "app.dashed") }
                    Text("\(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                    if entry.text.count > 220 {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Palette.accentText)
                    }
                }
            }

            HStack(spacing: 2) {
                Button { model.copy(entry.text, message: "Copied to clipboard") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle())
                    .help("Copy")
                Button { model.deleteEntry(entry.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle())
                    .help("Delete")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(hovering ? Palette.sunken.opacity(0.5) : Color.clear)
        .onHover { hovering = $0 }
    }
}
