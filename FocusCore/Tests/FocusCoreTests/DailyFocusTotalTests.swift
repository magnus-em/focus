import XCTest
@testable import FocusCore

final class DailyFocusTotalTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func totals(live: DailyFocusTotal.Live?, saved: [WorkSession] = [], now: Date) -> [String: Double] {
        DailyFocusTotal.categoryMinutes(saved: saved, live: live, on: now, through: now,
                                        lifeTags: ["Admin", "Sleep"], calendar: calendar)
    }

    func testRunningSessionClipsAtMidnight() {
        let result = totals(live: .init(start: date(13, 23, 50), activeSeconds: 20 * 60,
                                       label: "Math", isBreak: false), now: date(14, 0, 10))
        XCTAssertEqual(result["Math"], 10)
    }

    func testPausedWorkDoesNotAccumulateWallTime() {
        let live = DailyFocusTotal.Live(start: date(14, 10), activeSeconds: 15 * 60, label: "Math", isBreak: false)
        XCTAssertEqual(totals(live: live, now: date(14, 11))["Math"], 15)
        XCTAssertEqual(totals(live: live, now: date(14, 15))["Math"], 15)
    }

    func testBreakWithStickyFocusLabelAndLifeTimeDoNotCount() {
        XCTAssertTrue(totals(live: .init(start: date(14, 10), activeSeconds: 600, label: "Math", isBreak: true), now: date(14, 11)).isEmpty)
        XCTAssertTrue(totals(live: .init(start: date(14, 10), activeSeconds: 600, label: "Admin", isBreak: false), now: date(14, 11)).isEmpty)
    }

    func testSavedOvernightWorkIsClippedAndInvalidLiveTimeIsIgnored() {
        let saved = [WorkSession(startTime: date(13, 23), durationMinutes: 90, type: .work, label: "SWE")]
        XCTAssertEqual(totals(live: nil, saved: saved, now: date(14, 1))["SWE"], 30)
        XCTAssertTrue(totals(live: .init(start: date(14, 10), activeSeconds: .nan, label: "Math", isBreak: false), now: date(14, 11)).isEmpty)
        XCTAssertTrue(totals(live: .init(start: date(14, 12), activeSeconds: 600, label: "Math", isBreak: false), now: date(14, 11)).isEmpty)
    }
}
