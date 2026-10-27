import SwiftUI
import KobeKit

/// Notes: the latest notes as cards, three to a row. Return or a click opens the note in the notch's editor (saved
/// to Notes as you type, and on the way back); "Open in Notes" opens it in Notes.
struct NotesPage: View {
    let app: AppModel
    @State private var selection = PageSelection()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.sm, alignment: .top), count: 3)

    var body: some View {
        let snapshot = app.snapshots.notes
        let notes = snapshot?.data.notes ?? []
        let editing = app.mac.editing
        PageScaffold(app: app, id: .notes,
                     footer: editing == nil ? ["↩ edits", "Esc back"] : ["Esc saves and goes back"],
                     keys: editing == nil ? [.up, .down, .enter] : [.escape],
                     onKey: { key in
                         if editing != nil { if key == .escape { Task { await app.mac.closeNote() } }; return }
                         switch key {
                         case .up: selection.move(.up, count: notes.count)
                         case .down: selection.move(.down, count: notes.count)
                         case .enter: if let n = selection.current(in: notes) { edit(n) }
                         default: break
                         }
                     }) {
            if let editing {
                NoteEditor(app: app, editing: editing)
            } else {
                cards(notes, snapshot: snapshot)
            }
        } actions: {
            if let editing {
                if let problem = editing.problem {
                    Text(problem).font(KFont.meta).foregroundStyle(K.red).lineLimit(1)
                    if editing.dirty { Button("Discard") { app.mac.discardNote() }.buttonStyle(DangerButtonStyle()) }
                } else if editing.saving {
                    Text("Saving").font(KFont.meta).foregroundStyle(K.text3)
                }
                Button("Open in Notes") { app.mac.openNote(editing.id) }.buttonStyle(GlassButtonStyle())
                Button("Done") { Task { await app.mac.closeNote() } }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Open Notes") { app.mac.openApp(.notes) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func edit(_ note: NoteItem) {
        Task { await app.mac.editNote(note.id, title: note.title) }
    }

    @ViewBuilder private func cards(_ notes: [NoteItem], snapshot: WidgetSnapshot<NotesSnapshotData>?) -> some View {
        MacPageNotice(app: app, kind: .notes, closed: snapshot.map { $0.data.appRunning ? nil : $0.detail } ?? nil)
        if notes.isEmpty {
            Text("No notes yet").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
        } else {
            PageList(app: app, selected: selection.current(in: notes)?.id) {
                LazyVGrid(columns: columns, spacing: Spacing.sm) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        NoteCard(note: note, focused: selection.index == index) { edit(note) }
                            .id(note.id)
                    }
                }
            }
            .onChange(of: notes.count) { _, count in selection.clamp(count: count) }
        }
    }
}

/// The note in the notch: back, the title, then the text. Typing saves to Notes 2 s after it stops, Done or Esc
/// saves and goes back, and folding the notch saves. A note the notch can't keep whole is shown, not edited.
private struct NoteEditor: View {
    let app: AppModel
    let editing: MacConnectors.NoteEditing
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                KitIconButton(icon: .caretLeft, help: "Back (Esc)") { Task { await app.mac.closeNote() } }
                Text(editing.title.isEmpty ? "New note" : editing.title).font(KFont.row).foregroundStyle(K.text1)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let reason = editing.readOnly {
                    Text(Self.why(reason)).font(KFont.meta).foregroundStyle(K.text3).lineLimit(1)
                } else if editing.document != nil {
                    Text(editing.dirty ? "Editing" : "Saved").font(KFont.meta).foregroundStyle(K.text3)
                }
            }
            if editing.document != nil {
                TextEditor(text: Binding(get: { app.mac.editing?.text ?? "" }, set: { app.mac.editing?.text = $0 }))
                    .font(KFont.body).foregroundStyle(K.text1)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .onAppear { focused = true }
                    // Saved 2 s after typing stops.
                    .task(id: editing.text) {
                        guard editing.dirty else { return }
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        await app.mac.saveNote()
                    }
            } else {
                ScrollView(.vertical) {
                    Text(editing.text).font(KFont.body).foregroundStyle(K.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140)
            }
        }
        // The notch folding: what's typed goes to Notes.
        .onDisappear { Task { await app.mac.saveNote() } }
    }

    static func why(_ reason: NoteDocument.ReadOnly) -> String {
        switch reason {
        case .locked: "Locked: edit it in Notes"
        case .attachments: "Has images or files: edit it in Notes"
        case .formatting: "Has formatting the notch can't keep: edit it in Notes"
        }
    }
}

private struct NoteCard: View {
    let note: NoteItem
    let focused: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title.isEmpty ? "New note" : note.title).font(KFont.row).foregroundStyle(K.text1).lineLimit(1)
                Text(note.snippet).font(KFont.secondary).foregroundStyle(K.text2).lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                Text([note.folder.isEmpty ? nil : note.folder, PageText.when(note.modified)].compactMap { $0 }
                        .joined(separator: " · "))
                    .font(KFont.meta).foregroundStyle(K.text3).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(hovering || focused ? K.glassActive : K.glass,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(K.glassHighlight, lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
