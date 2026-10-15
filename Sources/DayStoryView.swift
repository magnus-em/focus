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
        let watcher = ScreenWatcher.shared
        let tracked = sessions.map { Self.tracked($0, running: false) } + live.map { Self.tracked($0, running: true) }
        let activities = watcher.activities(from: start, to: min(end, now)).filter { $0.device == nil }
        let screen = activities.map { DayStory.Screen(start: $0.start, end: $0.end, category: $0.category) }
        let notes = activities.compactMap { a in
            watcher.notes(for: a).map { DayStory.Note(start: a.start, end: a.end, title: $0.title) }
        }
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
    /// Something to fix: #C2410C on light, #FF9F5A on dark (orange, never red: red is for errors).
    static let attention = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.25, blue: 0.05, alpha: 1)
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
                DayLanesView(lanes: model.lanes, day: day)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        storyColumn(story).frame(minWidth: 500, maxWidth: .infinity, alignment: .leading)
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
                Text(line)
                    .font(.system(size: 22, weight: .medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
                    .textSelection(.enabled)
                if let asOf = story.headlineAsOf, story.headline != nil {
                    Text("Written at \(asOf.formatted(date: .omitted, time: .shortened)). Later stretches come from live observations.")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private func fallbackHeadline(_ story: DayStory.Story) -> String? {
        let parts = story.courses.prefix(2).map { "\($0.code) for \(durationText(minutes: $0.minutes))" }
        guard !parts.isEmpty else { return nil }
        return (isToday ? "So far: " : "") + parts.joined(separator: ", ") + "."
    }

    private func glance(_ story: DayStory.Story) -> some View {
        let fixes = visible(story.fixes)
        return HStack(alignment: .top, spacing: 36) {
            fact(durationText(minutes: focusMinutes), goalLine, color: focusMinutes >= goalHours * 60 ? .good : .primary)
            if let top = story.courses.first {
                fact(top.code, courseLine(top), color: .primary)
            }
            if !fixes.isEmpty {
                fact(fixes.count == 1 ? "1 to fix" : "\(fixes.count) to fix", fixSummary(fixes[0]), color: .attention)
            }
            Spacer(minLength: 0)
        }
    }

    private var goalLine: String {
        let goal = goalHours * 60
        if focusMinutes >= goal { return "focus, goal met" }
        return "focus, \(durationText(minutes: goal - focusMinutes)) to your \(goalHours.formatted())h goal"
    }

    private func courseLine(_ c: DayStory.Course) -> String {
        var line = "\(durationText(minutes: c.minutes)) on screen"
        if let p = c.practiceShare, c.observations >= 5 { line += ", \(Int((p * 100).rounded()))% solving on your own" }
        return line
    }

    private func fact(_ value: String, _ caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func fixSummary(_ f: DayStory.Fix) -> String {
        switch f.kind {
        case .calendar(let event): return "\(f.tracked ?? "Tracked") during \(event)"
        case .untracked: return "\(durationText(minutes: f.minutes)) not logged at \(clock(f.start))"
        case .screenDiffers(let seen): return "Screen showed \(seen) during \(f.tracked ?? "tracked time")"
        }
    }

    // MARK: Story

    private func storyColumn(_ story: DayStory.Story) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if story.blocks.isEmpty {
                Text(isToday ? "Nothing tracked yet today." : "Nothing tracked on this day.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText).padding(.vertical, 12)
            }
            ForEach(Array(story.blocks.enumerated()), id: \.element.id) { i, block in
                if i > 0 { Divider().padding(.leading, 76) }
                if block.quiet { quietRow(block) } else { blockRow(block) }
            }
        }
    }

    private func quietRow(_ b: DayStory.Block) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(clock(b.start)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
                .frame(width: 64, alignment: .leading)
            Circle().fill(categoryColor(b.category ?? "")).frame(width: 7, height: 7)
            Text("\(b.title) · \(durationText(minutes: span(b)))\(b.moments.first.map { " · " + $0.text } ?? "")")
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
                Text(m.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
        let who = names.count == 1 ? names[0] : "Other things"
        let times = list.prefix(6).map { clock($0.start) }.joined(separator: ", ")
        let count = list.count == 1 ? "once" : list.count == 2 ? "twice" : "\(list.count) times"
        return "\(who) cut in \(count), \(durationText(minutes: max(minutes, 1))) in all (\(times))"
    }

    // MARK: Fixes

    private func fixRow(_ f: DayStory.Fix) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.attention)
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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.attention.opacity(0.10)))
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
                .padding(.vertical, 4)
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
                    Text("The coach noticed").font(.system(size: 14, weight: .semibold))
                    ForEach(story.noticed.prefix(3), id: \.self) { n in
                        Text(n).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !story.hasCoach {
                card {
                    Text("Only your tracking").font(.system(size: 14, weight: .semibold))
                    Text("With the cloud coach on (Settings → Coach), this page also shows what you studied, your own questions and what looked shaky.")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button(action: openCoach) {
                    Label("Ask the coach", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 36)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Talk this day through with the coach")
                if let spent = model.spent {
                    Text("Coach today: \(spent < 1 ? "\(Int((spent * 100).rounded()))¢" : String(format: "$%.2f", spent))")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private func courseCard(_ c: DayStory.Course, first: Bool, questions: Int) -> some View {
        card {
            if first { Text("What you learned").font(.system(size: 14, weight: .semibold)) }
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
                Text("Looked shaky").font(.system(size: 12, weight: .semibold)).padding(.top, 2)
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

/// Calendar, you and the screen on one 24-hour scale.
struct DayLanesView: View {
    let lanes: DayStoryModel.Lanes
    let day: Date

    private var start: Date { Calendar.current.startOfDay(for: day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !lanes.events.isEmpty {
                lane("Calendar", height: 8, items: lanes.events.map { ($0.start, $0.end, Color(red: 1.0, green: 0.48, blue: 0.27)) })
            }
            lane("You", height: 14, items: lanes.tracked.map { ($0.start, $0.end, categoryColor($0.label)) })
            lane("Screen", height: 14, items: lanes.screen.compactMap { s in s.category.map { (s.start, s.end, categoryColor($0)) } })
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your day: what you tracked and what the screen saw")
    }

    private func lane(_ label: String, height: CGFloat, items: [(Date, Date, Color)]) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                .frame(width: 56, alignment: .trailing)
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                         with: .color(Color.primary.opacity(0.06)))
                for (a, b, color) in items {
                    let x0 = CGFloat(max(0, a.timeIntervalSince(start)) / 86400) * size.width
                    let x1 = CGFloat(min(86400, b.timeIntervalSince(start)) / 86400) * size.width
                    guard x1 > x0 else { continue }
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)), with: .color(color))
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
