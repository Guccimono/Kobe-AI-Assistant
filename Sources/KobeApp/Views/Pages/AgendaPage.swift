import SwiftUI
import KobeKit

/// Agenda: the selected day's events on the left, the month on the right. A click on a day lists it; a click (or
/// Return) on an event opens its detail in place, where "View details" opens it in Calendar. ← → change month,
/// ← or Esc goes back from the detail. Months outside the snapshot (yesterday to 30 days ahead) are read live.
struct AgendaPage: View {
    let app: AppModel
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var month = Calendar.current.startOfDay(for: .now)
    @State private var detail: AgendaEvent?
    @State private var selection = PageSelection()
    /// A month the snapshot doesn't cover, read from Calendar while the page is open.
    @State private var live: (calendars: [AgendaCalendar], events: [AgendaEvent])?

    private var calendar: Calendar { .current }

    var body: some View {
        let source = data
        let events = AgendaGrid.events(on: day, in: source.events, calendar: calendar)
        PageScaffold(app: app, id: .agenda,
                     footer: detail == nil ? ["↩ opens", "←→ month", "Esc back"] : ["← or Esc back to the day"],
                     keys: detail == nil ? [.up, .down, .enter, .left, .right] : [.escape, .left, .right],
                     onKey: { key in
                         switch AgendaNavigation.move(key, detailOpen: detail != nil) {
                         case .select(let direction): selection.move(direction, count: events.count)
                         case .open: detail = selection.current(in: events)
                         case .back: detail = nil
                         case .month(let by): shift(by)
                         case .none: break
                         }
                     }) {
            HStack(alignment: .top, spacing: Spacing.base) {
                Group {
                    if let detail {
                        EventDetail(event: detail, calendars: source.calendars, back: { self.detail = nil },
                                    view: { app.mac.openEvent(detail.id) })
                    } else {
                        DayList(app: app, day: day, events: events, calendars: source.calendars,
                                selected: selection.index) { detail = $0 }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                MonthGrid(month: month, selected: day,
                          dots: AgendaGrid.daysWithEvents(source.events, in: month, calendar: calendar),
                          pick: { picked in day = picked; detail = nil; selection = PageSelection() },
                          shift: shift)
                    .frame(width: 224)
            }
        } actions: {
            Button("Open Calendar") { app.mac.openApp(.agenda) }.buttonStyle(PrimaryButtonStyle())
        }
        .onChange(of: month) { _, _ in loadLive() }
        // A new snapshot (an event added, the range moved): read the shown month again.
        .onChange(of: app.snapshots.agenda?.updatedAt) { _, _ in loadLive() }
        .onAppear { loadLive() }
    }

    /// The snapshot's events, or the live month when the snapshot doesn't reach it.
    private var data: (calendars: [AgendaCalendar], events: [AgendaEvent]) {
        if let live { return live }
        let s = app.snapshots.agenda?.data
        return (s?.calendars ?? [], s?.events ?? [])
    }

    private func shift(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month),
              let start = calendar.dateInterval(of: .month, for: next)?.start else { return }
        month = start
        // Today when the month has it, else the 1st.
        let today = calendar.startOfDay(for: .now)
        day = calendar.isDate(today, equalTo: start, toGranularity: .month) ? today : start
        selection = PageSelection()
        detail = nil
    }

    /// The snapshot when it covers the whole month, else Calendar itself (empty without access: then the
    /// snapshot's part of the month still shows).
    private func loadLive() {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }
        if let s = app.snapshots.agenda?.data, interval.start >= s.from, interval.end <= s.to {
            live = nil
        } else {
            let read = app.mac.month(month)
            live = read.calendars.isEmpty ? nil : read
        }
    }
}

/// The selected day's events: a calendar colour bar, "now" in orange on the running one, past ones faded.
private struct DayList: View {
    let app: AppModel
    let day: Date
    let events: [AgendaEvent]
    let calendars: [AgendaCalendar]
    let selected: Int?
    let open: (AgendaEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PageGroup(title: Self.title(day))
            if events.isEmpty {
                Text("Nothing on this day").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
            } else {
                PageList(app: app, selected: selected.flatMap { events.indices.contains($0) ? events[$0].id : nil }) {
                    VStack(spacing: 2) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            EventRow(event: event, day: day, color: color(event), focused: selected == index) {
                                open(event)
                            }
                            .id(event.id)
                        }
                    }
                }
            }
        }
    }

    private func color(_ e: AgendaEvent) -> Color {
        calendars.first { $0.id == e.calendar }.flatMap { RGB(hex: $0.color)?.color } ?? StripLayout.tint(.agenda).color
    }

    /// "Today", "Tomorrow", "Saturday 24 October".
    static func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f.string(from: day)
    }
}

