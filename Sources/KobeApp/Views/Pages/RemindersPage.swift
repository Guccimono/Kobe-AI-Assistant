import SwiftUI
import KobeKit

/// Reminders: Overdue, Today, Tomorrow, Later, No date. The circle ticks a reminder done in Reminders at once and
/// shows Undo for 5 s; the row fades and leaves with the next write. A click on the text opens Reminders.
/// "Add Reminder" opens a one-line field over the list: the date words become the due, Return adds it.
struct RemindersPage: View {
    let app: AppModel
    @State private var selection = PageSelection()
    /// The state of the last click per reminder, until the file says the same.
    @State private var clicked: [String: Bool] = [:]
    @State private var undo: String?
    @State private var failure: String?
    /// The add field: open, its text, the list chip, and a Today/Tomorrow/no-date pick over the typed date.
    @State private var adding = false
    @State private var text = ""
    @State private var listID: String?
    @State private var dayPick: Int??

    var body: some View {
        let snapshot = app.snapshots.reminders
        let now = Date()
        let groups = ReminderGroups.group(snapshot?.data.reminders ?? [], now: now)
        let flat = groups.flatMap(\.1)
        PageScaffold(app: app, id: .reminders,
                     footer: adding ? ["↩ adds", "Esc cancels"] : ["↩ opens in Reminders", "Esc back"],
                     keys: adding ? [.escape] : [.up, .down, .enter],
                     onKey: { key in
                         if adding { if key == .escape { closeAdd() }; return }
                         switch key {
                         case .up: selection.move(.up, count: flat.count)
                         case .down: selection.move(.down, count: flat.count)
                         case .enter: if let r = selection.current(in: flat) { app.mac.openReminders(r.id) }
                         default: break
                         }
                     }) {
            if adding {
                AddReminderField(text: $text, draft: draft, lists: app.mac.reminderLists(), listID: $listID,
                                 dayPick: $dayPick, submit: add)
            }
            if flat.isEmpty {
                Text("All done").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
            } else {
                PageList(app: app, selected: selection.current(in: flat)?.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.0) { group, items in
                            PageGroup(title: Self.title(group))
                            ForEach(items, id: \.id) { item in
                                ReminderRow(item: item, done: clicked[item.id] ?? item.completed,
                                            overdue: group == .overdue, due: ReminderGroups.dueText(item, now: now),
                                            focused: selection.current(in: flat)?.id == item.id,
                                            tick: { tick(item, done: !(clicked[item.id] ?? item.completed)) },
                                            open: { app.mac.openReminders(item.id) })
                                    .id(item.id)
                            }
                        }
                    }
                }
                .onChange(of: flat.count) { _, count in selection.clamp(count: count) }
            }
        } actions: {
            if let failure {
                Text(failure).font(KFont.meta).foregroundStyle(K.red).lineLimit(1)
            } else if let undo {
                UndoChip(text: "Done") {
                    if let item = flat.first(where: { $0.id == undo }) { tick(item, done: false) }
                    self.undo = nil
                }
                .id(undo)
            }
            if adding {
                Button("Cancel", action: closeAdd).buttonStyle(GlassButtonStyle())
                Button("Add", action: add).buttonStyle(PrimaryButtonStyle()).disabled(draft.isEmpty)
            } else {
                Button {
                    failure = nil
                    adding = true
                } label: {
                    HStack(spacing: 4) { Icon(icon: .plus, size: 12); Text("Add Reminder") }
                }
                .buttonStyle(GlassButtonStyle())
                Button("Open Reminders") { app.mac.openApp(.reminders) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .onChange(of: snapshot?.updatedAt) { _, _ in
            // The file caught up with the clicks: it draws them from now on.
            let items = snapshot?.data.reminders ?? []
            clicked = clicked.filter { id, done in items.first { $0.id == id }.map { $0.completed != done } ?? false }
        }
    }

    /// What Return adds: the typed line, with the day chip's pick over the date it found.
    private var draft: ReminderDraft {
        let parsed = ReminderDraft.parse(text)
        switch dayPick {
        case .none: return parsed
        // No date: the words that named one stay in the title.
        case .some(.none): return ReminderDraft(title: text.trimmingCharacters(in: .whitespacesAndNewlines), due: nil,
                                                dueHasTime: false)
        case .some(.some(let day)): return parsed.on(day: day)
        }
    }

    /// Typed and Return (or Add): written to Reminders at once; the field closes when it went.
    private func add() {
        let draft = draft
        guard !draft.isEmpty else { return }
        failure = nil
        Task {
            switch await app.actions.perform(.addReminder(draft, list: listID)) {
            case .success: closeAdd()
            case .failure(let error): failure = error.message
            }
        }
    }

    private func closeAdd() {
        adding = false
        text = ""
        dayPick = nil
    }

    /// Written at once (the click is the approval); Undo is a click the other way.
    private func tick(_ item: ReminderItem, done: Bool) {
        clicked[item.id] = done
        failure = nil
        undo = done ? item.id : nil
        Task {
            if case .failure(let error) = await app.actions.perform(.reminderDone(id: item.id, done: done)) {
                clicked[item.id] = nil
                undo = nil
                failure = error.message
            }
        }
    }

    static func title(_ group: ReminderGroup) -> String {
        switch group {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .later: "Later"
        case .noDate: "No date"
        }
    }
}

private struct ReminderRow: View {
    let item: ReminderItem
    let done: Bool
    let overdue: Bool
    let due: String
    let focused: Bool
    let tick: () -> Void
    let open: () -> Void

    var body: some View {
        let color = RGB(hex: item.listColor)?.color ?? K.text3
        HStack(spacing: 4) {
            Button(action: tick) {
                Icon(icon: done ? .checkCircleFill : .circle, size: 18).foregroundStyle(color)
                    .frame(width: 26, height: 26).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(done ? "Not done" : "Done")
            KitRow(title: item.title, subtitle: item.list,
                   detail: due.isEmpty ? nil : Text(due).foregroundStyle(overdue ? K.red : K.text2)
                       + Text("  " + item.list).foregroundStyle(K.text3),
                   focused: focused, stacked: true) {
                EmptyView()
            } trailing: {
                EmptyView()
            } action: {
                open()
            }
        }
        .opacity(done ? 0.45 : 1)
        .animation(.easeOut(duration: 0.15), value: done)
    }
}

/// The add field: the line, then what it will add: the due (Today, Tomorrow or the date found) and the list.
private struct AddReminderField: View {
    @Binding var text: String
    let draft: ReminderDraft
    let lists: [ReminderList]
    @Binding var listID: String?
    @Binding var dayPick: Int??
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Icon(icon: .circle, size: 16).foregroundStyle(K.text3)
                TextField("Call Ana tomorrow 10am", text: $text)
                    .textFieldStyle(.plain).font(KFont.body).foregroundStyle(K.text1)
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
            HStack(spacing: 6) {
                PickChip(text: "Today", lit: draft.dayOffset() == 0) { dayPick = draft.dayOffset() == 0 ? .some(nil) : 0 }
                PickChip(text: "Tomorrow", lit: draft.dayOffset() == 1) {
                    dayPick = draft.dayOffset() == 1 ? .some(nil) : 1
                }
                if let due = draft.due, draft.dayOffset() == nil {
                    PickChip(text: Self.dayText(due), lit: true) { dayPick = .some(nil) }
                }
                if draft.dueHasTime, let due = draft.due {
                    Text(MacBuilders.clock(due)).font(KFont.meta).foregroundStyle(K.text2)
                }
                Spacer(minLength: 0)
                if let list = lists.first(where: { $0.id == listID }) ?? lists.first {
                    PickChip(text: list.name, lit: false, dot: RGB(hex: list.color)?.color) {
                        listID = ReminderList.next(after: list.id, in: lists)?.id
                    }
                    .help("Change list")
                }
            }
        }
        .padding(.bottom, Spacing.xs)
        .onAppear {
            focused = true
            if listID == nil { listID = lists.first?.id }
        }
    }

    /// "Mon 2 Nov" for a due past tomorrow.
    static func dayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: date)
    }
}

/// A small capsule choice under the add field; lit when it is what Return will use.
private struct PickChip: View {
    let text: String
    let lit: Bool
    var dot: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(text).font(KFont.meta).foregroundStyle(lit ? K.text1 : K.text2)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(lit ? K.glassActive : K.glass, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
