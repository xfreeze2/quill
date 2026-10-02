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
            PageHeader(symbol: "mic.fill", tile: .coral, title: "Dictation", subtitle: hint) {
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
            .padding(.horizontal, 40)
            .padding(.top, Layout.titlebar - 4)

            TabStrip(tabs: AppModel.DictationTab.allCases, selection: $model.dictationTab) { $0.rawValue }
                .padding(.horizontal, 40)
                .padding(.top, 16)

            switch model.dictationTab {
            case .history:    HistoryList(model: model, query: query, keepHistory: keepHistory, trigger: trigger, singleTap: singleTap)
            case .vocabulary: VocabularyPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PageGround(tint: .coral))
        .alert("Delete all dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every dictation Quill has kept on this Mac. It can't be undone.")
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    @ObservedObject var model: AppModel
    var query: String
    var keepHistory: Bool
    var trigger: Trigger
    var singleTap: Bool
    @State private var limit = 80

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var results: [DictationEntry] {
        searching ? model.history.search(query) : model.entries
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
            FirstDictation(model: model, keepHistory: keepHistory, trigger: trigger, singleTap: singleTap)
        } else if results.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing you dictated matches “\(query)”.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !searching { StatsRow(stats: model.stats) }

                    ForEach(groups, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                GroupHeading(text: Formatting.day(group.day))
                                Spacer()
                                let words = group.entries.reduce(0) { $0 + $1.wordCount }
                                Text("\(Formatting.count(words)) word\(words == 1 ? "" : "s")")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                    .padding(.trailing, 4)
                            }
                            Panel(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                        if index > 0 { RowDivider().padding(.leading, 56) }
                                        EntryRow(model: model, entry: entry)
                                    }
                                }
                            }
                        }
                    }

                    if results.count > limit {
                        Button("Show older") { limit += 120 }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 10.5))
                        Text(keepHistory ? "Kept only on this Mac." : "Keeping dictations is off. New ones aren't saved.")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// How you've been dictating: four numbers, and the last week as bars.
private struct StatsRow: View {
    var stats: DictationStats

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StatTile(value: Formatting.count(stats.wordsToday), label: "Words today", symbol: "text.alignleft", tile: .coral)
                    StatTile(value: Formatting.count(stats.wordsThisWeek), label: "This week", symbol: "calendar", tile: .sky)
                }
                HStack(spacing: 12) {
                    StatTile(value: "\(stats.streakDays)", label: stats.streakDays == 1 ? "Day in a row" : "Days in a row",
                             symbol: "flame.fill", tile: .amber)
                    if let pace = stats.wordsPerMinute {
                        StatTile(value: "\(pace)", label: "Words a minute", symbol: "speedometer", tile: .green)
                    } else {
                        StatTile(value: Formatting.count(stats.words), label: "In total", symbol: "sum", tile: .green)
                    }
                }
            }
            .frame(width: 340)
            WeekChart(days: stats.lastSevenDays)
        }
    }
}

private struct WeekChart: View {
    var days: [Int]

