import Foundation
import FocusCore

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let cal = Calendar.current
let dayArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "2026-10-15"
let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
let day = f.date(from: dayArg)!
let dayEnd = cal.date(byAdding: .day, value: 1, to: day)!
let now = min(Date(), dayEnd)
// sessions: lines "unixStart|minutes|label|type" on stdin file
let sessText = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
var tracked: [DayStory.Tracked] = sessText.split(separator: "\n").map { l in
    let p = l.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let s = Date(timeIntervalSince1970: Double(p[0])!)
    return DayStory.Tracked(start: s, end: s.addingTimeInterval(Double(p[1])! * 60),
                            label: p[3] == "work" ? (p[2].isEmpty ? "Focus" : p[2]) : "Break")
}
if CommandLine.arguments.count > 3, let runStart = Double(CommandLine.arguments[3]) {
    tracked.append(.init(start: Date(timeIntervalSince1970: runStart), end: now, label: CommandLine.arguments[4], running: true))
}
let record = CoachDay.load(day, from: support.appendingPathComponent("Focus/days"))
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let epText = (try? String(contentsOf: support.appendingPathComponent("Focus/episodes/\(dayArg).jsonl"), encoding: .utf8)) ?? ""
let observations = epText.split(separator: "\n").compactMap { try? dec.decode(CoachEpisode.Record.self, from: Data($0.utf8)) }
    .filter { $0.source.privacy == .notBrowser || $0.source.privacy == .regular }
struct Span: Decodable { let start: Double; let end: Double; let category: String?; let active: Bool? }
let spans = (try? JSONDecoder().decode([Span].self, from: Data(contentsOf: support.appendingPathComponent("Focus/screen.json")))) ?? []
let screen = spans.map { DayStory.Screen(start: Date(timeIntervalSinceReferenceDate: $0.start), end: Date(timeIntervalSinceReferenceDate: $0.end), category: $0.category) }
    .filter { $0.end > day && $0.start < dayEnd }
func t(_ h: Int, _ m: Int) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: day)! }
let eventsArg = ProcessInfo.processInfo.environment["EVENTS"] ?? ""
let events: [DayStory.CalendarEvent] = eventsArg.split(separator: ";").map { e in
    let p = e.split(separator: ",").map(String.init)
    func hm(_ s: String) -> Date { let x = s.split(separator: ":").map { Int($0)! }; return t(x[0], x[1]) }
    return .init(start: hm(p[0]), end: hm(p[1]), title: p[2])
}
let focus: Set<String> = ["SWE", "Math", "Quant", "AI", "HW"]
let story = DayStory.build(day: day, now: now, tracked: tracked, record: record, observations: observations, events: events,
                           screen: screen, focus: focus,
                           course: CoachCourse.resolver(observations, context: .init()))
let c = DateFormatter(); c.dateFormat = "HH:mm"
print("headline:", story.headline ?? "-", "asOf:", story.headlineAsOf.map(c.string) ?? "-")
for b in story.blocks {
    print("\(c.string(from: b.start))–\(c.string(from: b.end)) [\(b.category ?? "nil")] \(b.title) study=\(b.study) quiet=\(b.quiet) min=\(Int(b.minutes)) moments=\(b.moments.count) intr=\(b.interruptions.count)\(b.running ? " RUNNING" : "")")
    for m in b.moments.prefix(12) { print("    \(c.string(from: m.start))–\(c.string(from: m.end)) \(m.category ?? "-"): \(m.text.prefix(110))") }
    for i in b.interruptions { print("    ~ \(c.string(from: i.start)) \(i.category ?? "-") \(Int(i.minutes))m") }
    for x in b.fixes { print("    FIX \(x.kind) \(c.string(from: x.start))–\(c.string(from: x.end)) tracked=\(x.tracked ?? "-") sugg=\(x.suggestion ?? "-")") }
}
print("fixes:"); for x in story.fixes { print("  \(x.kind) \(c.string(from: x.start))–\(c.string(from: x.end)) \(Int(x.minutes))m tracked=\(x.tracked ?? "-") sugg=\(x.suggestion ?? "-")") }
print("courses:"); for co in story.courses { print("  \(co.code) [\(co.category)] \(Int(co.minutes))m obs=\(co.observations) practice=\(co.practiceShare.map { String(format: "%.2f", $0) } ?? "-") topics=\(co.topics.prefix(5)) shaky=\(co.shaky.count)") }
