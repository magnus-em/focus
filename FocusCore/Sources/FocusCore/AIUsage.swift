import Foundation

/// How much you use AI: time with an AI tool in front, words you wrote to it
/// (`AIChats`), words it wrote back, and time it spent working for you, by
/// day, by tool and by the category the timer was on. Replies and working
/// time come from the Claude Code and Codex transcripts on disk (the ChatGPT
/// desktop app keeps its chats there too); the Claude app's chats only count
/// what you wrote, since its replies aren't on disk.
public enum AIUsage {
    public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
        case openAI = "ChatGPT & Codex"
        case anthropic = "Claude & Claude Code"
        case google = "Gemini"
        case perplexity = "Perplexity"
        case xAI = "Grok"
        public var id: String { rawValue }
    }

    public static func provider(bundle: String, url: String?) -> Provider? {
        let b = bundle.lowercased()
        if b == "com.openai.chat" || b == "com.openai.codex" { return .openAI }
        if b.hasPrefix("com.anthropic.claude") { return .anthropic }
        if b.hasPrefix("com.google.gemini") { return .google }
        if b.hasPrefix("ai.perplexity.") { return .perplexity }
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        func on(_ d: String) -> Bool { host == d || host.hasSuffix("." + d) }
        if on("chatgpt.com") || on("chat.openai.com") { return .openAI }
        if on("claude.ai") { return .anthropic }
        if on("gemini.google.com") || on("aistudio.google.com") { return .google }
        if on("perplexity.ai") { return .perplexity }
        if on("grok.com") { return .xAI }
        return nil
    }

    public static func provider(tool: String) -> Provider? {
        switch tool {
        case "ChatGPT", "Codex": return .openAI
        case "Claude", "Claude Code": return .anthropic
        case "Gemini": return .google
        case "Perplexity": return .perplexity
        case "Grok": return .xAI
        default: return nil
        }
    }

    public static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    // MARK: - Transcripts

    /// A minute in which an AI was working on something you asked
    /// (generating, thinking or running tools), and the words of reply it
    /// showed you in it. `Focus/ai-chats/usage-YYYY-MM.jsonl`.
    public struct Minute: Codable, Equatable, Sendable {
        public var at: Date
        public var tool: String
        public var session: String
        public var words: Int

        enum CodingKeys: String, CodingKey { case at, tool, session = "s", words = "n" }

        public init(at: Date, tool: String, session: String, words: Int) {
            self.at = at; self.tool = tool; self.session = session; self.words = words
        }
        var key: String { "\(tool)|\(session)|\(Int(at.timeIntervalSince1970))" }
    }

    public struct Work: Equatable, Sendable {
        public var at: Date
        public var words: Int
        public init(at: Date, words: Int) { self.at = at; self.words = words }
    }

    private static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// One line of a Claude Code transcript: a reply or tool use is work (with
    /// the reply's words); your prompts, injected context and side-chains are
    /// not. `automated` sessions (scheduled tasks) work but nobody reads them.
    public static func claudeCodeWork(_ line: Data, automated: Bool = false) -> Work? {
        guard let o = object(line), let at = AIChats.date(o["timestamp"] as? String),
              let msg = o["message"] as? [String: Any] else { return nil }
        switch o["type"] as? String {
        case "assistant":
            guard msg["model"] as? String != "<synthetic>" else { return nil }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            let read = automated || o["isSidechain"] as? Bool == true ? 0 : words(text)
            return Work(at: at, words: read)
        case "user":
            let blocks = msg["content"] as? [[String: Any]] ?? []
            return blocks.contains { $0["type"] as? String == "tool_result" } ? Work(at: at, words: 0) : nil
        default:
            return nil
        }
    }

    /// For a Claude Code prompt line, whether it came from the app rather
    /// than you (a scheduled task, a background-task notice); nil for any
    /// other line. A session whose first prompt is one is a scheduled task.
    public static func claudeCodePromptIsAutomated(_ line: Data) -> Bool? {
        guard let o = object(line), o["type"] as? String == "user", o["isMeta"] as? Bool != true,
              o["isSidechain"] as? Bool != true, o["isCompactSummary"] as? Bool != true,
              let msg = o["message"] as? [String: Any] else { return nil }
        if let blocks = msg["content"] as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        return o["promptSource"] as? String == "system"
    }

    /// One line of a Codex session (also the ChatGPT desktop app's chats):
    /// replies, reasoning and tool calls are work; messages to the model
    /// (yours, its instructions) are not.
    public static func codexWork(_ line: Data) -> Work? {
        guard let o = object(line), o["type"] as? String == "response_item",
              let p = o["payload"] as? [String: Any], let at = AIChats.date(o["timestamp"] as? String) else { return nil }
        if p["type"] as? String == "message" {
            guard p["role"] as? String == "assistant" else { return nil }
            let text = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
            return Work(at: at, words: words(text))
        }
        return Work(at: at, words: 0)
    }

    /// From a Codex `session_meta` line: whether the session is a helper
    /// Codex started itself (its approval reviewer and other subagents),
    /// whose work you never read. Nil for any other line.
    public static func codexSubagent(_ line: Data) -> Bool? {
        guard let o = object(line), o["type"] as? String == "session_meta",
              let p = o["payload"] as? [String: Any] else { return nil }
        if let s = p["source"] as? [String: Any], s["subagent"] != nil { return true }
        return false
    }

    /// Work lines folded into one row per session per minute.
    public static func minutes(_ work: [Work], tool: String, session: String) -> [Minute] {
        var byMinute: [Int: Int] = [:]
        for w in work {
            let m = Int(floor(w.at.timeIntervalSince1970 / 60)) * 60
            byMinute[m, default: 0] += w.words
        }
        return byMinute.keys.sorted().map {
            Minute(at: Date(timeIntervalSince1970: TimeInterval($0)), tool: tool, session: session, words: byMinute[$0]!)
        }
    }

    /// The same session-minute read in two scans becomes one row.
    public static func merged(_ rows: [Minute]) -> [Minute] {
        var out: [String: Minute] = [:]
        for r in rows {
            if var m = out[r.key] { m.words += r.words; out[r.key] = m } else { out[r.key] = r }
        }
        return out.values.sorted { $0.at < $1.at }
    }

    /// Minutes of one session less than this apart are one stretch of work
    /// (a long model call or build writes nothing in between).
    public static let workGap: TimeInterval = 180

    /// Stretches when each session was working, before any union.
    public static func workIntervals(_ rows: [Minute]) -> [(provider: Provider?, interval: DateInterval)] {
        var bySession: [String: [Minute]] = [:]
        for r in rows { bySession[r.tool + "|" + r.session, default: []].append(r) }
        var out: [(Provider?, DateInterval)] = []
        for (_, list) in bySession {
            let sorted = list.sorted { $0.at < $1.at }
            var start = sorted[0].at, end = sorted[0].at.addingTimeInterval(60)
            let p = provider(tool: sorted[0].tool)
            for m in sorted.dropFirst() {
                if m.at.timeIntervalSince(end) <= workGap - 60 { end = max(end, m.at.addingTimeInterval(60)) }
                else { out.append((p, DateInterval(start: start, end: end))); start = m.at; end = m.at.addingTimeInterval(60) }
            }
            out.append((p, DateInterval(start: start, end: end)))
        }
        return out.map { (provider: $0.0, interval: $0.1) }
    }

    static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for i in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
            } else { out.append(i) }
        }
        return out
    }

    static func overlap(_ list: [DateInterval], _ a: Date, _ b: Date) -> Double {
        list.reduce(0) { $0 + max(0, min($1.end, b).timeIntervalSince(max($1.start, a))) }
    }

    // MARK: - Summary

    public struct Day: Equatable, Sendable, Identifiable {
        public var date: Date
        /// An AI tool in front.
        public var aiSeconds: Double = 0
        /// Anything in front, at the Mac.
        public var macSeconds: Double = 0
        public var wrote = 0
        public var read = 0
        public var messages = 0
        /// Wall-clock time any AI was working for you.
        public var workSeconds: Double = 0
        public var id: Date { date }
        public var share: Double { macSeconds > 0 ? aiSeconds / macSeconds : 0 }
    }

    public struct Tool: Equatable, Sendable, Identifiable {
        public var provider: Provider
        public var aiSeconds: Double = 0
        public var wrote = 0
        public var read = 0
        public var messages = 0
        public var workSeconds: Double = 0
        public var id: Provider { provider }
    }

    /// Timer blocks of one category and how much of them had AI in front.
    public struct Category: Equatable, Sendable, Identifiable {
        public var name: String
        public var isFocus = false
        public var trackedSeconds: Double = 0
        /// Of those blocks, time anything was in front at the Mac.
        public var macSeconds: Double = 0
        public var aiSeconds: Double = 0
        public var messages = 0
        public var id: String { name }
        public var share: Double? { macSeconds >= 5 * 60 ? aiSeconds / macSeconds : nil }
    }

    public struct Summary: Equatable, Sendable {
        public var period: DateInterval
        public var days: [Day]
        public var tools: [Tool]
        public var categories: [Category]
        /// Time any AI was working, sessions running side by side counted once.
        public var workSeconds: Double
        /// The same, each session counted separately.
        public var parallelWorkSeconds: Double

        public var aiSeconds: Double { days.reduce(0) { $0 + $1.aiSeconds } }
        public var macSeconds: Double { days.reduce(0) { $0 + $1.macSeconds } }
        public var wrote: Int { days.reduce(0) { $0 + $1.wrote } }
        public var read: Int { days.reduce(0) { $0 + $1.read } }
        public var messages: Int { days.reduce(0) { $0 + $1.messages } }
        public var share: Double { macSeconds > 0 ? aiSeconds / macSeconds : 0 }

        /// Days with anything to count, for per-day averages (a day the Mac
        /// was off doesn't pull them down).
        public var activeDays: Int { days.filter { $0.macSeconds > 0 || $0.wrote > 0 || $0.workSeconds > 0 }.count }
        public var perDay: (aiSeconds: Double, wrote: Double, read: Double, workSeconds: Double) {
            let n = Double(max(1, activeDays))
            return (aiSeconds / n, Double(wrote) / n, Double(read) / n, workSeconds / n)
        }
    }

    static let notAtTheMac: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    public static func summarize(period p: DateInterval, segments: [WindowTimeline.LabeledSegment], sessions: [Insights.Session],
                                 messages: [AIChats.Message], minutes: [Minute], calendar: Calendar = .current) -> Summary {
        var dayStarts: [Date] = []
        var d = calendar.startOfDay(for: p.start)
        while d < p.end { dayStarts.append(d); d = calendar.date(byAdding: .day, value: 1, to: d) ?? p.end }
        func dayIndex(_ t: Date) -> Int? { dayStarts.firstIndex(of: calendar.startOfDay(for: t)) }
        var days = dayStarts.map { Day(date: $0) }
        var tools: [Provider: Tool] = [:]

        var ai: [DateInterval] = []
        var mac: [DateInterval] = []
        for l in segments {
            let s = l.segment
            guard !notAtTheMac.contains(s.bundle) else { continue }
            let a = max(s.start, p.start), b = min(s.end, p.end)
            guard b > a else { continue }
            let len = b.timeIntervalSince(a)
            mac.append(DateInterval(start: a, end: b))
            let prov = provider(bundle: s.bundle, url: s.url)
            if let prov { ai.append(DateInterval(start: a, end: b)); tools[prov, default: Tool(provider: prov)].aiSeconds += len }
            if let i = dayIndex(a) {
                days[i].macSeconds += len
                if prov != nil { days[i].aiSeconds += len }
            }
        }

        let msgs = messages.filter { p.contains($0.at) }
        for m in msgs {
            let w = words(m.text)
            if let i = dayIndex(m.at) { days[i].wrote += w; days[i].messages += 1 }
            if let prov = provider(tool: m.tool) {
                tools[prov, default: Tool(provider: prov)].wrote += w
                tools[prov]!.messages += 1
            }
        }

        let rows = merged(minutes.filter { p.contains($0.at) })
        for r in rows where r.words > 0 {
            if let i = dayIndex(r.at) { days[i].read += r.words }
            if let prov = provider(tool: r.tool) { tools[prov, default: Tool(provider: prov)].read += r.words }
        }
        let work = workIntervals(rows).compactMap { w -> (Provider?, DateInterval)? in
            let a = max(w.interval.start, p.start), b = min(w.interval.end, p.end)
            return b > a ? (w.provider, DateInterval(start: a, end: b)) : nil
        }
        let allWork = union(work.map(\.1))
        for (i, start) in dayStarts.enumerated() {
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? p.end
            days[i].workSeconds = overlap(allWork, start, end)
        }
        for prov in Provider.allCases {
            let mine = union(work.filter { $0.0 == prov }.map(\.1))
            guard !mine.isEmpty else { continue }
            tools[prov, default: Tool(provider: prov)].workSeconds = mine.reduce(0) { $0 + $1.duration }
        }

        let aiUnion = union(ai), macUnion = union(mac)
        var cats: [String: Category] = [:]
        for s in sessions where s.category != "Sleep" {
            let a = max(s.start, p.start), b = min(s.end, p.end)
            guard b > a else { continue }
            var c = cats[s.category] ?? Category(name: s.category)
            c.isFocus = c.isFocus || s.isFocus
            c.trackedSeconds += b.timeIntervalSince(a)
            c.macSeconds += overlap(macUnion, a, b)
            c.aiSeconds += overlap(aiUnion, a, b)
            c.messages += msgs.filter { $0.at >= a && $0.at < b }.count
            cats[s.category] = c
        }

        return Summary(period: p, days: days,
                       tools: tools.values.sorted { ($0.aiSeconds + $0.workSeconds) > ($1.aiSeconds + $1.workSeconds) },
                       categories: cats.values.sorted { $0.isFocus != $1.isFocus ? $0.isFocus : $0.trackedSeconds > $1.trackedSeconds },
                       workSeconds: allWork.reduce(0) { $0 + $1.duration },
                       parallelWorkSeconds: work.reduce(0) { $0 + $1.1.duration })
    }
}
