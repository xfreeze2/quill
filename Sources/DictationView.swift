import SwiftUI

/// Everything about dictating: what you've said, and the words Quill should know.
struct DictationView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.trigger) private var triggerRaw = Trigger.control.rawValue
    @AppStorage(Defaults.singleTap) private var singleTap = true
    @AppStorage(Defaults.keepHistory) private var keepHistory = true
    @State private var query = ""
    @State private var confirmClear = false

    private var trigger: Trigger { Trigger(rawValue: triggerRaw) ?? .control }

    private var hint: String {
        var text = trigger.gesture(singleTap: singleTap) + " anywhere to dictate"
        let today = model.stats.wordsToday
        if today > 0 { text += " · \(Formatting.count(today)) word\(today == 1 ? "" : "s") today" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 40)
                .padding(.top, Layout.titlebar - 4)

            TabStrip(tabs: AppModel.DictationTab.allCases, selection: $model.dictationTab) { $0.rawValue }
                .padding(.horizontal, 40)
                .padding(.top, 16)

            switch model.dictationTab {
            case .history:    HistoryList(model: model, query: query, keepHistory: keepHistory)
            case .vocabulary: VocabularyPane(model: model)
            }
        }
        .alert("Delete all dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every dictation Quill has kept on this Mac. It can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dictation").font(.system(size: 22, weight: .semibold))
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if model.dictationTab == .history && !model.entries.isEmpty {
                SearchBox(text: $query, prompt: "Search")
                    .frame(width: 220)
                Menu {
                    Button("Delete all…") { confirmClear = true }
                    Divider()
                    Button("Show in Finder") { model.revealDataFolder() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
            }
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    @ObservedObject var model: AppModel
    var query: String
    var keepHistory: Bool
    @State private var limit = 80

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
        if model.entries.isEmpty {
            EmptyState(symbol: "text.quote", title: "Nothing dictated yet",
                       message: keepHistory
                       ? "What you dictate is kept here, on this Mac, so you can find it again."
                       : "Keeping dictations is turned off. Turn it on in Settings and what you dictate will be kept here.",
                       actionTitle: keepHistory ? nil : "Open Settings",
                       action: keepHistory ? nil : { model.open(.settings) })
        } else if results.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing you dictated matches “\(query)”.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.day) { group in
                        Text(Formatting.day(group.day))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 22)
                            .padding(.bottom, 6)
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            RowDivider()
                            EntryRow(model: model, entry: entry)
                        }
                        RowDivider()
                    }
                    if results.count > limit {
                        Button("Show older") { limit += 120 }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 10.5))
                        Text(keepHistory ? "Kept only on this Mac." : "Keeping dictations is off. New ones aren't saved.")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 36)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct EntryRow: View {
    @ObservedObject var model: AppModel
    var entry: DictationEntry
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.time(entry.date))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
                if let app = entry.app {
                    Text(app).font(.system(size: 11.5)).foregroundColor(.secondary.opacity(0.75)).lineLimit(1)
                }
            }
            .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if entry.text.count > 220 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.accentText)
                }
            }

            HStack(spacing: 0) {
                Button { model.copy(entry.text, message: "Copied") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle())
                    .help("Copy")
                Button { model.deleteEntry(entry.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle())
                    .help("Delete")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Vocabulary

/// Names and terms Quill should spell your way, and phrases that expand into
/// longer text.
private struct VocabularyPane: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.polish) private var cleanup = false
    @State private var notes = ContextNotes.text
    @State private var saveWork: DispatchWorkItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                names
                shortcuts
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { flush() }
    }

    // MARK: Names and terms

    private var names: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Names and terms").font(.system(size: 15, weight: .semibold))
                Spacer()
                if ContextNotes.normalise(notes).count > ContextNotes.maxLength * 3 / 4 {
                    Text("\(ContextNotes.normalise(notes).count) / \(ContextNotes.maxLength)")
                        .font(.system(size: 11.5).monospacedDigit()).foregroundColor(.secondary)
                }
            }
            Text("Speech recognition mishears names and jargon. List yours and Quill spells them your way.")
                .font(.system(size: 13)).foregroundColor(.secondary)
            NotesEditor(text: $notes,
                        placeholder: "People: Priya Raghunathan, Siobhan.\nTerms: Kubernetes, xAI, Grok.\nI work on Quill, a Mac dictation app.",
                        onChange: { _ in schedule() })
                .frame(height: 120)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunken))
            if !cleanup {
                HStack(spacing: 6) {
                    Text("Used when grammar cleanup is on.").foregroundColor(.secondary)
                    Button("Turn it on") { cleanup = true }
                        .buttonStyle(.plain).foregroundColor(Palette.accentText)
                }
                .font(.system(size: 12.5))
            }
        }
    }

    private func schedule() {
        saveWork?.cancel()
        let work = DispatchWorkItem { ContextNotes.text = notes }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flush() {
        saveWork?.cancel()
        ContextNotes.text = notes
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts").font(.system(size: 15, weight: .semibold))
            Text("Say a short phrase, get the full text: an email address, a link, a sign-off.")
                .font(.system(size: 13)).foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(model.snippets) { snippet in
                    RowDivider()
                    SnippetRow(snippet: binding(for: snippet)) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        model.setSnippets(model.snippets.filter { $0.id != snippet.id })
                    }
                }
                if !model.snippets.isEmpty { RowDivider() }
            }
            .onChange(of: model.snippets) { Snippets.save($0) }

            Button { model.setSnippets(model.snippets + [Snippet(trigger: "", expansion: "")]) } label: {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("Add a shortcut") }
            }
            .buttonStyle(GhostButtonStyle(tint: Palette.accentText))
        }
    }

    private func binding(for snippet: Snippet) -> Binding<Snippet> {
        Binding(
            get: { model.snippets.first { $0.id == snippet.id } ?? snippet },
            set: { updated in
                guard let index = model.snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
                model.snippets[index] = updated
            })
    }
}

private struct SnippetRow: View {
    @Binding var snippet: Snippet
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("When I say…", text: $snippet.trigger)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            TextField("Write this…", text: $snippet.expansion)
                .textFieldStyle(.roundedBorder)
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle())
                .help("Delete")
        }
        .padding(.vertical, 9)
    }
}
