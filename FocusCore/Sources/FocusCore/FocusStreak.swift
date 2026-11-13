import Foundation

/// How long you stay on your study without a distraction (user, 11/10:
/// "talking to AI about what I'm doing is fine but I want to stop going to
/// Messages etc. while focused"). One rule for what's in front, used for the
/// week's numbers (`stretches`) and the live count (`Live`):
/// - study: the block's category, any other focus category, and AI chats
///   (ChatGPT, Claude…) unless the screen called the chat a life category;
/// - distraction: Messages/Mail and other private apps, and anything the
///   screen labeled a life category (Leisure, Admin, Social…), once it has
///   been in front `minDistraction` seconds;
/// - neutral: unlabeled windows (Finder, Focus itself): they neither end a
///   stretch nor count as study.
public enum FocusStreak {
    public static let minDistraction: TimeInterval = 5
    /// Longer than this with nothing in front (away, asleep, recorder off) ends a stretch.
    public static let maxGap: TimeInterval = 30
    public static let coarseMaxGap: TimeInterval = 120

    public enum Kind: Equatable, Sendable {
        case study, neutral
        case distraction(String)
    }

    static let chatHosts = ["chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "grok.com", "perplexity.ai"]
    public static let chatBundles: Set<String> = ["com.openai.chat", "com.anthropic.claudefordesktop", "com.openai.codex",
                                                  "com.google.Gemini", "ai.perplexity.mac"]

    public static func isAIChat(bundle: String, url: String?) -> Bool {
        if chatBundles.contains(bundle) { return true }
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return chatHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// `labelSource` "rule" marks the user's Focus-project rule (work on this
    /// app is Admin), which during study is a distraction of its own kind.
    public static func kind(app: String, bundle: String, title: String?, url: String?, category: String?,
                            labelSource: String? = nil, life: Set<String>) -> Kind {
        if category == WindowTimeline.privateCategory { return .distraction(app) }
        let chat = isAIChat(bundle: bundle, url: url)
        guard let c = category else { return chat ? .study : .neutral }
        if c == "Break" || life.contains(c) {
            return .distraction(name(app: app, title: title, url: url, category: c, labelSource: labelSource))
        }
        return .study
    }

    public static func name(app: String, title: String?, url: String?, category: String, labelSource: String?) -> String {
        if labelSource == "rule" { return "Working on Focus" }
        let t = ((title ?? "") + " " + (url ?? "")).lowercased()
        for (mark, name) in [("youtube", "YouTube"), (" / x", "X"), ("x.com", "X"), ("twitter", "X"), ("instagram", "Instagram"),
                             ("reddit", "Reddit"), ("linkedin", "LinkedIn"), ("gmail", "Email"), ("mail.google", "Email"),
                             ("inbox", "Email"), ("amazon", "Shopping"), ("threads", "Threads"), ("tiktok", "TikTok"),
                             ("netflix", "Netflix"), ("facebook", "Facebook"), ("nytimes", "News")] where t.contains(mark) {
            return name
        }
        if ["Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge"].contains(app) { return "\(category) browsing" }
        return isAIChat(bundle: "", url: url) || ["ChatGPT", "Claude", "Codex"].contains(app) ? "\(app) (\(category))" : app
    }

    // MARK: - The week

    public struct Stretch: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var category: String
        public var studySeconds: Double
        /// What ended it; nil when the block ended or you stepped away.
        public var endedBy: String?
        public var seconds: Double { end.timeIntervalSince(start) }
        public var minutes: Double { seconds / 60 }
    }

    public struct Distraction: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var name: String
        public var blockCategory: String
        /// Minutes of focus the stretch it ended had reached.
        public var endedMinutes: Double
        public var seconds: Double { end.timeIntervalSince(start) }
    }

    public struct Result: Equatable, Sendable {
        public var stretches: [Stretch]
        public var distractions: [Distraction]
        /// Seconds anything was in front during the blocks.
        public var seenSeconds: Double
        /// Of those, seconds from the second-by-second window log.
        public var fineSeconds: Double
    }

