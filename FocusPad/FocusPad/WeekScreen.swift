import SwiftUI
import SwiftData
import FocusCore

/// The last seven days at a glance: each day as a midnight-to-midnight strip
/// with its focus total, then where the week's hours went by category.
struct WeekView: View {
    @EnvironmentObject private var engine: FocusTimerEngine
    @EnvironmentObject private var settings: PadSettings
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    let open: (Date) -> Void

    private struct Day: Identifiable {
        var date: Date
        var rows: [LogRow]
        var id: Date { date }
        var focus: Double { rows.filter(\.isFocus).map(\.minutes).reduce(0, +) }
        var tracked: Double { rows.map(\.minutes).reduce(0, +) }
    }

    private func days(ending end: Date, count: Int) -> [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: end)
        let first = cal.date(byAdding: .day, value: -(count - 1), to: today)!
        let relevant = sessions.filter { $0.startTime > first.addingTimeInterval(-86400) }
        return (0..<count).reversed().map { back in
            let date = cal.date(byAdding: .day, value: -back, to: today)!
            let next = cal.date(byAdding: .day, value: 1, to: date)!
            let rows = LogRow.rows(relevant.filter { $0.startTime < next && $0.startTime > date.addingTimeInterval(-86400) },
                                   engine: engine, day: date)
            return Day(date: date, rows: rows)
        }
    }

    var body: some View {
        let week = days(ending: Date(), count: 7)
        let before = days(ending: Calendar.current.date(byAdding: .day, value: -7, to: Date())!, count: 7)
        List {
            headline(week, before)
            Section {
                ForEach(week.reversed()) { day in
                    Button { open(day.date) } label: { dayRow(day) }
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Day by day")
            } footer: {
                Text("Tap a day to see its log.")
            }
            categories(week, before)
        }
        .listStyle(.insetGrouped)
        .readableWidth()
    }

    private func headline(_ week: [Day], _ before: [Day]) -> some View {
        let focus = week.map(\.focus).reduce(0, +)
        let last = before.map(\.focus).reduce(0, +)
        let goalDays = week.filter { $0.focus >= Double(settings.dailyGoalHours) * 60 }.count
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(durationText(minutes: focus)).font(.title2.weight(.semibold).monospacedDigit())
                    Text("focus in the last 7 days").foregroundStyle(Color.secondaryText)
                }
                Text(summaryLine(focus: focus, last: last, goalDays: goalDays))
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryLine(focus: Double, last: Double, goalDays: Int) -> String {
        var parts = ["\(durationText(minutes: focus / 7)) a day"]
        if last > 0 {
            let diff = focus - last
            if abs(diff) >= 30 {
                parts.append("\(durationText(minutes: abs(diff))) \(diff > 0 ? "more" : "less") than the week before")
            } else {
                parts.append("about the same as the week before")
            }
        }
        parts.append("\(settings.dailyGoalHours)h goal hit on \(goalDays) of 7 days")
        return parts.joined(separator: " · ")
    }

    private func dayRow(_ day: Day) -> some View {
        let cal = Calendar.current
        let name = cal.isDateInToday(day.date) ? "Today"
            : day.date.formatted(.dateTime.weekday(.abbreviated).day())
        let met = day.focus >= Double(settings.dailyGoalHours) * 60
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).fontWeight(.semibold)
                Spacer()
                if met { Image(systemName: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
                Text(day.focus > 0 ? "\(durationText(minutes: day.focus)) focus" : "No focus")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondaryText)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            MiniStrip(rows: day.rows, day: day.date)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func categories(_ week: [Day], _ before: [Day]) -> some View {
        let now = totalsByName(week)
        let then = totalsByName(before)
        let sorted = now.sorted { $0.value > $1.value }
        let tracked = week.map(\.tracked).reduce(0, +)
        let elapsed = week.map { d in min(Date(), d.date.addingTimeInterval(86400)).timeIntervalSince(d.date) / 60 }.reduce(0, +)
        let top = sorted.first?.value ?? 1
        Section {
            if sorted.isEmpty { Text("Nothing logged this week.").foregroundStyle(Color.secondaryText) }
            ForEach(sorted, id: \.key) { name, minutes in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name)
                        Spacer()
                        if let prev = then[name], abs(minutes - prev) >= 30 {
                            Text("\(minutes > prev ? "+" : "−")\(durationText(minutes: abs(minutes - prev)))")
                                .font(.caption.monospacedDigit()).foregroundStyle(Color.secondaryText)
                        }
                        Text(durationText(minutes: minutes)).font(.subheadline.monospacedDigit())
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(name == "Break" ? FocusColors.breakBlue : categoryColor(name))
                            .frame(width: max(3, geo.size.width * minutes / top))
                    }
                    .frame(height: 6)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Where the week went")
        } footer: {
            if elapsed > 0 {
                Text("\(Int((tracked / elapsed * 100).rounded()))% of the week tracked. Changes are against the 7 days before.")
            }
        }
    }

    private func totalsByName(_ days: [Day]) -> [String: Double] {
        var out: [String: Double] = [:]
        for row in days.flatMap(\.rows) { out[row.name, default: 0] += row.minutes }
        return out
    }
}

private extension LogRow {
    var isFocus: Bool { label.map { !FocusCategories.isLife($0) } ?? false }
}

/// A thinner day strip without hour labels, for the week list.
private struct MiniStrip: View {
    let rows: [LogRow]
    let day: Date

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill))
                ForEach(1..<4) { q in
                    Rectangle().fill(Color(.separator)).frame(width: 1)
                        .offset(x: geo.size.width * Double(q) / 4)
                }
                ForEach(rows) { row in
                    Rectangle()
                        .fill(row.label.map(categoryColor) ?? FocusColors.breakBlue)
                        .frame(width: max(1, row.end.timeIntervalSince(row.start) / 86400 * geo.size.width))
                        .offset(x: row.start.timeIntervalSince(day) / 86400 * geo.size.width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
    }
}
