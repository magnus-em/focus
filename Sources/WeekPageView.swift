import Charts
import FocusCore
import SwiftUI

/// The week's day stories, built off the main thread for the Week page.
@MainActor
final class WeekStoryModel: ObservableObject {
    struct Day: Identifiable {
        let date: Date
        let story: DayStory.Story
        var id: Date { date }
    }

    @Published private(set) var days: [Day] = []
    private var task: Task<Void, Never>?
    private var key = ""

    func refresh(endDay: Date, sessions: [WorkSession], live: Set<UUID>, focus: Set<String>) {
        let cal = Calendar.current
        let dates = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: endDay)) }
        let newKey = "\(endDay.timeIntervalSince1970)|\(sessions.count)|\(Int(Date().timeIntervalSince1970 / 300))"
        guard newKey != key else { return }
        key = newKey
        let now = Date()
        let inputs: [(Date, [DayStory.Tracked], CoachDay.Record?, [DayStory.CalendarEvent], [DayStory.Screen], [DayStory.Note])] = dates.map { day in
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            let tracked = sessions.filter { $0.startTime < end && $0.startTime.addingTimeInterval($0.durationMinutes * 60) > day }
                .map { DayStory.Tracked(start: $0.startTime, end: $0.startTime.addingTimeInterval($0.durationMinutes * 60),
                                        label: $0.type == .work ? ($0.label ?? "Focus") : "Break",
                                        running: live.contains($0.id)) }
            CoachDayWorker.shared.load(day)
            let events = ClassCalendar.shared.classes(on: day).map {
                DayStory.CalendarEvent(start: $0.start, end: $0.end, title: $0.title)
            }
            let (screen, notes) = DayStoryModel.screen(from: day, to: min(end, now))
            return (day, tracked, CoachDayWorker.shared.record(for: day), events, screen, notes)
        }
        let prefixes = ClassCalendar.shared.coursePrefixes
        let context = CoachDayWorker.courseContext(for: dates)
        task?.cancel()
        task = Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                inputs.map { day, tracked, record, events, screen, notes in
                    let observations = DayStoryModel.observations(for: day)
                    return Day(date: day, story: DayStory.build(day: day, now: now, tracked: tracked, record: record,
                                                                observations: observations, events: events, screen: screen,
                                                                notes: notes, focus: focus, coursePrefixes: prefixes,
                                                                course: CoachCourse.resolver(observations, context: context)))
                }
            }.value
            guard !Task.isCancelled else { return }
            self?.days = built
        }
    }
}

/// Where the week's time went against courses, exams and interview prep,
/// and which days still have something to fix.
struct WeekPage: View {
    let endDay: Date
    let sessions: [WorkSession]
    let live: Set<UUID>
    let problems: [ProblemEntry]
    let focus: Set<String>
    @ObservedObject var settings: AppSettings
    let onSelectDay: (Date) -> Void

    @StateObject private var model = WeekStoryModel()
    @ObservedObject private var calendar = ClassCalendar.shared