    /// Stretches without a distraction inside each focus block. A stretch
    /// starts on study and runs through neutral windows and distractions
    /// shorter than `minDistraction`; it ends at a longer distraction, a hole
    /// in the record, or the end of the block. Stretches with under a minute
    /// of study aren't kept.
    public static func stretches(_ labeled: [WindowTimeline.LabeledSegment], blocks: [WindowTimeline.Block],
                                 life: Set<String>) -> Result {
        let segs = labeled.sorted { $0.segment.start < $1.segment.start }
        var out: [Stretch] = []
        var distractions: [Distraction] = []
        var seen = 0.0, fine = 0.0
        for b in blocks.sorted(by: { $0.start < $1.start }) {
            var cur: Stretch?
            var run: Distraction?
            var runWeights: [String: Double] = [:]
            var lastEnd: Date?
            func close(at t: Date, by name: String?) {
                guard var s = cur else { return }
                s.end = max(s.start, t)
                s.endedBy = name
                if s.studySeconds >= 60 { out.append(s) }
                cur = nil
            }
            func flushRun() {
                guard var r = run else { return }
                run = nil
                r.name = runWeights.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? r.name
                runWeights = [:]
                guard r.seconds >= minDistraction else {
                    cur?.end = r.end
                    return
                }
                var d = r
                if let s = cur { d.endedMinutes = max(0, r.start.timeIntervalSince(s.start)) / 60 }
                distractions.append(d)
                close(at: r.start, by: r.name)
            }
            for l in segs where l.segment.end > b.start && l.segment.start < b.end {
                let a = max(l.segment.start, b.start), e = min(l.segment.end, b.end)
                guard e > a else { continue }
                seen += e.timeIntervalSince(a)
                if !l.coarse { fine += e.timeIntervalSince(a) }
                if let last = lastEnd, a.timeIntervalSince(last) > (l.coarse ? coarseMaxGap : maxGap) {
                    flushRun()
                    close(at: last, by: nil)
                }
                lastEnd = e
                let s = l.segment
                switch kind(app: s.app, bundle: s.bundle, title: s.title, url: s.url, category: l.category,
                            labelSource: l.labelSource, life: life) {
                case .distraction(let name):
                    // Back-to-back distractions (Messages, then YouTube) are one trip away.
                    if run == nil { run = Distraction(start: a, end: e, name: name, blockCategory: b.category, endedMinutes: 0) }
                    run!.end = e
                    runWeights[name, default: 0] += e.timeIntervalSince(a)
                    // Readings are 15 s apart: any distraction there is real.
                    if l.coarse, run!.seconds < minDistraction { run!.end = run!.start.addingTimeInterval(minDistraction) }
                case .study:
                    flushRun()
                    if cur == nil { cur = Stretch(start: a, end: e, category: b.category, studySeconds: 0) }
                    cur!.end = e
                    cur!.studySeconds += e.timeIntervalSince(a)
                case .neutral:
                    flushRun()
                    cur?.end = e
                }
            }
            flushRun()
            close(at: min(b.end, cur?.end ?? b.end), by: nil)
        }
        return Result(stretches: out, distractions: distractions, seenSeconds: seen, fineSeconds: fine)
    }

    /// The length L such that half the time in stretches came in stretches of
    /// L or longer ("half your focus came in stretches of 14+ min").
    public static func halfTimeMinutes(_ stretches: [Stretch]) -> Double {
        let lengths = stretches.map(\.minutes).sorted(by: >)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return 0 }
        var acc = 0.0
        for l in lengths {
            acc += l
            if acc >= total / 2 { return l }
        }
        return lengths.last ?? 0
    }

    // MARK: - Live

    public enum Event: Equatable, Sendable {
        /// A distraction lasted `minDistraction`: the stretch ended at `minutes`.
        case broke(name: String, minutes: Double)
        /// Still on it after `nudgeAfter` s, with a stretch worth protecting.
        case nudge(name: String, minutes: Double)
        /// Back on study after a distraction that ended a stretch.
        case back
    }

    /// The running count, fed once a second while the Mac is in use.
    public struct Live: Codable, Equatable, Sendable {
        public static let nudgeAfter: TimeInterval = 10
        public static let worthProtecting: TimeInterval = 3 * 60

        public var streakStart: Date?
        public var distractionStart: Date?
        public var distractionName: String?
        public var brokeMinutes: Double?
        public var nudged = false
        public var lastTick: Date?
        public var bestSeconds: Double = 0
        public var bestDay: String = ""
        public var brokenToday = 0

        public init() {}

        /// Seconds of the current stretch (0 when none is running).
        public func current(at now: Date) -> Double {
            guard let s = streakStart else { return 0 }
            if let d = distractionStart, now.timeIntervalSince(d) >= FocusStreak.minDistraction { return 0 }
            return max(0, now.timeIntervalSince(s))
        }

        public func best(at now: Date, day: String) -> Double {
            max(bestDay == day ? bestSeconds : 0, current(at: now))
        }

        /// `kind` nil: no focus block runs, you're away, or the window
        /// couldn't be read; the stretch stops there without counting as a distraction.
        public mutating func tick(_ now: Date, kind: Kind?, day: String) -> Event? {
            if bestDay != day { bestDay = day; bestSeconds = 0; brokenToday = 0 }
            defer { lastTick = now }
            if let last = lastTick, now.timeIntervalSince(last) > FocusStreak.maxGap { end(at: last) }
            guard let kind else { end(at: now); return nil }
            switch kind {
            case .study, .neutral:
                let wasBroken = distractionStart.map { now.timeIntervalSince($0) >= FocusStreak.minDistraction } ?? false
                distractionStart = nil; distractionName = nil; brokeMinutes = nil; nudged = false
                if wasBroken { streakStart = now; return .back }
                if streakStart == nil, kind == .study { streakStart = now }
                return nil
            case .distraction(let name):
                guard let s = streakStart else { return nil }
                if distractionStart == nil || distractionName != name {
                    if distractionStart == nil { distractionStart = now }
                    distractionName = name
                }
                let away = now.timeIntervalSince(distractionStart!)
                if brokeMinutes == nil, away >= FocusStreak.minDistraction {
                    let length = distractionStart!.timeIntervalSince(s)
                    bestSeconds = max(bestSeconds, length)
                    brokeMinutes = length / 60
                    brokenToday += 1
                    return .broke(name: name, minutes: length / 60)
                }
                if !nudged, let m = brokeMinutes, away >= Self.nudgeAfter, m * 60 >= Self.worthProtecting {
                    nudged = true
                    return .nudge(name: name, minutes: m)
                }
                return nil
            }
        }

        mutating func end(at t: Date) {
            if let s = streakStart, distractionStart == nil || brokeMinutes == nil {
                bestSeconds = max(bestSeconds, (distractionStart ?? t).timeIntervalSince(s))
            }
            streakStart = nil; distractionStart = nil; distractionName = nil; brokeMinutes = nil; nudged = false
        }
    }
}
