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

    private var headline: String? {
        var parts: [String] = []
        let rows = courses
        if let top = rows.first {
            var line = "\(top.code) got the most study time (\(durationText(minutes: top.minutes)) on screen)"
            if let p = top.practice {
                line += p < 0.25 ? ", mostly reading and asking AI" : p >= 0.5 ? ", much of it solving on your own" : ""
            }
            parts.append(line + ".")
            if rows.count > 1 { parts.append("\(rows[1].code) had \(durationText(minutes: rows[1].minutes)).") }
        } else if let top = trackedByCategory.first {
            parts.append("\(top.label) got the most tracked time: \(durationText(minutes: top.minutes)).")
        }
        if let stale = quiet.compactMap({ q in q.last.map { (q.label, $0) } }).max(by: { $0.1 < $1.1 }) {
            parts.append("Nothing on \(stale.0) since \(stale.1.formatted(.dateTime.month(.abbreviated).day())).")
        }
        if let last = lastLeetCode, leetCodeThisWeek == 0 {
            parts.append("No LeetCode since \(last.formatted(.dateTime.month(.abbreviated).day())).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Courses and goals

    private var coursesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Courses and goals", subtitle: "How long each course was on your screen this week, as the coach saw it, and its next exam. Below: what your timer logged and goals that went quiet.")
            let rows = courses
            if rows.isEmpty {
                Text("No course work seen this week. Course time shows up once the cloud coach has watched some study.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
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
                     : trackedByCategory.map { "\($0.label) \(durationText(minutes: $0.minutes))" }.joined(separator: " · ")))
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
                ForEach(quiet.prefix(4), id: \.label) { q in
                    HStack(spacing: 8) {
                        Circle().fill(categoryColor(q.label)).frame(width: 6, height: 6)
                        Text(q.last.map { "\(q.label): nothing this week, last on \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                             ?? "\(q.label): never tracked")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                }
                Text(leetCodeThisWeek > 0 ? "LeetCode: \(leetCodeThisWeek) solved this week"
                     : lastLeetCode.map { "LeetCode: none this week, last on \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                     ?? "LeetCode: none logged yet")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
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
        if row.shaky > 0 { bits.append(row.shaky == 1 ? "1 thing looked shaky" : "\(row.shaky) things looked shaky") }
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

    private func examText(_ exam: ClassCalendar.Exam) -> String {
        let d = daysUntil(exam.date)
        let when = d <= 0 ? "today" : d == 1 ? "tomorrow" : "in \(d) days"
        return "\(exam.title) \(when)"
    }

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
