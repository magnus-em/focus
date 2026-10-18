import AppKit
import FocusCore
import SwiftUI

/// Builds the Day page's story off the main thread: the coach's day record,
/// the day's observations, tracked sessions (live ones included), calendar
/// classes and the screen's smoothed blocks.
@MainActor
final class DayStoryModel: ObservableObject {
    struct Lanes: Equatable {
        var tracked: [DayStory.Tracked] = []
        var screen: [DayStory.Screen] = []
        var events: [DayStory.CalendarEvent] = []
    }

    @Published private(set) var story: DayStory.Story?
    @Published private(set) var lanes = Lanes()
    @Published private(set) var spent: Double?
    private var task: Task<Void, Never>?

    func refresh(day: Date, sessions: [WorkSession], live: [WorkSession], focus: Set<String>) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let now = Date()
        let tracked = sessions.map { Self.tracked($0, running: false) } + live.map { Self.tracked($0, running: true) }
        let (screen, notes) = Self.screen(from: start, to: min(end, now))
        let events = ClassCalendar.shared.classes(on: day).map {
            DayStory.CalendarEvent(start: $0.start, end: $0.end, title: $0.title)
        }
        let prefixes = ClassCalendar.shared.coursePrefixes
        let context = CoachDayWorker.courseContext(for: [day])
        CoachDayWorker.shared.load(day)
        let record = CoachDayWorker.shared.record(for: day)
        lanes = Lanes(tracked: tracked, screen: screen, events: events)
        task?.cancel()
        task = Task { [weak self] in
            let story = await Task.detached(priority: .userInitiated) {
                let observations = Self.observations(for: day)
                return DayStory.build(day: day, now: now, tracked: tracked, record: record, observations: observations,
                                      events: events, screen: screen, notes: notes, focus: focus, coursePrefixes: prefixes,
                                      course: CoachCourse.resolver(observations, context: context))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.story = story
            self.spent = cal.isDateInToday(day) ? await Coach.budget.spent(on: now) : nil
        }
    }

    /// The Mac's smoothed screen blocks and their on-device notes, for the Day and Week pages alike.
    static func screen(from start: Date, to end: Date) -> (screen: [DayStory.Screen], notes: [DayStory.Note]) {
        let watcher = ScreenWatcher.shared
        guard end > start else { return ([], []) }
        let activities = watcher.activities(from: start, to: end).filter { $0.device == nil }
        let screen = activities.map { DayStory.Screen(start: $0.start, end: $0.end, category: $0.category) }
        let notes = activities.compactMap { a in
            watcher.notes(for: a).map { DayStory.Note(start: a.start, end: a.end, title: $0.title) }
        }
        return (screen, notes)
    }

    private static func tracked(_ s: WorkSession, running: Bool) -> DayStory.Tracked {
        DayStory.Tracked(start: s.startTime, end: s.startTime.addingTimeInterval(s.durationMinutes * 60),
                         label: s.type == .work ? (s.label ?? "Focus") : "Break", running: running)
    }

    /// `Focus/episodes/DATE.jsonl`; browser rows only when the journal confirmed them regular.
    nonisolated static func observations(for day: Date) -> [CoachEpisode.Record] {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/episodes/\(CoachDay.dayKey(day)).jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(CoachEpisode.Record.self, from: Data($0.utf8)) }
            .filter { $0.source.privacy == .notBrowser || $0.source.privacy == .regular }
    }
}

extension Color {
    /// Something to fix: amber #B45309 on light, #F5A524 on dark (never red: red is for errors).
    static let attention = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.961, green: 0.647, blue: 0.141, alpha: 1)
            : NSColor(srgbRed: 0.706, green: 0.325, blue: 0.035, alpha: 1)
    })
}

/// The Dashboard's Day page: a headline, three facts, the day's lanes, the
/// story in blocks with fixes on the row they're about, and what was learned.
struct DayStoryPage: View {
    @ObservedObject var model: DayStoryModel
    let day: Date
    let focusMinutes: Double
    let goalHours: Double
    let commitment: String?
    let categories: [String]
    let apply: (DayStory.Fix, String) -> Void
    let openCoach: () -> Void

    @State private var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    @State private var expanded: Set<Date> = []

