import SwiftUI
import Charts
import FocusCore

/// Everything about one stretch of days needed for the week card.
struct WeekLedger {
    struct Night { let start: Date; let end: Date; var hours: Double { end.timeIntervalSince(start) / 3600 } }

    let days: [Date]
    let from: Date
    let to: Date
    let minutesByCategory: [String: Double]
    /// The categories above in the seven groups (`CategoryGroup`).
    let minutesByGroup: [CategoryGroup: Double]
    let untrackedMinutes: Double
    let elapsedMinutes: Double
    let focusMinutes: Double
    let focusBlocks: [WorkSession]
    let nights: [Night]
    /// Minutes from waking to the first focus block, per day that has both.
    let wakeToFocus: [Double]
    let firstFocus: [Date]
    let focusWhileAwayMinutes: Double

    static let breakKey = "Break"

    static func key(_ s: WorkSession) -> String {
        s.type.isBreak ? breakKey : (s.label?.isEmpty == false ? s.label! : "Focus")
    }

    static func group(_ key: String) -> CategoryGroup {
        key == "Focus" ? .learning : CategoryGroup.of(key, isBreak: key == breakKey)
    }

    static func overlap(_ s: WorkSession, _ a: Date, _ b: Date) -> Double {
        let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
        return max(0, min(e, b).timeIntervalSince(max(s.startTime, a))) / 60
    }

    init(store: SessionStore, live: [WorkSession], endDay: Date, days n: Int = 7, presence: [AwaySpan], now: Date = Date()) {
        let cal = Calendar.current
        let last = cal.startOfDay(for: endDay)
        let days = (0..<n).reversed().map { cal.date(byAdding: .day, value: -$0, to: last)! }
        let from = days[0]
        let to = min(cal.date(byAdding: .day, value: 1, to: last)!, now)
        self.days = days
        self.from = from
        self.to = to
        let all = store.sessions + live
        let inWindow = all.filter { Self.overlap($0, from, to) > 0 }

        var byCat: [String: Double] = [:]
        for s in inWindow { byCat[Self.key(s), default: 0] += Self.overlap(s, from, to) }
        minutesByCategory = byCat
        minutesByGroup = byCat.reduce(into: [:]) { $0[Self.group($1.key), default: 0] += $1.value }
        elapsedMinutes = max(0, to.timeIntervalSince(from) / 60)
        untrackedMinutes = to > from ? store.untrackedGaps(from: from, to: to, live: live, minMinutes: 0).reduce(0) { $0 + $1.minutes } : 0
        let focusBlocks = inWindow.filter(\.isFocus)
        self.focusBlocks = focusBlocks
        focusMinutes = focusBlocks.reduce(0) { $0 + Self.overlap($1, from, to) }

        // Nights: Sleep blocks (split at midnight when filled) merged back together.
        var merged: [Night] = []
        let sleeps = all.filter { $0.type == .work && $0.label == "Sleep" }.sorted { $0.startTime < $1.startTime }
        for s in sleeps {
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            if let prev = merged.last, s.startTime.timeIntervalSince(prev.end) <= 45 * 60 {
                merged[merged.count - 1] = Night(start: prev.start, end: max(prev.end, e))
            } else {
                merged.append(Night(start: s.startTime, end: e))
            }
        }
        let windowFrom = from, windowTo = to
        let nights = merged.filter { $0.hours >= 3 && $0.end > windowFrom && $0.end <= windowTo }
        self.nights = nights
        var ttf: [Double] = []
        var first: [Date] = []
        for d in days {
            let dEnd = cal.date(byAdding: .day, value: 1, to: d)!
            let wake = nights.first { $0.end >= d && $0.end < dEnd }?.end
            // Without a logged wake, skip blocks that are really last night's.
            let floor = wake ?? d.addingTimeInterval(4 * 3600)
            if let f = focusBlocks.filter({ $0.startTime >= floor && $0.startTime < dEnd }).map(\.startTime).min() {
                first.append(f)
                if let wake { ttf.append(f.timeIntervalSince(wake) / 60) }
            }
        }
        wakeToFocus = ttf
        firstFocus = first

        var away = 0.0
        for s in focusBlocks {
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            for p in presence where p.end > s.startTime && p.start < e {
                away += max(0, min(e, p.end, windowTo).timeIntervalSince(max(s.startTime, p.start, windowFrom))) / 60
            }
        }
        focusWhileAwayMinutes = away
    }
}

