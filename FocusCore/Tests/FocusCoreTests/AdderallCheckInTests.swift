import XCTest
@testable import FocusCore

final class AdderallCheckInTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 21))! }
    private func key(_ d: Int) -> String { AdderallCheckIn.dayKey(day(d), calendar: cal) }

    func testDayKeyRoundTrips() {
        XCTAssertEqual(key(7), "2026-11-07")
        XCTAssertEqual(AdderallCheckIn.date("2026-11-07", calendar: cal), cal.startOfDay(for: day(7)))
    }

    func testMergeKeepsNewestEdit() {
        let old = AdderallCheckIn(day: key(1), tookDose: true, focus: 3, updatedAt: Date(timeIntervalSince1970: 10))
        let new = AdderallCheckIn(day: key(1), tookDose: true, focus: 8, updatedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(AdderallCheckIn.merge([old.day: new], [old.day: old])[old.day]?.focus, 8)
        XCTAssertEqual(AdderallCheckIn.merge([old.day: old], [old.day: new])[old.day]?.focus, 8)
    }

    func testSummarySplitsDoseAndOffDaysAndCreditsSleepToDayBefore() {
        var all: [String: AdderallCheckIn] = [:]
        all[key(3)] = AdderallCheckIn(day: key(3), tookDose: true, focus: 8, sleep: 7, hoursWorked: 6, comedown: 4, worthIt: 8, effects: ["Headache"])
        all[key(4)] = AdderallCheckIn(day: key(4), tookDose: false, focus: 4, sleep: 3)
        all[key(5)] = AdderallCheckIn(day: key(5), tookDose: true, focus: 6, sleep: 8, hoursWorked: 5, comedown: 2, worthIt: 6, effects: ["Headache", "Dry mouth"])
        all[key(6)] = AdderallCheckIn(day: key(6), tookDose: false, focus: 2, sleep: 5)
        let s = CheckInSummary.make(all, days: 7, end: day(7), calendar: cal)
        XCTAssertEqual(s.checkIns, 4)
        XCTAssertEqual(s.doseDays, 2)
        let focus = s.splits.first { $0.metric == .focus }!
        XCTAssertEqual(focus.dose, 7)
        XCTAssertEqual(focus.off, 3)
        // Night after 11/3 (dose) was answered on 11/4 (3); after 11/5 on 11/6 (5).
        let sleep = s.splits.first { $0.metric == .sleep }!
        XCTAssertEqual(sleep.dose, 4)
        XCTAssertEqual(sleep.doseDays, 2)
        // Night after 11/4 (off) was answered on 11/5 (8); 11/6's night has no answer yet.
        XCTAssertEqual(sleep.off, 8)
        XCTAssertEqual(sleep.offDays, 1)
        let worth = s.splits.first { $0.metric == .worthIt }!
        XCTAssertEqual(worth.dose, 7)
        XCTAssertNil(worth.off)
        XCTAssertEqual(s.effects.first?.name, "Headache")
        XCTAssertEqual(s.effects.first?.days, 2)
    }

    func testOffDayIgnoresDoseOnlyAnswers() {
        let c = AdderallCheckIn(day: key(1), tookDose: false, hoursWorked: 4, comedown: 3, worthIt: 2)
        XCTAssertNil(CheckInMetric.hoursWorked.value(c))
        XCTAssertNil(CheckInMetric.worthIt.value(c))
        XCTAssertEqual(CheckInMetric.focus.value(c), 5)
    }

    func testPreviousWindowComparesDoseDays() {
        var all: [String: AdderallCheckIn] = [:]
        all[key(1)] = AdderallCheckIn(day: key(1), tookDose: true, focus: 4, hoursWorked: 4, comedown: 1, worthIt: 4)
        all[key(6)] = AdderallCheckIn(day: key(6), tookDose: true, focus: 8, hoursWorked: 6, comedown: 1, worthIt: 8)
        let s = CheckInSummary.make(all, days: 3, end: day(7), calendar: cal)
        let focus = s.splits.first { $0.metric == .focus }!
        XCTAssertEqual(focus.dose, 8)
        XCTAssertNil(focus.previous)
        let wide = CheckInSummary.make(all, days: 5, end: day(7), calendar: cal)
        XCTAssertEqual(wide.splits.first { $0.metric == .focus }!.previous, 4)
    }
}