    private func letter(_ index: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: index - (days.count - 1), to: Date()) ?? Date()
        return calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }

    var body: some View {
        let peak = max(1, days.max() ?? 1)
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Last 7 days").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Formatting.count(days.reduce(0, +))) words")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, words in
                        let today = index == days.count - 1
                        VStack(spacing: 7) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(today
                                      ? AnyShapeStyle(LinearGradient(colors: [Tile.coral.top, Tile.coral.bottom], startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Tile.coral.top.opacity(words == 0 ? 0.14 : 0.42)))
                                .frame(height: words == 0 ? 4 : max(8, CGFloat(words) / CGFloat(peak) * 84))
                            Text(letter(index))
                                .font(.system(size: 10.5, weight: today ? .bold : .medium))
                                .foregroundColor(today ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct EntryRow: View {
    @ObservedObject var model: AppModel
    var entry: DictationEntry
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppAvatar(name: entry.app, size: 30)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.app ?? "Dictation")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(Formatting.time(entry.date))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    HStack(spacing: 0) {
                        Button { model.copy(entry.text, message: "Copied") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(IconButtonStyle())
                            .help("Copy")
                        Button { model.deleteEntry(entry.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(IconButtonStyle())
                            .help("Delete")
                    }
                    .opacity(hovering ? 1 : 0)
                    .padding(.vertical, -6)
                }
                Text(entry.text)
                    .font(.system(size: 14))
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovering ? Palette.hover.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - First run

/// What a person sees before they have dictated anything: how it works, and a
/// place to try it.
private struct FirstDictation: View {
    @ObservedObject var model: AppModel
    var keepHistory: Bool
    var trigger: Trigger
    var singleTap: Bool
    @State private var practice = ""

    private var verb: String { trigger == .f5 ? "Press" : (singleTap ? "Tap" : "Double-tap") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel(padding: 26) {
                    HStack(alignment: .center, spacing: 28) {
                        KeyIllustration(text: trigger.shortTitle, size: 78)
                            .padding(.leading, 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Talk instead of typing")
                                .font(.system(size: 22, weight: .semibold))
                            Text("\(verb) \(trigger.title), say what you want to write, then \(verb.lowercased()) it again. Quill types it wherever your cursor is.")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Chip(text: "Works in every app", symbol: "checkmark")
                                Chip(text: "Fixes ums and restarts", symbol: "wand.and.stars")
                            }
                            .padding(.top, 6)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    Step(number: 1, title: "Click where you type", detail: "Mail, Slack, Notes, a browser. Anywhere there's a cursor.")
                    Step(number: 2, title: "\(verb) \(trigger.shortTitle) and talk", detail: "A small bar shows Quill is listening. Speak naturally.")
                    Step(number: 3, title: "\(verb) \(trigger.shortTitle) to finish", detail: "Your words appear, with punctuation. Dictations are kept here.")
                }

                Panel(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            IconTile(symbol: "text.cursor", tile: .coral, size: 24)
                            Text("Try it here").font(.system(size: 14, weight: .semibold))
                        }
                        NotesEditor(text: $practice,
                                    placeholder: "Click here, \(verb.lowercased()) \(trigger.shortTitle), and say something.",
                                    onChange: { _ in })
                            .frame(height: 84)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunken))
                    }
                }

                if !keepHistory {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text("Keeping dictations is off, so they won't be listed here.")
                            .foregroundColor(.secondary)
                        Button("Open Settings") { model.open(.settings) }
                            .buttonStyle(.plain).foregroundColor(Palette.accentText)
                    }
                    .font(.system(size: 12.5))
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct Step: View {
    var number: Int
    var title: String
    var detail: String

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(LinearGradient(colors: [Tile.coral.top, Tile.coral.bottom], startPoint: .top, endPoint: .bottom)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
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
            VStack(alignment: .leading, spacing: 18) {
                names
                shortcuts
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { flush() }
    }

    // MARK: Names and terms

    private var names: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: "person.text.rectangle", tile: .sky, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Names and terms").font(.system(size: 15, weight: .semibold))
                        Text("Speech recognition mishears names and jargon. List yours and Quill spells them your way.")
                            .font(.system(size: 12.5)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    if ContextNotes.normalise(notes).count > ContextNotes.maxLength * 3 / 4 {
                        Text("\(ContextNotes.normalise(notes).count) / \(ContextNotes.maxLength)")
                            .font(.system(size: 11.5).monospacedDigit()).foregroundColor(.secondary)
                    }
                }
                NotesEditor(text: $notes,
                            placeholder: "People: Priya Raghunathan, Siobhan.\nTerms: Kubernetes, xAI, Grok.\nI work on Quill, a Mac dictation app.",
                            onChange: { _ in schedule() })
                    .frame(height: 120)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunken))
                if !cleanup {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text("Used when grammar cleanup is on.").foregroundColor(.secondary)
                        Button("Turn it on") { cleanup = true }
                            .buttonStyle(.plain).foregroundColor(Palette.accentText)
                    }
                    .font(.system(size: 12.5))
                }
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
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: "arrow.right.square", tile: .teal, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shortcuts").font(.system(size: 15, weight: .semibold))
                        Text("Say a short phrase, get the full text: an email address, a link, a sign-off.")
                            .font(.system(size: 12.5)).foregroundColor(.secondary)
                    }
                }

                if model.snippets.isEmpty {
                    HStack(spacing: 10) {
                        Text("my email").font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        Text("priya@example.com").font(.system(size: 13)).foregroundColor(.secondary)
                        Spacer()
                        Text("Example").font(.system(size: 11.5)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.sunken))
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.snippets) { snippet in
                            SnippetRow(snippet: binding(for: snippet)) {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                model.setSnippets(model.snippets.filter { $0.id != snippet.id })
                            }
                        }
                    }
                    .onChange(of: model.snippets) { Snippets.save($0) }
                }

                Button { model.setSnippets(model.snippets + [Snippet(trigger: "", expansion: "")]) } label: {
                    HStack(spacing: 6) { Image(systemName: "plus"); Text("Add a shortcut") }
                }
                .buttonStyle(GhostButtonStyle(tint: Palette.accentText))
            }
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
        .padding(.vertical, 5)
    }
}