/// Dashboard card: 7 days × 24h, hours by category vs the week before,
/// and the few numbers that explain a week (sleep, first focus, coverage).
struct WhereTimeWentSection: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject private var presence = PresenceMonitor.shared
    let live: [WorkSession]
    let endDay: Date
    let selectedDay: Date
    let onSelectDay: (Date) -> Void

    private let green = Color(red: 0.25, green: 0.72, blue: 0.53)
    private let red = Color(red: 0.96, green: 0.36, blue: 0.36)

    var body: some View {
        let week = WeekLedger(store: store, live: live, endDay: endDay, presence: presence.spans)
        let prevEnd = Calendar.current.date(byAdding: .day, value: -7, to: endDay)!
        let prev = WeekLedger(store: store, live: [], endDay: prevEnd, presence: presence.spans)
        let coverage = week.elapsedMinutes > 0 ? 1 - week.untrackedMinutes / week.elapsedMinutes : 0

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Where time went", subtitle: "Every hour of the last 7 days in seven groups, against the week before. Underlines mark time away from the Mac; click a day to open it.")
                Spacer()
                Text("\(Int((coverage * 100).rounded()))% tracked")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(coverage >= 0.9 ? green : coverage >= 0.6 ? Color.orange : red)
                    .help("Share of the week's hours (so far) that have a category or Break")
            }

            strips(week)
            Divider().opacity(0.5)
            groupTable(week, prev)
            Divider().opacity(0.5)
            WeekByWeekChart(sessions: store.sessions + live, endDay: endDay)
            Divider().opacity(0.5)
            statsGrid(week, prev)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        .id("week-where")
    }

    // MARK: - 7 × 24h strips

    private func strips(_ week: WeekLedger) -> some View {
        let cal = Calendar.current
        let all = store.sessions + live
        return VStack(spacing: 3) {
            ForEach(week.days, id: \.self) { d in
                let dEnd = cal.date(byAdding: .day, value: 1, to: d)!
                let blocks = all.filter { WeekLedger.overlap($0, d, dEnd) > 0 }
                let focus = blocks.filter(\.isFocus).reduce(0) { $0 + WeekLedger.overlap($1, d, dEnd) }
                let isSel = cal.isDate(d, inSameDayAs: selectedDay)
                Button { onSelectDay(d) } label: {
                    HStack(spacing: 6) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 9.5, weight: isSel ? .bold : .medium))
                            .foregroundStyle(isSel ? Color.primary : Color.secondary)
                            .frame(width: 26, alignment: .leading)
                        DayStripRow(day: d, blocks: blocks, away: presence.spans(from: d, to: dEnd))
                            .frame(height: 13)
                        Text(focus >= 1 ? hm(focus) : "–")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(focus >= 1 ? Color.primary : Color.secondary.opacity(0.5))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .help("Show \(d.formatted(.dateTime.weekday(.wide).month().day())) in the day timeline")
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 26)
                GeometryReader { geo in
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text(h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.tertiary)
                            .offset(x: geo.size.width * CGFloat(h) / 24)
                    }
                }
                .frame(height: 10)
                Text("focus").font(.system(size: 7.5)).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
            }
        }
    }

    // MARK: - Hours by group

    /// Always the same seven rows in the same order, so weeks read alike.
    private func groupTable(_ week: WeekLedger, _ prev: WeekLedger) -> some View {
        let groups = CategoryGroup.allCases.filter { (week.minutesByGroup[$0] ?? 0) >= 1 || (prev.minutesByGroup[$0] ?? 0) >= 30 }
        let maxM = max(1, groups.map { week.minutesByGroup[$0] ?? 0 }.max() ?? 1, week.untrackedMinutes)
        let days = max(1, week.elapsedMinutes / 1440)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Text("week").frame(minWidth: 56, alignment: .trailing)
                Text("a day").frame(width: 56, alignment: .trailing)
                Text("vs last week").frame(width: 84, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.secondaryText)
            ForEach(groups, id: \.self) { g in
                let now = week.minutesByGroup[g] ?? 0
                groupRow(name: g.rawValue, color: g.color, inside: inside(g, week), minutes: now, max: maxM,
                         perDay: now / days, delta: now - (prev.minutesByGroup[g] ?? 0), good: g.holdsFocus ? 1 : 0,
                         bold: g.holdsFocus)
            }
            groupRow(name: "Untracked", color: .secondary.opacity(0.5), inside: nil, minutes: week.untrackedMinutes, max: maxM,
                     perDay: week.untrackedMinutes / days, delta: week.untrackedMinutes - prev.untrackedMinutes,
                     good: -1, bold: false)
        }
    }

    /// "Math 7h 30m · Class 6h 12m · HW 1h 5m": what the group held this week.
    private func inside(_ g: CategoryGroup, _ week: WeekLedger) -> String? {
        let parts = week.minutesByCategory.filter { WeekLedger.group($0.key) == g && $0.value >= 1 }
            .sorted { $0.value > $1.value }
        guard !(parts.count == 1 && parts[0].key == g.rawValue), !parts.isEmpty else { return nil }
        return parts.map { "\($0.key) \(hm($0.value))" }.joined(separator: " · ")
    }

    /// `good`: 1 = more is better, -1 = less is better, 0 = neutral.
    private func groupRow(name: String, color: Color, inside: String?, minutes: Double, max maxM: Double, perDay: Double,
                          delta: Double, good: Int, bold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                    .font(.system(size: 13, weight: bold ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(width: 136, alignment: .leading)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.8))
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, minutes / maxM))), height: 8)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 12)
                Text(hm(minutes))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 56, alignment: .trailing)
                Text(hm(perDay))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 56, alignment: .trailing)
                Text(abs(delta) < 15 ? "same" : (delta > 0 ? "+" : "−") + hm(abs(delta)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(abs(delta) < 15 || good == 0 ? Color.secondaryText : (delta > 0) == (good > 0) ? green : red)
                    .frame(width: 84, alignment: .trailing)
            }
            if let inside {
                Text(inside)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
        }
    }

    // MARK: - Stats

    private func statsGrid(_ week: WeekLedger, _ prev: WeekLedger) -> some View {
        let sleepAvg = week.nights.isEmpty ? nil : week.nights.map(\.hours).reduce(0, +) / Double(week.nights.count)
        let bed = circularMean(week.nights.map(\.start))
        let wake = circularMean(week.nights.map(\.end))
        let spread = bedtimeSpread(week.nights.map(\.start))
        let ttf = week.wakeToFocus.isEmpty ? nil : median(week.wakeToFocus)
        let first = circularMean(week.firstFocus)
        let avgBlock = week.focusBlocks.isEmpty ? nil : week.focusBlocks.map(\.durationMinutes).reduce(0, +) / Double(week.focusBlocks.count)
        let focusDelta = week.focusMinutes - prev.focusMinutes

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                stat(hm(week.focusMinutes), "focus",
                     sub: abs(focusDelta) >= 15 ? "\(focusDelta > 0 ? "+" : "−")\(hm(abs(focusDelta))) vs last wk" : "same as last wk",
                     subColor: abs(focusDelta) < 15 ? .secondary : focusDelta > 0 ? green : red)
                stat(sleepAvg.map { String(format: "%.1fh", $0) } ?? "–", "avg sleep",
                     sub: week.nights.isEmpty ? "log Sleep to see this" : "\(week.nights.count) night\(week.nights.count == 1 ? "" : "s")")
                stat(bed.map(clock) ?? "–", "bedtime",
                     sub: spread.map { "±\(Int($0))m" + (wake.map { " · up \(clock($0))" } ?? "") } ?? (wake.map { "up \(clock($0))" } ?? ""))
            }
            HStack(spacing: 0) {
                stat(first.map(clock) ?? "–", "first focus",
                     sub: ttf.map { "\(hm($0)) after waking" } ?? "")
                stat(avgBlock.map { hm($0) } ?? "–", "avg focus block",
                     sub: week.focusBlocks.isEmpty ? "" : "\(week.focusBlocks.count) blocks")
                stat(week.focusWhileAwayMinutes >= 15 ? hm(week.focusWhileAwayMinutes) : "–", "focus while away",
                     sub: "Mac idle or locked",
                     help: "Focus time logged while this Mac was locked, asleep or untouched. Fine for paper work; otherwise a timer left running.")
            }
        }
    }

    private func stat(_ value: String, _ label: String, sub: String, subColor: Color = .secondary, help: String? = nil) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(sub).font(.system(size: 8.5)).foregroundStyle(subColor).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .help(help ?? "")
    }

    // MARK: - Helpers

    private func hm(_ m: Double) -> String {
        let h = Int(m.rounded()) / 60, mn = Int(m.rounded()) % 60
        return h > 0 ? (mn > 0 ? "\(h)h \(mn)m" : "\(h)h") : "\(mn)m"
    }

    private func clock(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
    }

    /// Mean time of day, wrapping around midnight (11pm and 1am average to midnight).
    private func circularMean(_ dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        let cal = Calendar.current
        var x = 0.0, y = 0.0
        for d in dates {
            let a = d.timeIntervalSince(cal.startOfDay(for: d)) / 86400 * 2 * .pi
            x += cos(a); y += sin(a)
        }
        var a = atan2(y, x)
        if a < 0 { a += 2 * .pi }
        return cal.startOfDay(for: Date()).addingTimeInterval(a / (2 * .pi) * 86400)
    }

    /// Standard deviation of bedtime in minutes, measured from noon so late nights don't wrap.
    private func bedtimeSpread(_ dates: [Date]) -> Double? {
        guard dates.count >= 3 else { return nil }
        let cal = Calendar.current
        let m = dates.map { d -> Double in
            let mins = d.timeIntervalSince(cal.startOfDay(for: d)) / 60
            return mins < 720 ? mins + 1440 : mins
        }
        let mean = m.reduce(0, +) / Double(m.count)
        return (m.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(m.count)).squareRoot()
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// One day, midnight to midnight: tracked blocks in their group's colour, a thin
/// grey rule under the stretches when nobody was at the Mac.
private struct DayStripRow: View {
    let day: Date
    let blocks: [WorkSession]
    let away: [AwaySpan]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x: (Date) -> CGFloat = { CGFloat(max(0, min(86400, $0.timeIntervalSince(day))) / 86400) * w }
            let now = Date()
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.07))
                ForEach([6, 12, 18], id: \.self) { hr in
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 0.5, height: h).offset(x: w * CGFloat(hr) / 24)
                }
                ForEach(blocks) { s in
                    let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
                    Rectangle()
                        .fill(WeekLedger.group(WeekLedger.key(s)).color)
                        .opacity(s.isFocus ? 1 : 0.55)
                        .frame(width: max(1, x(e) - x(s.startTime)), height: h - 3)
                        .offset(x: x(s.startTime))
                }
                ForEach(away) { a in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: max(1, x(a.end) - x(a.start)), height: 2)
                        .offset(x: x(a.start), y: h - 2)
                }
                if Calendar.current.isDate(now, inSameDayAs: day) {
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1, height: h).offset(x: x(now))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