    private var cal: Calendar { Calendar.current }
    private var start: Date { cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: endDay))! }
    private var end: Date { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDay))! }

    struct CourseRow: Identifiable {
        var code: String
        var category: String
        var minutes: Double
        var days: Int
        var activity: [String: Int]
        var shaky: Int
        var id: String { code }
        var observations: Int { activity.values.reduce(0, +) }
        var practice: Double? {
            guard observations >= 5 else { return nil }
            return Double(["solving", "writing", "coding"].reduce(0) { $0 + (activity[$1] ?? 0) }) / Double(observations)
        }
    }

    /// One row per course across the week; a day that called it "CPSC 323" and
    /// one that called it "CPSC 3231" land on the same row, under the name with more time.
    private var courses: [CourseRow] {
        let names = DayStory.weekCourseNames(model.days.map(\.story.courses))
        var rows: [String: CourseRow] = [:]
        for d in model.days {
            for c in d.story.courses {
                let code = names[c.code] ?? c.code
                var row = rows[code] ?? CourseRow(code: code, category: c.category, minutes: 0, days: 0, activity: [:], shaky: 0)
                row.minutes += c.minutes
                row.days += c.minutes >= 5 ? 1 : 0
                row.shaky += c.shaky.count
                for (k, v) in c.activity { row.activity[k, default: 0] += v }
                rows[code] = row
            }
        }
        return rows.values.filter { $0.minutes >= 10 }.sorted { $0.minutes > $1.minutes }
    }

    private var trackedByCategory: [(label: String, minutes: Double)] {
        var minutes: [String: Double] = [:]
        for s in sessions where s.isFocus {
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            let m = max(0, min(e, end).timeIntervalSince(max(s.startTime, start))) / 60
            if m > 0 { minutes[s.label ?? "Focus", default: 0] += m }
        }
        return minutes.map { ($0.key, $0.value) }.sorted { $0.minutes > $1.minutes }
    }

    /// Focus categories with nothing this week, and when they last had time.
    private var quiet: [(label: String, last: Date?)] {
        let tracked = Set(trackedByCategory.map(\.label))
        return settings.tags.filter { focus.contains($0) && !tracked.contains($0) }.map { label in
            (label, sessions.filter { $0.isFocus && $0.label == label && $0.startTime < start }.map(\.startTime).max())
        }
    }

    private var lastLeetCode: Date? { problems.filter { $0.domain == .swe }.map(\.date).max() }
    private var leetCodeThisWeek: Int { problems.filter { $0.domain == .swe && $0.date >= start && $0.date < end }.count }

    private var dismissed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: DayStoryPage.dismissedKey) ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let line = headline {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The week in short").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                    Text(line)
                        .font(.system(size: 22, weight: .medium)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                }
            }
            coursesCard
            fixesCard
        }
        .onAppear { model.refresh(endDay: endDay, sessions: sessions, live: live, focus: focus) }
        .onChange(of: endDay) { _, _ in model.refresh(endDay: endDay, sessions: sessions, live: live, focus: focus) }
        .onChange(of: sessions.count) { _, _ in model.refresh(endDay: endDay, sessions: sessions, live: live, focus: focus) }
    }

    /// A judgement, not a recap of the card below: the nearest exam and how
    /// its course went, else the course that got the most, then the goal
    /// that's been quiet longest.
    private var headline: String? {
        var parts: [String] = []
        let rows = courses
        if let (row, exam) = rows.lazy.compactMap({ r in nextExam(for: r).map { (r, $0) } })
            .min(by: { $0.1.date < $1.1.date }), daysUntil(exam.date) <= 30 {
            var line = "\(exam.title) is \(examWhen(exam)). \(row.code) had \(durationText(minutes: row.minutes)) on your screen this week"
            if let p = row.practice {
                line += p < 0.25 ? ", mostly reading and asking AI; test yourself more" : p >= 0.5 ? ", much of it solving on your own" : ""
            }
            parts.append(line + ".")
        } else if let top = rows.first {
            var line = "\(top.code) got the most study time (\(durationText(minutes: top.minutes)) on screen)"
            if let p = top.practice {
                line += p < 0.25 ? ", mostly reading and asking AI" : p >= 0.5 ? ", much of it solving on your own" : ""
            }
            parts.append(line + ".")
        } else if let top = trackedByCategory.first {
            parts.append("\(top.label) got the most tracked time: \(durationText(minutes: top.minutes)).")
        }
        if let stale = quiet.compactMap({ q in q.last.map { (q.label, $0) } }).max(by: { $0.1 < $1.1 }) {
            parts.append("Nothing on \(stale.0) since \(stale.1.formatted(.dateTime.month(.abbreviated).day())).")
        }
        if parts.count < 2, let last = lastLeetCode, leetCodeThisWeek == 0 {
            parts.append("No LeetCode since \(last.formatted(.dateTime.month(.abbreviated).day())).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Courses and goals

    private var coursesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Courses and goals", subtitle: "How long each course was on your screen this week, as Focus saw it, and its next exam. Below: what your timer logged and goals that went quiet.")
            let rows = courses
            if rows.isEmpty {
                Text("No course work seen this week. Course time shows up once cloud AI has seen some study.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if !rows.isEmpty {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 8, height: 1)
                    Text("Course").frame(width: 96, alignment: .leading)
                    Text("On screen").frame(width: 70, alignment: .leading)
                    Text("How you studied").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Next exam")
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryText)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Circle().fill(categoryColor(row.category)).frame(width: 8, height: 8)
                    Text(row.code).font(.system(size: 14, weight: .semibold)).frame(width: 96, alignment: .leading)
                    Text(durationText(minutes: row.minutes)).font(.system(size: 14)).monospacedDigit()
                        .frame(width: 70, alignment: .leading)
                    Text(how(row)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let exam = nextExam(for: row) {
                        Text(examText(exam)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(daysUntil(exam.date) <= 3 ? Color.attention : Color.secondaryText)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Your timer's focus time: " + (trackedByCategory.isEmpty ? "none"
                     : trackedByCategory.map { "\($0.label == "Focus" ? "Unlabeled" : $0.label) \(durationText(minutes: $0.minutes))" }
                        .joined(separator: " · ")))
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
                ForEach(quiet.prefix(4), id: \.label) { q in
                    HStack(spacing: 8) {
                        Circle().fill(categoryColor(q.label)).frame(width: 6, height: 6)
                        Text(q.last.map { "\(q.label): nothing this week, last on \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                             ?? "\(q.label): never tracked")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                }
                HStack(spacing: 8) {
                    Circle().fill(categoryColor("SWE")).frame(width: 6, height: 6)
                    Text(leetCodeThisWeek > 0 ? "LeetCode: \(leetCodeThisWeek) solved this week"
                         : lastLeetCode.map { "LeetCode: none this week, last on \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                         ?? "LeetCode: none logged yet")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func how(_ row: CourseRow) -> String {
        var bits: [String] = []
        bits.append(row.days == 1 ? "on 1 day" : "on \(row.days) days")
        if let p = row.practice {
            let top = row.activity.max { $0.value < $1.value }?.key
            let mostly = ["asking-ai": "mostly asking AI", "reading": "mostly reading", "watching": "mostly watching",
                          "solving": "mostly solving", "writing": "mostly writing", "coding": "mostly coding"][top ?? ""]
            bits.append("\(Int((p * 100).rounded()))% solving problems yourself")
            if let mostly, p < 0.5 { bits.append(mostly) }
        }
        if row.shaky > 0 { bits.append(row.shaky == 1 ? "struggled with 1 topic" : "struggled with \(row.shaky) topics") }
        return bits.joined(separator: " · ")
    }

    private func nextExam(for row: CourseRow) -> ClassCalendar.Exam? {
        let number = row.code.split(separator: " ").last.map(String.init) ?? ""
        let sameCategory = courses.filter { $0.category == row.category }.count == 1
        return calendar.exams.first { exam in
            let digits = exam.title.components(separatedBy: CharacterSet.decimalDigits.inverted).first { $0.count >= 3 } ?? ""
            if !digits.isEmpty, !number.isEmpty, digits.hasPrefix(number) || number.hasPrefix(digits) { return true }
            return digits.isEmpty && sameCategory && exam.category == row.category
        }
    }

    private func daysUntil(_ date: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    private func examWhen(_ exam: ClassCalendar.Exam) -> String {
        let d = daysUntil(exam.date)
        return d <= 0 ? "today" : d == 1 ? "tomorrow" : "in \(d) days"
    }

    private func examText(_ exam: ClassCalendar.Exam) -> String { "\(exam.title) \(examWhen(exam))" }

    // MARK: Days to fix

    @ViewBuilder
    private var fixesCard: some View {
        let hidden = dismissed
        let days = model.days.reversed().compactMap { d -> (Date, [DayStory.Fix])? in
            let fixes = d.story.fixes.filter { !hidden.contains($0.id) }
            return fixes.isEmpty ? nil : (d.date, fixes)
        }
        if !days.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Days with something to fix", subtitle: "Days where your log disagrees with your calendar or with what the screen saw. Open one to fix it on its Day page.")
                ForEach(days, id: \.0) { day, fixes in
                    HStack(spacing: 12) {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.system(size: 13, weight: .medium)).frame(width: 140, alignment: .leading)
                        Text(summary(fixes)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open") { onSelectDay(day) }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .frame(minHeight: 36)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        }
    }

    private func summary(_ fixes: [DayStory.Fix]) -> String {
        let minutes = fixes.reduce(0) { $0 + $1.minutes }
        let calendarCount = fixes.filter { if case .calendar = $0.kind { return true }; return false }.count
        let untracked = fixes.filter { if case .untracked = $0.kind { return true }; return false }.count
        let screen = fixes.count - calendarCount - untracked
        var bits = ["\(fixes.count == 1 ? "1 thing" : "\(fixes.count) things"), \(durationText(minutes: minutes)) in all"]
        if calendarCount > 0 { bits.append(calendarCount == 1 ? "a class tracked as something else" : "\(calendarCount) classes tracked as something else") }
        if untracked > 0 { bits.append(untracked == 1 ? "1 gap with nothing logged" : "\(untracked) gaps with nothing logged") }
        if screen > 0 { bits.append(screen == 1 ? "1 stretch the screen saw differently" : "\(screen) stretches the screen saw differently") }
        return bits.joined(separator: " · ")
    }
}

/// Focus hours over a week, month, quarter or year. Bars are hours per day
/// at every zoom (a day, or a week's/month's daily average) so the goal line
/// reads the same everywhere.
struct FocusHistorySection: View {
    let sessions: [WorkSession]
    let goalHours: Double

    enum Range: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", quarter = "3 Months", year = "Year"
        var id: String { rawValue }
    }

    struct Bar: Identifiable {
        let start: Date
        let label: String
        let hoursPerDay: Double
        var id: String { "\(start.timeIntervalSince1970)|\(label)" }
    }

    struct Summary {
        var bars: [Bar] = []
        var buckets: [Date] = []
        var totalMinutes: Double = 0
        var days = 0
        var daysAtGoal = 0
        var previousPerDay: Double?
    }

    @AppStorage("focusHistoryRange") private var range: Range = .month
    @State private var summary = Summary()
    @State private var selected: Date?

    private var unit: Calendar.Component {
        switch range {
        case .week, .month: return .day
        case .quarter: return .weekOfYear
        case .year: return .month
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                SectionTitle("How much you focused",
                             subtitle: "Hours per day in your focus categories on the timer; life time and breaks don't count")
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            facts
            chart.frame(height: 200)
        }
        .onAppear(perform: refresh)
        .onChange(of: range) { _, _ in selected = nil; refresh() }
        .onChange(of: sessions.count) { _, _ in refresh() }
    }

    private var facts: some View {
        let perDay = summary.days > 0 ? summary.totalMinutes / Double(summary.days) : 0
        return HStack(alignment: .top, spacing: 36) {
            fact("Total", durationText(minutes: summary.totalMinutes), "over \(summary.days) day\(summary.days == 1 ? "" : "s")")
            fact("Per day", durationText(minutes: perDay), comparison(perDay))
            fact("Days at your \(goalHours.formatted())h goal", "\(summary.daysAtGoal) of \(summary.days)",
                 summary.days > 0 ? "\(Int((Double(summary.daysAtGoal) / Double(summary.days) * 100).rounded()))% of days" : "")
            Spacer(minLength: 0)
        }
    }

    private func comparison(_ perDay: Double) -> String {
        guard let prev = summary.previousPerDay, prev > 0 else { return "No earlier \(range.rawValue.lowercased()) to compare" }
        let change = (perDay - prev) / prev
        let pct = Int((abs(change) * 100).rounded())
        let span = range == .quarter ? "3 months" : range.rawValue.lowercased()
        if pct < 3 { return "About the same as the \(span) before" }
        return "\(change > 0 ? "Up" : "Down") \(pct)% from \(durationText(minutes: prev)) the \(span) before"
    }

    private func fact(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    private var chart: some View {
        Chart {
            ForEach(summary.bars) { b in
                BarMark(x: .value("When", b.start, unit: unit), y: .value("Hours per day", b.hoursPerDay))
                    .foregroundStyle(categoryColor(b.label))
                    .opacity(selected == nil || Calendar.current.isDate(b.start, equalTo: selected!, toGranularity: unit) ? 1 : 0.4)
            }
            RuleMark(y: .value("Goal", goalHours))
                .foregroundStyle(Color.secondaryText.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("\(goalHours.formatted())h goal").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            if let s = selected, let bucket = summary.buckets.last(where: { $0 <= s }) {
                RuleMark(x: .value("When", bucket, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(bucket)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let h = v.as(Double.self) { Text("\(h.formatted())h") } }
            }
        }
        .chartXAxis {
            switch range {
            case .week: AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) }
            case .month: AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
            case .quarter: AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) }
            case .year: AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) }
            }
        }
    }

    private func readout(_ bucket: Date) -> some View {
        let parts = summary.bars.filter { $0.start == bucket }.sorted { $0.hoursPerDay > $1.hoursPerDay }
        let total = parts.reduce(0) { $0 + $1.hoursPerDay }
        let when: String = switch range {
        case .week, .month: bucket.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .quarter: "Week of " + bucket.formatted(.dateTime.month(.abbreviated).day())
        case .year: bucket.formatted(.dateTime.month(.wide).year())
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(when).font(.system(size: 12, weight: .semibold))
            Text(durationText(minutes: total * 60) + (unit == .day ? "" : " a day")).font(.system(size: 12)).monospacedDigit()
            ForEach(parts) { p in
                HStack(spacing: 5) {
                    Circle().fill(categoryColor(p.label)).frame(width: 6, height: 6)
                    Text("\(p.label) \(durationText(minutes: p.hoursPerDay * 60))").font(.system(size: 11)).monospacedDigit()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.secondary))
    }

    private func refresh() {
        summary = Self.build(sessions: sessions, range: range, unit: unit, goalHours: goalHours)
    }

    static func build(sessions: [WorkSession], range: Range, unit: Calendar.Component, goalHours: Double,
                      now: Date = Date(), calendar cal: Calendar = .current) -> Summary {
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let periodStart: Date = switch range {
        case .week: cal.date(byAdding: .day, value: -6, to: today)!
        case .month: cal.date(byAdding: .day, value: -29, to: today)!
        case .quarter: cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .weekOfYear, value: -12, to: today)!)!.start
        case .year: cal.dateInterval(of: .month, for: cal.date(byAdding: .month, value: -11, to: today)!)!.start
        }
        let previousStart = cal.date(byAdding: .day, value: -(cal.dateComponents([.day], from: periodStart, to: tomorrow).day ?? 0), to: periodStart)!

        let focus = sessions.filter(\.isFocus)
        guard let firstDay = focus.map({ cal.startOfDay(for: $0.startTime) }).min() else { return Summary() }

        var byDay: [Date: [String: Double]] = [:]
        for s in focus {
            var a = max(s.startTime, previousStart)
            let end = min(s.startTime.addingTimeInterval(s.durationMinutes * 60), now)
            while a < end {
                let day = cal.startOfDay(for: a)
                let next = cal.date(byAdding: .day, value: 1, to: day)!
                byDay[day, default: [:]][s.label ?? "Focus", default: 0] += min(end, next).timeIntervalSince(a) / 60
                a = next
            }
        }

        var out = Summary()
        let start = max(periodStart, firstDay)
        var day = start
        while day < tomorrow {
            let m = byDay[day]?.values.reduce(0, +) ?? 0
            out.totalMinutes += m
            out.days += 1
            if m >= goalHours * 60 { out.daysAtGoal += 1 }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        var bucket = cal.dateInterval(of: unit, for: start)!.start
        while bucket < tomorrow {
            let next = cal.date(byAdding: unit, value: 1, to: bucket)!
            let from = max(bucket, start), to = min(next, tomorrow)
            let days = max(1, cal.dateComponents([.day], from: from, to: to).day ?? 1)
            var totals: [String: Double] = [:]
            var d = from
            while d < to {
                for (k, v) in byDay[d] ?? [:] { totals[k, default: 0] += v }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            out.buckets.append(bucket)
            for (k, v) in totals.sorted(by: { $0.value > $1.value }) {
                out.bars.append(Bar(start: bucket, label: k, hoursPerDay: v / 60 / Double(days)))
            }
            bucket = next
        }

        if firstDay < periodStart {
            let from = max(previousStart, firstDay)
            var m = 0.0, n = 0
            var d = from
            while d < periodStart { m += byDay[d]?.values.reduce(0, +) ?? 0; n += 1; d = cal.date(byAdding: .day, value: 1, to: d)! }
            if n > 0 { out.previousPerDay = m / Double(n) }
        }
        return out
    }
}
