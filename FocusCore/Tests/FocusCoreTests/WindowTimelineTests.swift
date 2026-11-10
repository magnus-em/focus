import XCTest
@testable import FocusCore

final class WindowTimelineTests: XCTestCase {
    typealias E = WindowTimeline.Event
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testSegmentsFollowWindowRowsAndCountInput() {
        let ev: [E] = [
            .window(at(0), app: "Preview", bundle: "com.apple.Preview", title: "pset6.pdf"),
            .input(at(5), keys: 3, clicks: 0, scrolls: 2, moves: 10),
            .input(at(10), keys: 0, clicks: 0, scrolls: 0, moves: 0),
            .alive(at(20)),
            .window(at(25), app: "Messages", bundle: "com.apple.MobileSMS", title: nil),
            .alive(at(45)),
            .away(at(50), reason: "lock"),
        ]
        let s = WindowTimeline.segments(ev, from: at(0), to: at(100))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].seconds, 25)
        XCTAssertEqual(s[0].inputSeconds, 5)
        XCTAssertEqual(s[0].keys, 3)
        XCTAssertEqual(s[1].app, "Messages")
        XCTAssertEqual(s[1].seconds, 25)
    }

    func testRecorderGapAssumesNothing() {
        let ev: [E] = [
            .window(at(0), app: "Code", bundle: "com.microsoft.VSCode", title: "a.py"),
            .alive(at(20)),
            .alive(at(200)),
            .alive(at(220)),
        ]
        let s = WindowTimeline.segments(ev, from: at(0), to: at(1000))
        XCTAssertEqual(s.map(\.seconds), [20, 20])
        XCTAssertEqual(s[1].start, at(200))
    }

    func testOpenSegmentRunsToNowOnlyWhileRecorderIsFresh() {
        let ev: [E] = [.window(at(0), app: "Code", bundle: "b", title: "x"), .alive(at(20))]
        XCTAssertEqual(WindowTimeline.segments(ev, from: at(0), to: at(30)).first?.seconds, 30)
        XCTAssertEqual(WindowTimeline.segments(ev, from: at(0), to: at(300)).first?.seconds, 20)
    }

    func testAwaySpansAreCutOut() {
        let ev: [E] = [.window(at(0), app: "Code", bundle: "b", title: "x")] + stride(from: 20.0, through: 600, by: 20).map { E.alive(at($0)) }
        let s = WindowTimeline.segments(ev, away: [DateInterval(start: at(100), end: at(400))], from: at(0), to: at(600))
        XCTAssertEqual(s.map(\.seconds), [100, 200])
    }

    func testSpinnerGlyphsAreNotATitleChange() {
        XCTAssertEqual(WindowTimeline.normalizedTitle("⠋ claude — zsh"), "claude — zsh")
        XCTAssertEqual(WindowTimeline.normalizedTitle("✳ Fix tests"), "Fix tests")
    }

    func testLabelsComeFromReadingsThenSameWindowThenPrivate() {
        let segs = [
            WindowTimeline.Segment(start: at(0), end: at(60), app: "Preview", bundle: "p", title: "pset6.pdf"),
            WindowTimeline.Segment(start: at(60), end: at(68), app: "Messages", bundle: "sms"),
            WindowTimeline.Segment(start: at(68), end: at(75), app: "Chrome", bundle: "c", title: "(3) Home / X"),
            WindowTimeline.Segment(start: at(75), end: at(80), app: "Preview", bundle: "p", title: "pset6.pdf"),
            WindowTimeline.Segment(start: at(80), end: at(90), app: "Finder", bundle: "f", title: "Downloads"),
        ]
        let labels = [
            WindowTimeline.Label(start: at(-3000), end: at(-2900), bundle: "c", title: "(3) Home / X", category: "Leisure"),
            WindowTimeline.Label(start: at(5), end: at(50), bundle: "p", title: "pset6.pdf", category: "Math"),
        ]
        let l = WindowTimeline.label(segs, with: labels, privateBundles: ["sms"])
        XCTAssertEqual(l.map(\.category), ["Math", "Private", "Leisure", "Math", nil])
        XCTAssertEqual(l.map(\.source), [.reading, .privateApp, .sameWindow, .sameWindow, .none])
    }

    func testAttentionFindsGlancesDetoursAndStretches() {
        func seg(_ a: Double, _ b: Double, _ app: String, _ c: String?) -> WindowTimeline.LabeledSegment {
            .init(segment: .init(start: at(a), end: at(b), app: app, bundle: app, title: app), category: c, source: .reading)
        }
        let segs = [
            seg(0, 100, "Preview", "Math"), seg(100, 112, "Messages", "Private"), seg(112, 300, "Preview", "Math"),
            seg(300, 380, "Chrome", "Leisure"), seg(380, 420, "Messages", "Private"), seg(420, 430, "Finder", nil),
            seg(430, 600, "Preview", "Math"), seg(600, 700, "Chrome", "Leisure"),
        ]
        let life: Set<String> = ["Leisure", "Admin", "Private"]
        let r = WindowTimeline.attention(segs, blocks: [.init(start: at(0), end: at(650), category: "Math")],
                                         distracting: { life.contains($0) }, isFocus: { !life.contains($0) })
        XCTAssertEqual(r.excursions.count, 3)
        XCTAssertEqual(r.excursions[0].kind, .glance)
        XCTAssertEqual(r.excursions[0].category, "Private")
        XCTAssertTrue(r.excursions[0].returned)
        XCTAssertEqual(r.excursions[1].seconds, 120)
        XCTAssertEqual(r.excursions[1].category, "Leisure")
        XCTAssertEqual(r.excursions[1].apps, ["Chrome", "Messages"])
        XCTAssertFalse(r.excursions[2].returned)
        XCTAssertEqual(r.excursions[2].seconds, 50)
        XCTAssertEqual(r.stretches.map(\.seconds), [300, 170])
        XCTAssertEqual(r.onTaskSeconds, 458)
        XCTAssertEqual(r.seenSeconds, 650)
    }

    func testEventRowsAreCompact() throws {
        let data = try JSONEncoder().encode(E.input(at(5), keys: 3, clicks: 1, scrolls: 0, moves: 9))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"k\":3"))
        XCTAssertEqual(try JSONDecoder().decode(E.self, from: data).keys, 3)
    }
}