    static let dismissedKey = "dayStoryDismissedFixes"
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    private func visible(_ fixes: [DayStory.Fix]) -> [DayStory.Fix] { fixes.filter { !dismissed.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let story = model.story {
                header(story)
                glance(story)
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Timeline", subtitle: "Midnight to midnight: your calendar, what you tracked with the timer, and what was on your Mac's screen.")
                    DayLanesView(lanes: model.lanes, day: day)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        storyColumn(story).frame(minWidth: 500, idealWidth: 560, maxWidth: .infinity, alignment: .leading)
                        side(story).frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        storyColumn(story)
                        side(story)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ story: DayStory.Story) -> some View {
        if let line = story.headline ?? fallbackHeadline(story) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(headlineCaption(story)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                    if story.hasCoach {
                        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .help("Focus uses an AI model (xAI's Grok) to read your timer log and what's on your screen, then writes this summary, the notes under each stretch and what you learned. Settings → AI turns it off.")
                            .accessibilityLabel("About these notes")
                    }
                }
                Text(DayStory.twelveHour(line))
                    .font(.system(size: 22, weight: .medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func headlineCaption(_ story: DayStory.Story) -> String {
        guard story.headline != nil else { return isToday ? "So far today, from your tracking" : "From your tracking" }
        if let asOf = story.headlineAsOf { return "Focus's summary of your timer and screen, written at \(clock(asOf))" }
        return "Focus's summary of your timer and screen"
    }

    private func fallbackHeadline(_ story: DayStory.Story) -> String? {
        let parts = story.courses.prefix(2).map { "\($0.code) for \(durationText(minutes: $0.minutes))" }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + "."
    }

    private func glance(_ story: DayStory.Story) -> some View {
        let fixes = visible(story.fixes)
        return HStack(alignment: .top, spacing: 36) {
            fact("Focus time", durationText(minutes: focusMinutes), goalLine, color: focusMinutes >= goalHours * 60 ? .good : .primary)
            if let top = story.courses.first {
                fact("Most studied", top.code, courseLine(top), color: .primary)
            }
            if !fixes.isEmpty {
                fact("Log check", fixes.count == 1 ? "1 to fix" : "\(fixes.count) to fix",
                     fixSummary(fixes[0]) + (fixes.count > 1 ? ", and \(fixes.count - 1) more below" : "; fix it below"),
                     color: .attention)
            } else if !story.blocks.isEmpty {
                fact("Log check", "Looks right", "Nothing disagrees with your calendar or screen", color: .good)
            }
            Spacer(minLength: 0)
        }
    }

    private var goalLine: String {
        let goal = goalHours * 60
        if focusMinutes >= goal { return "On your timer; your \(goalHours.formatted())h goal is met" }
        return "On your timer, \(durationText(minutes: goal - focusMinutes)) short of your \(goalHours.formatted())h goal"
    }

    private func courseLine(_ c: DayStory.Course) -> String {
        var line = "Seen on your screen for \(durationText(minutes: c.minutes))"
        if let p = c.practiceShare, c.observations >= 5 { line += ", \(Int((p * 100).rounded()))% of that solving problems yourself" }
        return line
    }

    private func fact(_ label: String, _ value: String, _ caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func fixSummary(_ f: DayStory.Fix) -> String {
        switch f.kind {
        case .calendar(let event): return "You tracked \(f.tracked ?? "something else") during \(event) on your calendar"
        case .untracked: return "Nothing logged for \(durationText(minutes: f.minutes)) at \(clock(f.start))"
        case .screenDiffers(let seen): return "The screen showed \(seen) while \(f.tracked ?? "something else") was tracked"
        }
    }

    // MARK: Story

    private func storyColumn(_ story: DayStory.Story) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("How the day went", subtitle: storySubtitle(story)).padding(.bottom, 4)
            if story.blocks.isEmpty {
                Text(isToday ? "Nothing tracked yet today." : "Nothing tracked on this day.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText).padding(.vertical, 12)
            }
            ForEach(Array(story.blocks.reversed().enumerated()), id: \.element.id) { i, block in
                if i > 0 { Divider().padding(.leading, 76) }
                if block.quiet { quietRow(block) } else { blockRow(block) }
            }
        }
    }

    private func storySubtitle(_ story: DayStory.Story) -> String {
        var line = "Each stretch of your day, newest first, and what you did in it; ⚠︎ marks time your log may have wrong."
        if isToday, let asOf = story.headlineAsOf, story.headline != nil {
            line += " Rows after \(clock(asOf)) update as you go."
        }
        return line
    }

    private func quietRow(_ b: DayStory.Block) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(clock(b.start)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
                .frame(width: 64, alignment: .leading)
            Circle().fill(categoryColor(b.category ?? "")).frame(width: 7, height: 7)
            Text("\(b.title) · \(durationText(minutes: span(b)))\(b.moments.first.flatMap { DayStory.restates($0.text, title: b.title) ? nil : " · " + DayStory.twelveHour($0.text) } ?? "")")
                .font(.system(size: 13)).foregroundStyle(Color.secondaryText).lineLimit(1)
        }
        .padding(.vertical, 8)
    }

    private func blockRow(_ b: DayStory.Block) -> some View {
        let showAll = expanded.contains(b.start)
        let moments = showAll ? b.moments : Array(b.moments.prefix(4))
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(clock(b.start)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text(b.running ? "now" : durationText(minutes: span(b)))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
            }
            .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(b.category.map(categoryColor) ?? Color.secondary.opacity(0.25))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(b.title).font(.system(size: 15, weight: .semibold))
                    if let c = b.category, c != b.title {
                        Text(b.event != nil ? "tracked as \(c)" : c).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                    if b.running {
                        Text("Running").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(b.category.map(categoryColor) ?? .accentColor)
                    }
                }
                ForEach(moments) { m in momentRow(m, timed: b.moments.count > 1) }
                if b.moments.count > 4 {
                    Button(showAll ? "Show fewer" : "Show \(b.moments.count - 4) more") {
                        if showAll { expanded.remove(b.start) } else { expanded.insert(b.start) }
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                }
                if !b.interruptions.isEmpty {
                    Text(interruptionLine(b.interruptions))
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(visible(b.fixes)) { fixRow($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }

    private func momentRow(_ m: DayStory.Moment, timed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if timed {
                Text(clock(m.start)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
                    .frame(width: 58, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(DayStory.twelveHour(m.text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let d = m.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(m.asked, id: \.self) { q in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.35)).frame(width: 2)
                        Text("“\(q)”").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func interruptionLine(_ list: [DayStory.Moment]) -> String {
        let minutes = list.reduce(0) { $0 + $1.minutes }
        let names = Array(Set(list.compactMap(\.category)))
        let by = names.count == 1 ? " by \(names[0])" : ""
        let times = list.prefix(6).map { clock($0.start) }.joined(separator: ", ")
        let count = list.count == 1 ? "once" : list.count == 2 ? "twice" : "\(list.count) times"
        return "Interrupted \(count)\(by), \(durationText(minutes: max(minutes, 1))) in all (\(times))"
    }

    // MARK: Fixes

    private func fixRow(_ f: DayStory.Fix) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color.attention)
            Text(message(f)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let s = f.suggestion {
                pill(f.running ? "Switch to \(s)" : (isUntrackedFix(f) ? "Add as \(s)" : "Make it \(s)"), prominent: true) { apply(f, s) }
            }
            if isUntrackedFix(f) {
                Menu {
                    ForEach(categories, id: \.self) { c in Button(c) { apply(f, c) } }
                } label: {
                    Text(f.suggestion == nil ? "Fill…" : "Other…").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Log this stretch as a category")
            }
            pill("Leave it", prominent: false) { dismiss(f) }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func isUntrackedFix(_ f: DayStory.Fix) -> Bool {
        if case .untracked = f.kind { return true }
        return false
    }

    private func message(_ f: DayStory.Fix) -> String {
        let range = "\(clock(f.start))–\(f.running ? "now" : clock(f.end))"
        switch f.kind {
        case .calendar(let event):
            return "Tracked as \(f.tracked ?? "something else") during \(event), \(range)."
        case .untracked(let seen):
            return seen.map { "Nothing logged \(range). The screen showed \($0)." } ?? "Nothing logged \(range)."
        case .screenDiffers(let seen):
            return "The screen showed \(seen) for \(durationText(minutes: f.minutes)) while \(f.tracked ?? "something else") was tracked."
        }
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : .primary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(prominent ? Color.primary : Color.primary.opacity(0.08)))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dismiss(_ f: DayStory.Fix) {
        dismissed.insert(f.id)
        UserDefaults.standard.set(Array(dismissed.suffix(400)), forKey: Self.dismissedKey)
    }

    // MARK: Side column

    private func side(_ story: DayStory.Story) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let commitment, !commitment.isEmpty {
                card {
                    Text("Your commitment").font(.system(size: 14, weight: .semibold))
                    Text(commitment).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(story.courses.prefix(2).enumerated()), id: \.element.id) { i, c in
                courseCard(c, first: i == 0, questions: i == 0 && isToday ? story.questions : 0)
            }
            if !story.noticed.isEmpty {
                card {
                    Text("Focus noticed").font(.system(size: 14, weight: .semibold))
                    ForEach(story.noticed.prefix(3), id: \.self) { n in
                        Text(n).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !story.hasCoach {
                card {
                    Text("Only your tracking").font(.system(size: 14, weight: .semibold))
                    Text("With cloud AI on (Settings → AI), this page also shows what you studied, your own questions and what looked shaky.")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button(action: openCoach) {
                    Label("Ask Focus", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 36)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Talk this day through with Focus")
                if let spent = model.spent {
                    Text("AI notes cost \(spent < 1 ? "\(Int((spent * 100).rounded()))¢" : String(format: "$%.2f", spent)) today")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private func courseCard(_ c: DayStory.Course, first: Bool, questions: Int) -> some View {
        card {
            if first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What you learned").font(.system(size: 14, weight: .semibold))
                    Text("Topics Focus saw you study, by course").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(c.code).font(.system(size: 13, weight: .semibold)).foregroundStyle(categoryColor(c.category))
                Spacer()
                Text(durationText(minutes: c.minutes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
            }
            if !c.topics.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(c.topics.prefix(10), id: \.self) { t in
                        Text(t).font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
            }
            if !c.shaky.isEmpty {
                Text("Where you struggled").font(.system(size: 12, weight: .semibold)).padding(.top, 2)
                ForEach(c.shaky.prefix(3), id: \.self) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Color.attention)
                        Text(s).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
            }
            if c.observations >= 5 { HowStudiedBar(course: c) }
            if questions > 0 {
                Text(questions == 1 ? "1 question waits for tomorrow morning." : "\(questions) questions wait for tomorrow morning.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: Helpers

    private func span(_ b: DayStory.Block) -> Double { b.end.timeIntervalSince(b.start) / 60 }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

/// How a course was studied, from the coach's observations: practice
/// (solving, writing, coding) against reading, watching and asking AI.
struct HowStudiedBar: View {
    let course: DayStory.Course

    private static let order: [(key: String, label: String, weight: Double)] = [
        ("solving", "Solving", 1), ("writing", "Writing", 0.85), ("coding", "Coding", 0.85),
        ("asking-ai", "Asking AI", 0.45), ("reading", "Reading", 0.3), ("watching", "Watching", 0.2),
    ]

    var body: some View {
        let total = Double(max(course.observations, 1))
        let parts = Self.order.compactMap { o -> (String, Double, Double)? in
            guard let n = course.activity[o.key], n > 0 else { return nil }
            return (o.label, Double(n) / total, o.weight)
        }
        let color = categoryColor(course.category)
        VStack(alignment: .leading, spacing: 6) {
            Text("How you studied").font(.system(size: 12, weight: .semibold)).padding(.top, 2)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(color.opacity(p.2)).frame(width: max(2, (geo.size.width - CGFloat(parts.count - 1) * 2) * p.1))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            Text(parts.map { "\($0.0) \(Int(($0.1 * 100).rounded()))%" }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
            if let p = course.practiceShare, p < 0.25 {
                Text("Mostly explanations. Testing yourself is what makes it stick.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A section title (15 semibold) with a one-line description under it, so
/// someone new to the page knows what they're looking at.
struct SectionTitle: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Calendar, tracked time and the screen on one 24-hour scale; pointing at
/// it reads out all three for that minute.
struct DayLanesView: View {
    let lanes: DayStoryModel.Lanes
    let day: Date
    @State private var hover: Date?

    /// Neutral, so a calendar event never reads as the Class category's coral.
    private static let eventColor = Color.primary.opacity(0.2)
    private var start: Date { Calendar.current.startOfDay(for: day) }

    private struct Row: Identifiable {
        let label: String
        let height: CGFloat
        let items: [(Date, Date, Color)]
        var id: String { label }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if !lanes.events.isEmpty {
            rows.append(Row(label: "Calendar", height: 18, items: lanes.events.map { ($0.start, $0.end, Self.eventColor) }))
        }
        rows.append(Row(label: "Tracked", height: 14, items: lanes.tracked.map { ($0.start, $0.end, categoryColor($0.label)) }))
        rows.append(Row(label: "Screen", height: 14,
                        items: lanes.screen.compactMap { s in s.category.map { (s.start, s.end, categoryColor($0)) } }))
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(rows) { r in
                        Text(r.label).font(.system(size: 11)).foregroundStyle(Color.secondaryText).frame(height: r.height)
                    }
                }
                .frame(width: 56, alignment: .trailing)
                GeometryReader { geo in
                    VStack(spacing: 5) {
                        ForEach(rows) { r in lane(r) }
                    }
                    .overlay(alignment: .topLeading) {
                        if let hover {
                            Capsule().fill(Color.primary.opacity(0.7)).frame(width: 2)
                                .offset(x: x(hover, geo.size.width) - 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            hover = start.addingTimeInterval(Double(min(max(p.x / max(geo.size.width, 1), 0), 1)) * 86400)
                        case .ended:
                            hover = nil
                        }
                    }
                }
                .frame(height: rows.reduce(0) { $0 + $1.height + 5 } - 5)
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: 56, height: 1)
                GeometryReader { geo in
                    ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                        Text(h == 0 || h == 24 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p")
                            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                            .fixedSize()
                            .position(x: min(max(geo.size.width * CGFloat(h) / 24, 12), geo.size.width - 12), y: 6)
                    }
                }
                .frame(height: 12)
            }
            HStack(alignment: .top, spacing: 10) {
                Color.clear.frame(width: 56, height: 1)
                FlowLayout(spacing: 12) {
                    ForEach(legend, id: \.self) { label in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(label == "Calendar event" ? Self.eventColor
                                      : label == "Nothing logged" ? Color.primary.opacity(0.06) : categoryColor(label))
                                .frame(width: 10, height: 10)
                            Text(label).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
            .padding(.top, 6)
            HStack(spacing: 10) {
                Color.clear.frame(width: 56, height: 1)
                Text(readout).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(hover == nil ? Color.secondaryText : Color.primary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your day: calendar, what you tracked and what the screen saw")
    }

    /// Today's categories in the order they first appear, then the calendar swatch.
    private var legend: [String] {
        var seen = Set<String>()
        let labels = (lanes.tracked.map { ($0.start, $0.label) } + lanes.screen.compactMap { s in s.category.map { (s.start, $0) } })
            .sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
        return labels + (lanes.events.isEmpty ? [] : ["Calendar event"]) + ["Nothing logged"]
    }

    private var readout: String {
        guard let t = hover else { return "Point at the timeline to see what was happening at that time." }
        let event = lanes.events.first { $0.start <= t && t < $0.end }?.title
        let tracked = lanes.tracked.last { $0.start <= t && t < $0.end }?.label
        let screen = lanes.screen.last { $0.start <= t && t < $0.end }?.category
        var parts = [t.formatted(date: .omitted, time: .shortened)]
        if let event { parts.append("Calendar: \(event)") }
        parts.append("Tracked: \(tracked ?? "nothing")")
        parts.append("Screen: \(screen ?? (t > Date() ? "not yet" : "nothing seen"))")
        return parts.joined(separator: " · ")
    }

    private func x(_ d: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max(d.timeIntervalSince(start), 0), 86400) / 86400) * width
    }

    private func lane(_ r: Row) -> some View {
        let titles = r.label == "Calendar" ? lanes.events.map(\.title) : []
        return Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                     with: .color(Color.primary.opacity(0.06)))
            for (i, (a, b, color)) in r.items.enumerated() {
                let x0 = x(a, size.width), x1 = x(b, size.width)
                guard x1 > x0 else { continue }
                let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                ctx.fill(Path(rect), with: .color(color))
                guard i < titles.count else { continue }
                let text = ctx.resolve(Text(titles[i]).font(.system(size: 11, weight: .medium)).foregroundColor(.primary))
                if text.measure(in: CGSize(width: .infinity, height: size.height)).width + 8 <= rect.width {
                    ctx.draw(text, at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
                }
            }
        }
        .frame(height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
