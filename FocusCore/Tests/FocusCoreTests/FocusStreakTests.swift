import XCTest
@testable import FocusCore

final class FocusStreakTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let life: Set<String> = ["Leisure", "Admin", "Social", "Meals"]
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func seg(_ a: Double, _ b: Double, _ app: String, _ c: String?, bundle: String? = nil, title: String? = nil,
             url: String? = nil, coarse: Bool = false, source: String? = nil) -> WindowTimeline.LabeledSegment {
        .init(segment: .init(start: at(a), end: at(b), app: app, bundle: bundle ?? app, title: title ?? app, url: url),
              category: c, source: .reading, coarse: coarse, labelSource: source)
    }
    func block(_ a: Double, _ b: Double, _ c: String = "Math") -> WindowTimeline.Block { .init(start: at(a), end: at(b), category: c) }

    func testKinds() {
        XCTAssertEqual(FocusStreak.kind(app: "Messages", bundle: "com.apple.MobileSMS", title: nil, url: nil, category: "Private", life: life), .distraction("Messages"))
        XCTAssertEqual(FocusStreak.kind(app: "ChatGPT", bundle: "com.openai.chat", title: "Bayes", url: nil, category: nil, life: life), .study)
        XCTAssertEqual(FocusStreak.kind(app: "ChatGPT", bundle: "com.openai.chat", title: "Bayes", url: nil, category: "SWE", life: life), .study)
        XCTAssertEqual(FocusStreak.kind(app: "Google Chrome", bundle: "c", title: "claude", url: "https://claude.ai/chat/1", category: nil, life: life), .study)
        XCTAssertEqual(FocusStreak.kind(app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Fix the timer", url: nil,
                                        category: "Admin", labelSource: "rule", life: life), .distraction("Working on Focus"))
        XCTAssertEqual(FocusStreak.kind(app: "Google Chrome", bundle: "c", title: "(3) Home / X", url: nil, category: "Leisure", life: life), .distraction("X"))
        XCTAssertEqual(FocusStreak.kind(app: "Finder", bundle: "f", title: "Downloads", url: nil, category: nil, life: life), .neutral)
        XCTAssertEqual(FocusStreak.kind(app: "Preview", bundle: "p", title: "pset", url: nil, category: "HW", life: life), .study)
    }

    func testStretchesEndAtRealDistractionsOnly() {
        let segs = [
            seg(0, 600, "Preview", "Math"),
            seg(600, 603, "Messages", "Private"),          // 3 s glance: absorbed
            seg(603, 900, "ChatGPT", nil, bundle: "com.openai.chat"), // AI chat about it: study
            seg(900, 960, "Finder", nil),                   // neutral
            seg(960, 1500, "Preview", "Math"),
            seg(1500, 1520, "Messages", "Private"),         // 20 s: ends the stretch
            seg(1520, 1530, "Google Chrome", "Leisure", title: "YouTube"), // same trip away
            seg(1530, 2100, "Preview", "Math"),
        ]
        let r = FocusStreak.stretches(segs, blocks: [block(0, 2100)], life: life)
        XCTAssertEqual(r.stretches.map(\.minutes), [25, 9.5])
        XCTAssertEqual(r.stretches.first?.endedBy, "Messages")
        XCTAssertNil(r.stretches.last?.endedBy)
        XCTAssertEqual(r.distractions.count, 1)
        XCTAssertEqual(r.distractions.first?.seconds, 30)
        XCTAssertEqual(r.distractions.first?.endedMinutes, 25)
        XCTAssertEqual(r.fineSeconds, 2100)
    }

    func testHoleInTheRecordEndsAStretchWithoutBlame() {
        let segs = [seg(0, 600, "Preview", "Math"), seg(1200, 1800, "Preview", "Math")]
        let r = FocusStreak.stretches(segs, blocks: [block(0, 1800)], life: life)
        XCTAssertEqual(r.stretches.map(\.minutes), [10, 10])
        XCTAssertTrue(r.distractions.isEmpty)
        // 15 s readings have holes up to 2 min that aren't absences.
        let coarse = [seg(0, 600, "Preview", "Math", coarse: true), seg(690, 1200, "Preview", "Math", coarse: true)]
        XCTAssertEqual(FocusStreak.stretches(coarse, blocks: [block(0, 1200)], life: life).stretches.map(\.minutes), [20])
    }

    func testHalfTime() {
        func s(_ m: Double) -> FocusStreak.Stretch { .init(start: t0, end: t0.addingTimeInterval(m * 60), category: "Math", studySeconds: m * 60) }
        XCTAssertEqual(FocusStreak.halfTimeMinutes([s(40), s(5), s(5), s(10)]), 40)
        XCTAssertEqual(FocusStreak.halfTimeMinutes([s(10), s(10), s(10), s(10)]), 10)
        XCTAssertEqual(FocusStreak.halfTimeMinutes([]), 0)
    }

    func testLiveCountBreaksNudgesAndComesBack() {
        var live = FocusStreak.Live()
        let day = "2026-11-13"
        var events: [FocusStreak.Event] = []
        for i in 0..<600 { if let e = live.tick(at(Double(i)), kind: .study, day: day) { events.append(e) } }
        XCTAssertEqual(live.current(at: at(599)), 599)
        for i in 600..<603 { if let e = live.tick(at(Double(i)), kind: .distraction("Messages"), day: day) { events.append(e) } }
        XCTAssertEqual(live.tick(at(603), kind: .study, day: day), nil, "a 3 s glance doesn't end it")
        XCTAssertEqual(live.current(at: at(603)), 603)
        for i in 604..<620 { if let e = live.tick(at(Double(i)), kind: .distraction("Messages"), day: day) { events.append(e) } }
        XCTAssertEqual(events, [.broke(name: "Messages", minutes: 604.0 / 60), .nudge(name: "Messages", minutes: 604.0 / 60)])
        XCTAssertEqual(live.current(at: at(619)), 0)
        XCTAssertEqual(live.tick(at(620), kind: .study, day: day), .back)
        XCTAssertEqual(live.current(at: at(680)), 60)
        XCTAssertEqual(live.best(at: at(680), day: day), 604)
        XCTAssertEqual(live.brokenToday, 1)
    }

    func testLiveStopsWithoutBlameWhenAwayOrNoFocus() {
        var live = FocusStreak.Live()
        let day = "2026-11-13"
        for i in 0..<300 { _ = live.tick(at(Double(i)), kind: .study, day: day) }
        XCTAssertNil(live.tick(at(300), kind: nil, day: day))
        XCTAssertEqual(live.current(at: at(300)), 0)
        XCTAssertEqual(live.best(at: at(300), day: day), 300)
        XCTAssertEqual(live.brokenToday, 0)
        _ = live.tick(at(301), kind: .study, day: day)
        XCTAssertNil(live.tick(at(400), kind: .study, day: day), "a 99 s hole (asleep) restarts the count")
        XCTAssertEqual(live.current(at: at(400)), 0)
        XCTAssertEqual(live.tick(at(401), kind: .neutral, day: day), nil)
    }

    func testNoNudgeForAShortStretch() {
        var live = FocusStreak.Live()
        for i in 0..<60 { _ = live.tick(at(Double(i)), kind: .study, day: "d") }
        var events: [FocusStreak.Event] = []
        for i in 60..<90 { if let e = live.tick(at(Double(i)), kind: .distraction("YouTube"), day: "d") { events.append(e) } }
        XCTAssertEqual(events, [.broke(name: "YouTube", minutes: 1)])
    }
}
