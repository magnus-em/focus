import Foundation

/// The numbers behind the Insights page and the written analysis: effort by
/// goal (the goals you put off first), what the timer said against what the
/// screen showed, how often and where attention left the work, and what kind
/// of studying it was. Pure: the app gathers the inputs, this only counts.
public enum Insights {
    public struct Session: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var category: String
        public var isFocus: Bool
        public init(start: Date, end: Date, category: String, isFocus: Bool) {
            self.start = start; self.end = end; self.category = category; self.isFocus = isFocus
        }
    }

    /// One reading from the cloud observer (`Focus/episodes`).
    public struct Observation: Equatable, Sendable {
        public var at: Date
        public var end: Date
        public var category: String?
        public var course: String?
        public var activity: String?
        public var asked: [String]
        public var concepts: [String]
        public init(at: Date, end: Date, category: String?, course: String?, activity: String?, asked: [String] = [],
                    concepts: [String] = []) {
            self.at = at; self.end = end; self.category = category; self.course = course; self.activity = activity
            self.asked = asked; self.concepts = concepts
        }
    }

    public struct Input: Sendable {
        public var period: DateInterval
        public var goals: [Goals.Goal]
        public var sessions: [Session]
        /// Windows in front with their labels (second-by-second where the
        /// window log exists, screen readings before that).
        public var segments: [WindowTimeline.LabeledSegment]
        public var observations: [Observation]
        public var aiMessages: [AIChats.Message]
        public var applications: [Date]
        public var leetCodeSolves: [Date]
        public var studyCategories: Set<String>
        public var lifeCategories: Set<String>
        public init(period: DateInterval, goals: [Goals.Goal], sessions: [Session], segments: [WindowTimeline.LabeledSegment],
                    observations: [Observation] = [], aiMessages: [AIChats.Message] = [], applications: [Date] = [],
                    leetCodeSolves: [Date] = [], studyCategories: Set<String>, lifeCategories: Set<String>) {
            self.period = period; self.goals = goals; self.sessions = sessions; self.segments = segments
            self.observations = observations; self.aiMessages = aiMessages; self.applications = applications
            self.leetCodeSolves = leetCodeSolves; self.studyCategories = studyCategories; self.lifeCategories = lifeCategories
        }
    }

    public struct GoalProgress: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var avoided: Bool
        public var rank: Int
        /// On the timer in the goal's categories.
        public var trackedMinutes: Double
        /// The screen showing the goal's work (any time, timer or not).
        public var screenMinutes: Double
        public var weeklyTarget: Double?
        /// Minutes per day on screen, oldest first, one per day of the period.
        public var perDay: [Double]
        public var daysTouched: Int
        public var outputs: [String: Int]
        public var outputTargets: [String: Int]
        public var lastTouched: Date?
        /// Target scaled to the period's length.
        public var target: Double? { weeklyTarget.map { $0 * 60 } }
    }

    public struct Distractor: Equatable, Sendable, Identifiable {
        public var name: String
        public var count: Int
        public var minutes: Double
        public var id: String { name }
    }

    public struct Attention: Equatable, Sendable {
        public var focusHoursSeen: Double
        public var excursions: Int
        public var glances: Int
        public var detours: Int
        public var drifts: Int
        public var excursionMinutes: Double
        public var perFocusHour: Double
        public var medianStretchMinutes: Double
        public var longStretchShare: Double
        public var longestStretchMinutes: Double
        public var distractors: [Distractor]
        /// Excursion minutes by hour of day.
        public var byHour: [Double]
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public var date: Date
        public var trackedFocus: Double
        public var confirmedStudy: Double
        public var avoidedMinutes: Double
        public var excursionsPerHour: Double?
        public var firstFocus: Date?
        public var firstAvoided: Date?
        public var aiMessages: Int
        public var id: Date { date }
    }

    public struct Summary: Equatable, Sendable {
        public var period: DateInterval
        public var goals: [GoalProgress]
        /// Focus-category screen minutes by where they went.
        public var avoidedMinutes: Double
        public var otherGoalMinutes: Double
        public var noGoalMinutes: Double
        public var trackedFocusMinutes: Double
        /// Of tracked focus: study/goal work on screen, other things on screen, nothing on screen.
        public var confirmedMinutes: Double
        public var offTaskMinutes: Double
        public var unseenMinutes: Double
        public var attention: Attention
        public var days: [Day]
        public var studyByHour: [Double]
        public var activityMinutes: [String: Double]
        public var courseMinutes: [String: Double]
        public var repeatedConcepts: [(concept: String, days: Int)]
        public var aiMessages: Int
        public var aiByTool: [String: Int]
        public var questions: Int
        /// Days the first focus block went to a goal you put off.
        public var avoidedFirstDays: Int
        public var activeDays: Int

        public var avoidedShare: Double {
            let t = avoidedMinutes + otherGoalMinutes + noGoalMinutes
            return t > 0 ? avoidedMinutes / t : 0
        }

        public static func == (a: Summary, b: Summary) -> Bool {
            a.period == b.period && a.goals == b.goals && a.days == b.days && a.attention == b.attention
                && a.avoidedMinutes == b.avoidedMinutes && a.repeatedConcepts.map(\.concept) == b.repeatedConcepts.map(\.concept)
        }
    }

    // MARK: -

    public static func summarize(_ input: Input, calendar: Calendar = .current) -> Summary {
        let p = input.period
        let goals = input.goals.filter { !$0.archived }
        let dayStarts: [Date] = {
            var out: [Date] = []
            var d = calendar.startOfDay(for: p.start)
            while d < p.end { out.append(d); d = calendar.date(byAdding: .day, value: 1, to: d) ?? p.end }
            return out
        }()
        func dayIndex(_ t: Date) -> Int? {
            let s = calendar.startOfDay(for: t)
            return dayStarts.firstIndex(of: s)
        }
        func clip(_ a: Date, _ b: Date) -> (Date, Date)? {
            let x = max(a, p.start), y = min(b, p.end)
            return y > x ? (x, y) : nil
        }
        let segs = input.segments.compactMap { l -> WindowTimeline.LabeledSegment? in
            guard let (a, b) = clip(l.segment.start, l.segment.end) else { return nil }
            var c = l; c.segment.start = a; c.segment.end = b; return c
        }
        let obs = input.observations.sorted { $0.at < $1.at }
        let withCourse = obs.filter { $0.course != nil }
        let longest = withCourse.map { $0.end.timeIntervalSince($0.at) }.max() ?? 0
        func course(at a: Date, _ b: Date) -> String? {
            var lo = 0, hi = withCourse.count
            let from = a.addingTimeInterval(-longest)
            while lo < hi { let m = (lo + hi) / 2; if withCourse[m].at < from { lo = m + 1 } else { hi = m } }
            var w: [String: Double] = [:]
            var i = lo
            while i < withCourse.count, withCourse[i].at < b {
                let o = withCourse[i]
                if o.end > a, let c = o.course { w[c, default: 0] += min(o.end, b).timeIntervalSince(max(o.at, a)) + 1 }
                i += 1
            }
            return w.max { $0.value < $1.value }?.key
        }
        let isFocusCat = { (c: String) in input.studyCategories.contains(c) || (!input.lifeCategories.contains(c) && c != "Break" && c != WindowTimeline.privateCategory) }

        // Goals
        var progress: [GoalProgress] = goals.enumerated().map { i, g in
            GoalProgress(id: g.id, title: g.title, avoided: g.avoided, rank: i + 1, trackedMinutes: 0, screenMinutes: 0,
                         weeklyTarget: g.weeklyHours.map { $0 * p.duration / (7 * 86400) }, perDay: Array(repeating: 0, count: dayStarts.count),
                         daysTouched: 0, outputs: [:], outputTargets: g.outputsPerWeek, lastTouched: nil)
        }
        let goalIndex = Dictionary(uniqueKeysWithValues: goals.enumerated().map { ($1.id, $0) })
        var avoided = 0.0, otherGoal = 0.0, noGoal = 0.0
        var courseMinutes: [String: Double] = [:]
        var studyByHour = Array(repeating: 0.0, count: 24)
        var days = dayStarts.map { Day(date: $0, trackedFocus: 0, confirmedStudy: 0, avoidedMinutes: 0, excursionsPerHour: nil,
                                       firstFocus: nil, firstAvoided: nil, aiMessages: 0) }
        for l in segs {
            guard let c = l.category, isFocusCat(c) else { continue }
            let m = l.segment.seconds / 60
            let crs = course(at: l.segment.start, l.segment.end)
            if let crs { courseMinutes[crs, default: 0] += m }
            if input.studyCategories.contains(c) {
                let h = calendar.component(.hour, from: l.segment.start)
                studyByHour[h] += m
            }
            let di = dayIndex(l.segment.start)
            if let g = Goals.goal(for: c, course: crs, in: goals), let gi = goalIndex[g.id] {
                progress[gi].screenMinutes += m
                if let di { progress[gi].perDay[di] += m }
                progress[gi].lastTouched = max(progress[gi].lastTouched ?? .distantPast, l.segment.end)
                if g.avoided {
                    avoided += m
                    if let di {
                        days[di].avoidedMinutes += m
                        if days[di].firstAvoided == nil || l.segment.start < days[di].firstAvoided! { days[di].firstAvoided = l.segment.start }
                    }
                } else { otherGoal += m }
            } else { noGoal += m }
        }
        for i in progress.indices { progress[i].daysTouched = progress[i].perDay.filter { $0 >= 5 }.count }

        // Timer
        var tracked = 0.0, confirmed = 0.0, offTask = 0.0, unseen = 0.0
        let focusSessions = input.sessions.filter(\.isFocus).compactMap { s -> Session? in
            guard let (a, b) = clip(s.start, s.end) else { return nil }
            var c = s; c.start = a; c.end = b; return c
        }
        for s in input.sessions {
            guard let (a, b) = clip(s.start, s.end) else { continue }
            if s.isFocus, let g = Goals.goal(for: s.category, course: nil, in: goals), let gi = goalIndex[g.id] {
                progress[gi].trackedMinutes += b.timeIntervalSince(a) / 60
                if g.avoided, let di = dayIndex(a), days[di].firstAvoided == nil { days[di].firstAvoided = a }
            }
        }
        for s in focusSessions {
            let len = s.end.timeIntervalSince(s.start) / 60
            tracked += len
            var seen = 0.0, on = 0.0
            for l in segs where l.segment.end > s.start && l.segment.start < s.end {
                let o = min(l.segment.end, s.end).timeIntervalSince(max(l.segment.start, s.start)) / 60
                seen += o
                if let c = l.category, isFocusCat(c) { on += o }
            }
            confirmed += on; offTask += max(0, seen - on); unseen += max(0, len - seen)
            if let di = dayIndex(s.start) {
                days[di].trackedFocus += len
                days[di].confirmedStudy += on
                if days[di].firstFocus == nil || s.start < days[di].firstFocus! { days[di].firstFocus = s.start }
            }
        }
        var avoidedFirst = 0
        for d in days {
            guard let f = d.firstFocus, let s = focusSessions.first(where: { $0.start == f }) else { continue }
            if let g = Goals.goal(for: s.category, course: course(at: s.start, s.end), in: goals), g.avoided { avoidedFirst += 1 }
        }

        // Attention
        let distracting = { (c: String) in input.lifeCategories.contains(c) || c == WindowTimeline.privateCategory }
        let blocks = focusSessions.map { WindowTimeline.Block(start: $0.start, end: $0.end, category: $0.category) }
        let att = WindowTimeline.attention(segs, blocks: blocks, distracting: distracting, isFocus: isFocusCat)
        let away = att.excursions.filter { !$0.otherWork }
        var byName: [String: Distractor] = [:]
        var byHour = Array(repeating: 0.0, count: 24)
        for e in away {
            let name = e.category == WindowTimeline.privateCategory ? (e.privateApp ?? "Private apps") : distractorName(e)
            byName[name, default: Distractor(name: name, count: 0, minutes: 0)].count += 1
            byName[name]!.minutes += e.seconds / 60
            byHour[calendar.component(.hour, from: e.start)] += e.seconds / 60
            if let di = dayIndex(e.start) { days[di].excursionsPerHour = (days[di].excursionsPerHour ?? 0) + 1 }
        }
        for i in days.indices {
            let seenH = blocks.filter { dayIndex($0.start) == i }.reduce(0.0) { acc, b in
                acc + segs.filter { $0.segment.end > b.start && $0.segment.start < b.end }
                    .reduce(0.0) { $0 + min($1.segment.end, b.end).timeIntervalSince(max($1.segment.start, b.start)) } / 3600
            }
            if seenH >= 0.25 { days[i].excursionsPerHour = (days[i].excursionsPerHour ?? 0) / seenH } else { days[i].excursionsPerHour = nil }
        }
        let stretchMin = att.stretches.map { $0.seconds / 60 }.filter { $0 >= 1 }.sorted()
        let onTotal = stretchMin.reduce(0, +)
        let seenHours = att.seenSeconds / 3600
        let attention = Attention(
            focusHoursSeen: seenHours, excursions: away.count,
            glances: away.filter { $0.kind == .glance }.count, detours: away.filter { $0.kind == .detour }.count,
            drifts: away.filter { $0.kind == .drift }.count,
            excursionMinutes: away.reduce(0) { $0 + $1.seconds / 60 },
            perFocusHour: seenHours > 0 ? Double(away.count) / seenHours : 0,
            medianStretchMinutes: stretchMin.isEmpty ? 0 : stretchMin[stretchMin.count / 2],
            longStretchShare: onTotal > 0 ? stretchMin.filter { $0 >= 25 }.reduce(0, +) / onTotal : 0,
            longestStretchMinutes: stretchMin.last ?? 0,
            distractors: byName.values.sorted { $0.count > $1.count || ($0.count == $1.count && $0.minutes > $1.minutes) },
            byHour: byHour)

        // Observations, AI, outputs
        var activity: [String: Double] = [:]
        var conceptDays: [String: Set<Int>] = [:]
        var questions = Set<String>()
        for o in obs where o.at >= p.start && o.at < p.end && (o.category.map { input.studyCategories.contains($0) } ?? false) {
            let m = min(300, max(15, o.end.timeIntervalSince(o.at))) / 60
            if let a = o.activity { activity[a, default: 0] += m }
            if let di = dayIndex(o.at) {
                for c in o.concepts { conceptDays[c.lowercased(), default: []].insert(di) }
                for q in o.asked { questions.insert("\(di)|" + AIChats.normalized(q)) }
            }
        }
        let msgs = input.aiMessages.filter { p.contains($0.at) }
        var byTool: [String: Int] = [:]
        for m in msgs {
            byTool[m.tool, default: 0] += 1
            if let di = dayIndex(m.at) { days[di].aiMessages += 1 }
        }
        for i in progress.indices {
            let g = goals[i]
            if g.outputs.contains(.applications) { progress[i].outputs["applications"] = input.applications.filter { p.contains($0) }.count }
            if g.outputs.contains(.leetCodeProblems) { progress[i].outputs["leetCodeProblems"] = input.leetCodeSolves.filter { p.contains($0) }.count }
        }

        let counted: [(concept: String, days: Int)] = conceptDays.filter { $0.value.count >= 3 }
            .map { (concept: $0.key, days: $0.value.count) }
        let repeated = Array(counted.sorted { a, b in a.days != b.days ? a.days > b.days : a.concept < b.concept }.prefix(12))
        let activeDays = days.filter { $0.trackedFocus > 0 || $0.confirmedStudy > 0 }.count
        return Summary(
            period: p, goals: progress, avoidedMinutes: avoided, otherGoalMinutes: otherGoal, noGoalMinutes: noGoal,
            trackedFocusMinutes: tracked, confirmedMinutes: confirmed, offTaskMinutes: offTask, unseenMinutes: unseen,
            attention: attention, days: days, studyByHour: studyByHour, activityMinutes: activity,
            courseMinutes: courseMinutes, repeatedConcepts: repeated,
            aiMessages: msgs.count, aiByTool: byTool, questions: questions.count,
            avoidedFirstDays: avoidedFirst, activeDays: activeDays)
    }

    static func distractorName(_ e: WindowTimeline.Excursion) -> String {
        let t = (e.titles.first ?? "").lowercased()
        let app = e.apps.first ?? e.category
        for (mark, name) in [("youtube", "YouTube"), ("/ x", "X"), ("x.com", "X"), ("instagram", "Instagram"), ("reddit", "Reddit"),
                             ("linkedin", "LinkedIn"), ("gmail", "Email"), ("inbox", "Email"), ("amazon", "Shopping"),
                             ("threads", "Threads"), ("tiktok", "TikTok"), ("netflix", "Netflix")] where t.contains(mark) {
            return name
        }
        if ["Google Chrome", "Safari", "Arc"].contains(app) { return "\(e.category) browsing" }
        return "\(app) (\(e.category))"
    }

    /// Screen readings as labeled segments, for days the window log doesn't cover.
    public static func segments(fromReadings labels: [WindowTimeline.Label], apps: [String: String] = [:]) -> [WindowTimeline.LabeledSegment] {
        labels.map { l in
            WindowTimeline.LabeledSegment(
                segment: .init(start: l.start, end: l.end, app: apps[l.bundle] ?? l.bundle, bundle: l.bundle, title: l.title),
                category: l.category, source: .reading, coarse: true)
        }
    }
}
