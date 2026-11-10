import Foundation

/// The written half of Insights: a strong model reads the week's numbers
/// (`Insights.Summary`), the day records and your goals, and writes the
/// headline, takeaways and tips, ranked by goal with the work you put off
/// first. Saved as `Focus/insights/reports/*.json`; Claude Code can write the
/// same file from `Focus/insights/bundle.json` when you ask it to.
public enum InsightsReport {
    public static let version = "insights-1"

    public struct GoalVerdict: Codable, Equatable, Sendable {
        public var goal: String
        public var verdict: String
        public var line: String
    }

    public struct Takeaway: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String
        public var evidence: String
        public var goal: String?
    }

    public struct Tip: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String
        public var goal: String?
        /// How the next report will tell whether it happened.
        public var measure: String
    }

    public struct TipCheck: Codable, Equatable, Sendable {
        public var tip: String
        public var followed: String
        public var effect: String
    }

    public struct Content: Codable, Equatable, Sendable {
        public var headline: String
        public var goals: [GoalVerdict]
        public var takeaways: [Takeaway]
        public var working: [String]
        public var tips: [Tip]
        public var lastTips: [TipCheck]
        public var goalQuestion: String?
    }

    public struct Report: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var writtenAt: Date
        public var periodStart: Date
        public var periodEnd: Date
        public var model: String
        public var author: String
        public var costUSD: Double?
        public var version: String
        public var content: Content

        public init(id: UUID = UUID(), writtenAt: Date, periodStart: Date, periodEnd: Date, model: String, author: String,
                    costUSD: Double?, content: Content) {
            self.id = id; self.writtenAt = writtenAt; self.periodStart = periodStart; self.periodEnd = periodEnd
            self.model = model; self.author = author; self.costUSD = costUSD; self.version = InsightsReport.version
            self.content = content
        }
    }

    /// What one day record contributes: its headline and what looked shaky.
    public struct DayNote: Equatable, Sendable {
        public var date: Date
        public var headline: String
        public var courses: [String]
        public var shaky: [String]
        public init(date: Date, headline: String, courses: [String], shaky: [String]) {
            self.date = date; self.headline = headline; self.courses = courses; self.shaky = shaky
        }
    }

    public static let system = """
    You are Focus, the analyst inside a student's focus tracker. The student is a Yale CS undergraduate preparing for quant and software engineering internship interviews. Their own diagnosis: they are good at hard technical work they enjoy (deep learning, building things), and they keep failing to point their effort at the work they don't want to do, mainly homework and recruiting. Your job is to help them direct effort, not to praise more of what they already do.

    Rules:
    - Rank everything by their goals, in their order. Goals marked "put off" come first in every list where they apply. Never present more time on a goal that is not put off as a win while a put-off goal is behind.
    - Every claim must come from the facts given. Cite the numbers and days. If a measure has little data, say so.
    - The screen record only covers the Mac. Time on the timer with nothing on screen may be paper, the iPad, a lecture or a timer left running; say which is more likely only when the facts show it.
    - Tips are small, concrete and schedulable (what, when, how long), aimed at starting the put-off work, and each names how Focus will measure it next week. At most 5 tips. No generic productivity advice.
    - Check last report's tips against this period's facts: followed (yes, partly, no, unknown) and what changed.
    - Plain words, second person, no exclamation marks, no headings inside fields. Keep each detail to 1–3 sentences.
    - Leave out health, medication and personal-life content entirely.
    """

    public static let schema: [String: Any] = {
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "properties": props, "required": Array(props.keys).sorted()]
        }
        let str: [String: Any] = ["type": "string"]
        let optStr: [String: Any] = ["type": ["string", "null"]]
        return obj([
            "headline": str,
            "goals": ["type": "array", "items": obj(["goal": str, "verdict": ["type": "string", "enum": ["ahead", "on track", "behind", "untouched", "no data"]], "line": str])],
            "takeaways": ["type": "array", "items": obj(["title": str, "detail": str, "evidence": str, "goal": optStr])],
            "working": ["type": "array", "items": str],
            "tips": ["type": "array", "items": obj(["title": str, "detail": str, "goal": optStr, "measure": str])],
            "lastTips": ["type": "array", "items": obj(["tip": str, "followed": ["type": "string", "enum": ["yes", "partly", "no", "unknown"]], "effect": str])],
            "goalQuestion": optStr,
        ])
    }()

    static func h(_ minutes: Double) -> String {
        minutes < 60 ? "\(Int(minutes.rounded())) min" : String(format: "%.1f h", minutes / 60)
    }

    /// The facts the model reads, as compact text.
    public static func facts(_ s: Insights.Summary, goals: [Goals.Goal], history: [Goals.Change], days: [DayNote],
                             previous: Report?, calendar: Calendar = .current) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.dateFormat = "EEE MMM d"
        let tf = DateFormatter()
        tf.calendar = calendar
        tf.dateFormat = "h:mm a"
        var out: [String] = []
        out.append("PERIOD: \(df.string(from: s.period.start)) to \(df.string(from: s.period.end.addingTimeInterval(-1))), \(s.days.count) days, \(s.activeDays) with tracked or seen study.")
        out.append("\nGOALS (priority order):")
        for (i, g) in goals.filter({ !$0.archived }).enumerated() {
            guard let p = s.goals.first(where: { $0.id == g.id }) else { continue }
            var line = "\(i + 1). \(g.title)\(g.avoided ? " [put off]" : "") — why: \(g.why)"
            line += "\n   counts: categories \(g.categories.joined(separator: ", "))\(g.courses.isEmpty ? "" : "; courses \(g.courses.joined(separator: ", "))")"
            line += "\n   on screen \(h(p.screenMinutes)), on timer \(h(p.trackedMinutes))"
            if let t = p.weeklyTarget { line += ", target \(String(format: "%.1f", t)) h for this period" }
            if let d = g.dailyMinutes { line += ", daily minimum \(Int(d)) min" }
            line += "\n   per day on screen (min): " + zip(s.days, p.perDay).map { "\(df.string(from: $0.date)) \(Int($1.rounded()))" }.joined(separator: ", ")
            for (k, v) in p.outputs.sorted(by: { $0.key < $1.key }) {
                line += "\n   \(k): \(v)\(p.outputTargets[k].map { " (target \($0)/week)" } ?? "")"
            }
            if let last = p.lastTouched { line += "\n   last seen \(df.string(from: last)) \(tf.string(from: last))" }
            out.append(line)
        }
        if !history.isEmpty {
            out.append("Goal changes: " + history.suffix(8).map { "\(df.string(from: $0.at)): \($0.summary)" }.joined(separator: "; "))
        }
        let total = s.avoidedMinutes + s.otherGoalMinutes + s.noGoalMinutes
        out.append("\nEFFORT on screen (focus categories): \(h(total)) total; put-off goals \(h(s.avoidedMinutes)) (\(Int((s.avoidedShare * 100).rounded()))%), other goals \(h(s.otherGoalMinutes)), no goal \(h(s.noGoalMinutes)).")
        out.append("First focus block of the day went to a put-off goal on \(s.avoidedFirstDays) of \(s.days.filter { $0.firstFocus != nil }.count) days with focus.")
        out.append("\nTIMER vs SCREEN: \(h(s.trackedFocusMinutes)) on the focus timer; of it, focus work on screen \(h(s.confirmedMinutes)), something else on screen \(h(s.offTaskMinutes)), nothing on screen \(h(s.unseenMinutes)).")
        out.append("\nDAYS:")
        for d in s.days {
            var l = "\(df.string(from: d.date)): timer focus \(h(d.trackedFocus)), focus on screen \(h(d.confirmedStudy)), put-off goals \(h(d.avoidedMinutes))"
            if let f = d.firstFocus { l += ", first focus \(tf.string(from: f))" }
            if let f = d.firstAvoided { l += ", first put-off work \(tf.string(from: f))" }
            if let e = d.excursionsPerHour { l += ", \(String(format: "%.1f", e)) distractions/focus hour" }
            if d.aiMessages > 0 { l += ", \(d.aiMessages) AI messages" }
            out.append(l)
        }
        let a = s.attention
        out.append("\nATTENTION during focus (\(String(format: "%.1f", a.focusHoursSeen)) h seen): \(a.excursions) times away to something else (\(a.glances) under 30 s, \(a.detours) 30 s–5 min, \(a.drifts) over 5 min), \(h(a.excursionMinutes)) in all, \(String(format: "%.1f", a.perFocusHour)) per hour. On-task stretches: median \(String(format: "%.0f", a.medianStretchMinutes)) min, longest \(String(format: "%.0f", a.longestStretchMinutes)) min, \(Int((a.longStretchShare * 100).rounded()))% of on-task time in stretches of 25 min or more.")
        out.append("Where attention went: " + a.distractors.prefix(8).map { "\($0.name) \($0.count)× \(h($0.minutes))" }.joined(separator: ", "))
        let hours = s.studyByHour.enumerated().filter { $0.element >= 10 }.map { "\($0.offset):00 \(h($0.element))" }
        out.append("\nSTUDY BY HOUR: " + hours.joined(separator: ", "))
        if !s.activityMinutes.isEmpty {
            out.append("HOW (study observations): " + s.activityMinutes.sorted { $0.value > $1.value }.map { "\($0.key) \(h($0.value))" }.joined(separator: ", "))
        }
        if !s.courseMinutes.isEmpty {
            out.append("COURSES on screen: " + s.courseMinutes.sorted { $0.value > $1.value }.map { "\($0.key) \(h($0.value))" }.joined(separator: ", "))
        }
        if !s.repeatedConcepts.isEmpty {
            out.append("CONCEPTS that came up on 3+ days: " + s.repeatedConcepts.map { "\($0.concept) (\($0.days) days)" }.joined(separator: ", "))
        }
        out.append("AI: \(s.aiMessages) messages typed to AI tools (" + s.aiByTool.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "), \(s.questions) distinct study questions seen on screen.")
        if !days.isEmpty {
            out.append("\nDAY RECORDS (written each morning from the screen):")
            for d in days {
                var l = "\(df.string(from: d.date)): \(d.headline)"
                if !d.courses.isEmpty { l += " Courses: \(d.courses.joined(separator: ", "))." }
                if !d.shaky.isEmpty { l += " Shaky: \(d.shaky.prefix(3).joined(separator: "; "))." }
                out.append(l)
            }
        }
        if let previous {
            out.append("\nLAST REPORT'S TIPS (\(df.string(from: previous.writtenAt))):")
            for t in previous.content.tips { out.append("- \(t.title): \(t.detail) (measure: \(t.measure))") }
        }
        return out.joined(separator: "\n")
    }

    public static func decode(_ json: Data) throws -> Content {
        try JSONDecoder().decode(Content.self, from: json)
    }
}
