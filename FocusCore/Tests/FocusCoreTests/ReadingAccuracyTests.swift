import XCTest
@testable import FocusCore

final class ReadingAccuracyTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private var day: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 14))! }
    private func t(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }

    private func run(spans: [ReadingAccuracy.Span], blocks: [ReadingAccuracy.Block],
                     corrections: [ReadingAccuracy.Correction] = [], switches: [ReadingAccuracy.AutoSwitch] = []) -> [ReadingAccuracy.Day] {
        ReadingAccuracy.days(spans: spans, blocks: blocks, corrections: corrections, autoSwitches: switches,
                             from: day, to: t(48), calendar: cal)
    }

    func testMatchUnlabeledAndOutsideBlocks() {
        let d = run(spans: [
            .init(start: t(10), end: t(10.5), window: "a", category: "Math", uncertain: false),
            .init(start: t(10.5), end: t(10.75), window: "b", category: "Leisure", uncertain: false),
            .init(start: t(10.75), end: t(11), window: "c", category: nil, uncertain: false),
            .init(start: t(13), end: t(14), window: "a", category: "Math", uncertain: false),
        ], blocks: [.init(start: t(10), end: t(11), label: "Math")])[0]
        XCTAssertEqual(d.readSeconds, 3600, accuracy: 1)
        XCTAssertEqual(d.labeledSeconds, 2700, accuracy: 1)
        XCTAssertEqual(d.right!, 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(d.unlabeled!, 0.25, accuracy: 0.001)
    }

    func testUnsureCountsAsNoLabel() {
        let d = run(spans: [.init(start: t(9), end: t(10), window: "a", category: "SWE", uncertain: true)],
                    blocks: [.init(start: t(9), end: t(10), label: "SWE")])[0]
        XCTAssertEqual(d.unlabeled!, 1, accuracy: 0.001)
        XCTAssertNil(d.right)
    }

    /// A window you corrected was misread until you said so, even where its
    /// label matched the block (the block was renamed from that same reading).
    func testCorrectionMarksTheWindowWrongUntilThen() {
        let c = ReadingAccuracy.Correction(at: t(10.5), app: "Preview", bundle: "p", title: "hw", windows: ["a"], since: t(10),
                                           wasCategory: "SWE", wasCourse: nil, wasSource: "label", toCategory: "Math",
                                           toCourse: "MATH 244", block: "SWE", renamedTo: "Math", via: "popover")
        let d = run(spans: [.init(start: t(10), end: t(11), window: "a", category: "Math", uncertain: false)],
                    blocks: [.init(start: t(10), end: t(11), label: "Math")], corrections: [c])[0]
        XCTAssertEqual(d.right!, 0.5, accuracy: 0.001)
        XCTAssertEqual(d.corrections, 1)
        XCTAssertEqual(d.courseCorrections, 1)
    }

    func testUndoneSwitchesAndBar() {
        let days = run(spans: [.init(start: t(9), end: t(10), window: "a", category: "AI", uncertain: false)],
                       blocks: [.init(start: t(9), end: t(10), label: "AI")],
                       switches: [.init(at: t(9.5), undone: false), .init(at: t(9.6), undone: true), .init(at: t(30), undone: false)])
        XCTAssertEqual(days[0].autoSwitches, 2)
        XCTAssertEqual(days[0].undone, 1)
        XCTAssertEqual(days[0].meetsBar, false)
        XCTAssertEqual(days[1].autoSwitches, 1)
        XCTAssertEqual(ReadingAccuracy.total(days).autoSwitches, 3)
    }

    func testSplitsAtMidnight() {
        let days = run(spans: [.init(start: t(23.5), end: t(24.5), window: "a", category: "Math", uncertain: false)],
                       blocks: [.init(start: t(23), end: t(25), label: "Math")])
        XCTAssertEqual(days[0].readSeconds, 1800, accuracy: 1)
        XCTAssertEqual(days[1].readSeconds, 1800, accuracy: 1)
    }

    func testCorrectionRoundTripsAsJSON() throws {
        let c = ReadingAccuracy.Correction(at: t(1), app: "Chrome", bundle: "com.google.Chrome", title: "x", windows: ["k"], since: t(0),
                                           wasCategory: nil, wasCourse: nil, wasSource: "unread", toCategory: "Admin",
                                           toCourse: nil, block: nil, renamedTo: nil, via: "hotkey")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(ReadingAccuracy.Correction.self, from: enc.encode(c)), c)
    }
}