/// The seven groups week by week: hours a day in each, stacked to 24 h with
/// the untracked rest in grey, so any stretch of weeks reads the same way.
/// Old blocks count under their group by the fixed table (`CategoryGroup`).
struct WeekByWeekChart: View {
    let sessions: [WorkSession]
    let endDay: Date
    var weeks = 8

    struct Slice: Identifiable {
        let week: Date
        let name: String
        let color: Color
        let hoursPerDay: Double
        var id: String { "\(week.timeIntervalSince1970)|\(name)" }
    }

    @State private var selected: Date?

    var body: some View {
        let slices = Self.slices(sessions: sessions, endDay: endDay, weeks: weeks)
        VStack(alignment: .leading, spacing: 8) {
            Text("Week by week")
                .font(.system(size: 13, weight: .semibold))
            Text("Hours a day in each group over the last \(weeks) weeks; grey is untracked. Hover a week for its numbers.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Chart {
                ForEach(slices) { s in
                    BarMark(x: .value("Week", s.week, unit: .weekOfYear), y: .value("Hours a day", s.hoursPerDay))
                        .foregroundStyle(s.color)
                        .opacity(selected == nil || Calendar.current.isDate(s.week, equalTo: selected!, toGranularity: .weekOfYear) ? 1 : 0.4)
                }
                if let sel = selected, let week = slices.map(\.week).last(where: { $0 <= sel }) {
                    RuleMark(x: .value("Week", week, unit: .weekOfYear))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            readout(slices.filter { $0.week == week }, week: week)
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartYScale(domain: 0...24)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 6, 12, 18, 24]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
            }
            .frame(height: 180)
        }
    }