private struct EventRow: View {
    let event: AgendaEvent
    let day: Date
    let color: Color
    let focused: Bool
    let open: () -> Void

    var body: some View {
        let now = Date()
        let running = !event.allDay && event.start <= now && now < event.end
        let past = event.end <= now
        KitRow(title: event.title.isEmpty ? "(no title)" : event.title,
               subtitle: AgendaGrid.timeText(event, on: day, calendar: .current),
               detail: running ? Text("now").foregroundStyle(K.amber) + Text("  " + AgendaGrid.timeText(event, on: day, calendar: .current))
                               : nil,
               focused: focused, stacked: true) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 3, height: 28)
        } trailing: {
            if event.url != nil { Icon(icon: .videoCamera, size: 14).foregroundStyle(K.text3) }
            else if event.location != nil { Icon(icon: .mapPin, size: 14).foregroundStyle(K.text3) }
        } action: {
            open()
        }
        .opacity(past ? 0.45 : 1)
    }
}

/// Title, calendar, when, where, the link as text, the notes; "View details" opens it in Calendar.
private struct EventDetail: View {
    let event: AgendaEvent
    let calendars: [AgendaCalendar]
    let back: () -> Void
    let view: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                KitIconButton(icon: .caretLeft, help: "Back (Esc)", action: back)
                Text(event.title.isEmpty ? "(no title)" : event.title).font(KFont.row).foregroundStyle(K.text1)
                    .lineLimit(2)
            }
            line(calendars.first { $0.id == event.calendar }?.name)
            line(when)
            if let location = event.location { label(.mapPin, location) }
            if let url = event.url { label(.videoCamera, url) }
            if let notes = event.notes {
                ScrollView(.vertical) {
                    Text(notes).font(KFont.secondary).foregroundStyle(K.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            Button("View details", action: view).buttonStyle(GlassButtonStyle())
        }
    }

    private var when: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let cal = Calendar.current
        let day = f.string(from: event.start)
        if event.allDay { return "\(day) · All day" }
        let start = MacBuilders.clock(event.start, cal), end = MacBuilders.clock(event.end, cal)
        if cal.isDate(event.start, inSameDayAs: event.end) { return "\(day) · \(start) – \(end)" }
        return "\(day) \(start) – \(f.string(from: event.end)) \(end)"
    }

    @ViewBuilder private func line(_ text: String?) -> some View {
        if let text { Text(text).font(KFont.secondary).foregroundStyle(K.text2) }
    }

    private func label(_ icon: PhosphorIcon, _ text: String) -> some View {
        HStack(spacing: 6) {
            Icon(icon: icon, size: 13).foregroundStyle(K.text3)
            Text(text).font(KFont.secondary).foregroundStyle(K.text2).lineLimit(2).textSelection(.enabled)
        }
    }
}

/// The month, Monday first: today in a red disc, the selected day ringed, a dot under days with events.
private struct MonthGrid: View {
    let month: Date
    let selected: Date
    let dots: Set<Int>
    let pick: (Date) -> Void
    let shift: (Int) -> Void

    var body: some View {
        let cal = Calendar.current
        let weeks = AgendaGrid.month(containing: month, calendar: cal)
        VStack(spacing: 4) {
            HStack {
                Text(Self.title(month)).font(KFont.row).foregroundStyle(K.text1)
                Spacer()
                KitIconButton(icon: .caretLeft, help: "Previous month (←)") { shift(-1) }
                KitIconButton(icon: .caretRight, help: "Next month (→)") { shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(KFont.meta).foregroundStyle(K.text3)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks.indices, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in
                        if let date = weeks[w][d] {
                            DayCell(date: date, today: cal.isDateInToday(date),
                                    selected: cal.isDate(date, inSameDayAs: selected),
                                    dot: dots.contains(cal.component(.day, from: date))) { pick(date) }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 28)
                        }
                    }
                }
            }
        }
    }

    static func title(_ month: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f.string(from: month)
    }
}

private struct DayCell: View {
    let date: Date
    let today: Bool
    let selected: Bool
    let dot: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 1) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(KFont.meta.weight(today ? .semibold : .regular))
                    .foregroundStyle(today ? K.text1 : K.text2)
                    .frame(width: 22, height: 22)
                    .background(today ? K.red : .clear, in: Circle())
                    .overlay { if selected && !today { Circle().strokeBorder(K.glassHighlight, lineWidth: 1) } }
                Circle().fill(dot ? K.text3 : .clear).frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
