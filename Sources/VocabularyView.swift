import SwiftUI

/// Your words: names and terms Quill should spell your way, and phrases that
/// expand into longer text.
struct VocabularyView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Defaults.polish) private var cleanup = false
    @State private var notes = ContextNotes.text
    @State private var saveWork: DispatchWorkItem?
    @State private var trial = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Vocabulary").font(.display(30))
                    Text("Teach Quill how you say and spell things.").font(.system(size: 14)).foregroundColor(.secondary)
                }
                .padding(.top, 8)

                notesSection
                snippetsSection
            }
            .padding(.horizontal, 38)
            .padding(.top, 14)
            .padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { flushNotes() }
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(text: "Names & terms")
                Spacer()
                Text("\(ContextNotes.normalise(notes).count) / \(ContextNotes.maxLength)")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundColor(.secondary)
            }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Speech recognition mishears names and jargon. List yours — people, products, places, a line about your work — and grammar cleanup will spell them the way you do.")
                        .font(.system(size: 12.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NotesEditor(text: $notes,
                                placeholder: "e.g. I work on Quill, a Mac dictation app.\nPeople: Priya Raghunathan, Siobhan.\nTerms: Kubernetes, xAI, Grok.",
                                font: NSFont.systemFont(ofSize: 14),
                                onChange: { _ in scheduleSave() })
                        .frame(height: 150)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunken))
                }
            }
            if !cleanup {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundColor(Palette.caution)
                    Text("These are used when “Clean up grammar” is on.").font(.system(size: 12.5))
                    Spacer()
                    Button("Turn it on") { cleanup = true }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.caution.opacity(0.10)))
            }
            Text("Written by you and nothing else — Quill never reads your screen or other apps to build this.")
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { ContextNotes.text = notes }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushNotes() {
        saveWork?.cancel()
        ContextNotes.text = notes
    }

    // MARK: Snippets

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Snippets")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Say a short phrase, get the full text.").font(.system(size: 14, weight: .medium))
                        Text("When a dictation is exactly the phrase, or contains it, Quill writes the expansion instead — an email address, a link, a sign-off.")
                            .font(.system(size: 12.5)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                    RowDivider()

                    if model.snippets.isEmpty {
                        VStack(spacing: 8) {
                            Text("No snippets yet").font(.system(size: 13, weight: .medium))
                            Text("Try “my email” → you@example.com, or “thanks sign off” → Thanks so much,\nAlex")
                                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(22)
                        RowDivider()
                    } else {
                        ForEach($model.snippets) { $snippet in
                            SnippetRow(snippet: $snippet) {
                                model.setSnippets(model.snippets.filter { $0.id != snippet.id })
                            }
                            RowDivider()
                        }
                    }

                    HStack {
                        Button { model.setSnippets(model.snippets + [Snippet(trigger: "", expansion: "")]) } label: {
                            HStack(spacing: 6) { Image(systemName: "plus"); Text("Add snippet") }
                        }
                        .buttonStyle(GhostButtonStyle(tint: Palette.accentText))
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .onChange(of: model.snippets) { Snippets.save($0) }

            if !model.snippets.isEmpty { tryIt }
        }
    }

    private var tryIt: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Try it").font(.system(size: 13, weight: .semibold))
                TextField("Type what you'd say, e.g. “please use my email”", text: $trial)
                    .textFieldStyle(.roundedBorder)
                let result = Snippets.expand(trial, using: model.snippets)
                if !trial.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: result == trial ? "equal.circle" : "arrow.turn.down.right")
                            .foregroundColor(result == trial ? .secondary : Palette.positive)
                        Text(result == trial ? "No snippet matches." : result)
                            .font(.system(size: 13))
                            .foregroundColor(result == trial ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct SnippetRow: View {
    @Binding var snippet: Snippet
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("When I say…", text: $snippet.trigger)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            TextField("Write this…", text: $snippet.expansion)
                .textFieldStyle(.roundedBorder)
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle())
                .help("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