    private func readout(_ parts: [Slice], week: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Week of " + week.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 12, weight: .semibold))
            ForEach(parts.filter { $0.hoursPerDay >= 0.05 }) { p in
                HStack(spacing: 5) {
                    Circle().fill(p.color).frame(width: 6, height: 6)
                    Text("\(p.name) \(durationText(minutes: p.hoursPerDay * 60)) a day").font(.system(size: 11)).monospacedDigit()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.secondary))
    }

    static func slices(sessions: [WorkSession], endDay: Date, weeks: Int, now: Date = Date(),
                       calendar cal: Calendar = .current) -> [Slice] {
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: endDay)?.start else { return [] }
        var out: [Slice] = []
        for k in (0..<weeks).reversed() {
            guard let start = cal.date(byAdding: .weekOfYear, value: -k, to: thisWeek),
                  let next = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { continue }
            let end = min(next, now)
            guard end > start else { continue }
            let days = end.timeIntervalSince(start) / 86400
            var byGroup: [CategoryGroup: Double] = [:]
            for s in sessions {
                let m = WeekLedger.overlap(s, start, end)
                if m > 0 { byGroup[WeekLedger.group(WeekLedger.key(s)), default: 0] += m }
            }
            var tracked = 0.0
            for g in CategoryGroup.allCases {
                let m = byGroup[g] ?? 0
                tracked += m
                if m > 0 { out.append(Slice(week: start, name: g.rawValue, color: g.color, hoursPerDay: m / 60 / days)) }
            }
            let untracked = max(0, days * 24 - tracked / 60) / days
            out.append(Slice(week: start, name: "Untracked", color: Color.secondary.opacity(0.18), hoursPerDay: untracked))
        }
        return out
    }
}
