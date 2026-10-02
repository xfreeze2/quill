import SwiftUI
import AppKit

/// ⌘K: one box for finding anything you've said and for getting around.
struct CommandPalette: View {
    @ObservedObject var model: AppModel
    @State private var query: String
    @State private var selected = 0
    @StateObject private var keys = KeyCatcher()
    @FocusState private var focused: Bool

    init(model: AppModel, query: String = "") {
        self.model = model
        _query = State(initialValue: query)
    }

    private struct Item: Identifiable {
        var id: String
        var symbol: String
        var tile: Tile
        var title: String
        var detail: String = ""
        var trailing: String = ""
        var run: () -> Void
    }

    private struct Bucket: Identifiable {
        var id: String { title }
        var title: String
        var items: [Item]
    }

    // MARK: Content

    private func closeThen(_ work: @escaping () -> Void) -> () -> Void {
        { model.showingSearch = false; work() }
    }

    private var actions: [Item] {
        var out: [Item] = [
            Item(id: "a-new", symbol: "plus", tile: .indigo, title: "New meeting", trailing: "⌘N", run: closeThen { model.newMeeting() }),
        ]
        let open = model.openTasks.count
        if !model.meetings.isEmpty {
            out.append(Item(id: "a-tasks", symbol: "checkmark.circle", tile: .green, title: "To-dos from meetings",
                            detail: open == 0 ? "Nothing open" : "\(open) open", run: closeThen { model.openTasksPage() }))
        }
        out.append(Item(id: "a-live", symbol: "character.bubble", tile: .teal,
                        title: model.liveRunning ? "Stop live translation" : "Start live translation",
                        run: closeThen { model.bridge.toggleLive() }))
        for section in AppModel.Section.allCases {
            out.append(Item(id: "g-\(section.rawValue)", symbol: section.symbol, tile: section.tile, title: "Go to \(section.title)",
                            trailing: "⌘\(section.shortcut)", run: closeThen { model.open(section) }))
        }
        return out
    }

    private var groups: [Bucket] {
        let terms = AppSearch.terms(query)
        if terms.isEmpty {
            var out = [Bucket(title: "Do", items: actions)]
            let recent = model.meetings.prefix(4).map { meeting in
                Item(id: "r-\(meeting.id)", symbol: "person.2.wave.2", tile: .indigo, title: meeting.title,
                     detail: Formatting.shortDate(meeting.createdAt), run: closeThen { model.openMeeting(meeting.id) })
            }
            if !recent.isEmpty { out.append(Bucket(title: "Recent meetings", items: Array(recent))) }
            return out
        }

        var out: [Bucket] = []
        let matching = actions.filter { item in
            terms.allSatisfy { item.title.lowercased().contains($0) }
        }
        if !matching.isEmpty { out.append(Bucket(title: "Do", items: matching)) }

        let hits = AppSearch.hits(for: query, meetings: model.meetings, entries: model.entries, limit: 24)
        func items(_ kind: SearchHit.Kind) -> [Item] {
            hits.filter { $0.kind == kind }.map { hit in
                switch kind {
                case .meeting:
                    return Item(id: hit.id, symbol: "person.2.wave.2", tile: .indigo, title: hit.title, detail: hit.detail,
                                trailing: Formatting.shortDate(hit.date), run: { model.open(hit) })
                case .task:
                    return Item(id: hit.id, symbol: "checkmark.circle", tile: .green, title: hit.title, detail: hit.detail,
                                run: { model.open(hit) })
                case .dictation:
                    return Item(id: hit.id, symbol: "mic", tile: .coral, title: hit.title, detail: hit.detail,
                                trailing: Formatting.shortDate(hit.date), run: { model.open(hit) })
                }
            }
        }
        for (title, kind) in [("Meetings", SearchHit.Kind.meeting), ("To-dos", .task), ("Dictations", .dictation)] {
            let list = items(kind)
            if !list.isEmpty { out.append(Bucket(title: title, items: list)) }
        }
        return out
    }

    private var flat: [Item] { groups.flatMap(\.items) }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { model.showingSearch = false }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                    TextField("Search meetings, dictations and to-dos", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                    Keycap(text: "esc")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle().fill(Palette.hairline).frame(height: 1)

                results

                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(spacing: 14) {
                    hint("↑↓", "move")
                    hint("↩", "open")
                    hint("esc", "close")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 14)
            .padding(.top, 86)
        }
        .onAppear {
            focused = true
            keys.start { code in handle(code) }
        }
        .onDisappear { keys.stop() }
        .onChange(of: query) { _ in selected = 0 }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.sunken))
            Text(text).font(.system(size: 11.5))
        }
        .foregroundColor(.secondary)
    }

    @ViewBuilder private var results: some View {
        let list = flat
        if list.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .light)).foregroundColor(.secondary)
                Text("No matches for “\(query)”").font(.system(size: 13.5, weight: .medium))
                Text("Try fewer words, or a name.").font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            Text(group.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(group.items) { item in
                                row(item, isSelected: list.firstIndex { $0.id == item.id } == selected)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 400)
                .onChange(of: selected) { index in
                    guard list.indices.contains(index) else { return }
                    proxy.scrollTo(list[index].id)
                }
            }
        }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        Button { item.run() } label: {
            HStack(spacing: 11) {
                IconTile(symbol: item.symbol, tile: item.tile, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1).foregroundColor(.primary)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !item.trailing.isEmpty {
                    Text(item.trailing).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Palette.selected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Keys

    private func handle(_ code: UInt16) -> Bool {
        let list = flat
        switch code {
        case 125:
            if !list.isEmpty { selected = min(list.count - 1, selected + 1) }
            return true
        case 126:
            selected = max(0, selected - 1)
            return true
        case 36, 76:
            if list.indices.contains(selected) { list[selected].run() }
            return true
        case 53:
            model.showingSearch = false
            return true
        default:
            return false
        }
    }
}

/// Listens for the few keys the palette answers to while it is open, so the arrow
/// keys move the choice even though the text field has the focus.
final class KeyCatcher: ObservableObject {
    private var monitor: Any?

    func start(_ handler: @escaping (UInt16) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event.keyCode) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
