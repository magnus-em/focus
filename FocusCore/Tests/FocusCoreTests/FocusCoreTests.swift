import XCTest
@testable import FocusCore

final class RecallSchedulerTests: XCTestCase {
    func testLadderClimbsOneRungOnGot() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 1, grade: .got, hinted: false), 3)
        XCTAssertEqual(RecallScheduler.nextInterval(current: 3, grade: .got, hinted: false), 7)
    }

    func testFluentSkipsARung() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 3, grade: .fluent, hinted: false), 14)
    }

    func testHintCapsAtPartialAndDropsARung() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 7, grade: .fluent, hinted: true), 3)
    }

    func testForgotRestarts() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 60, grade: .forgot, hinted: false), 1)
    }

    func testPastTheLadderDoublesUpToAYear() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 240, grade: .got, hinted: false), 365)
    }

    func testDueDateIsStartOfTheDayIntervalLater() {
        let cal = Calendar(identifier: .gregorian)
        let from = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 22))!
        let due = RecallScheduler.dueDate(from: from, interval: 3, calendar: cal)
        XCTAssertEqual(due, cal.date(from: DateComponents(year: 2026, month: 10, day: 16)))
    }
}

final class TimerDisplayTests: XCTestCase {
    let day: TimeInterval = FocusCategories.openEndedSeconds

    func testCountdownShowsTimeLeft() {
        XCTAssertEqual(FocusCategories.timeString(total: 25 * 60, remaining: 10 * 60 + 5), "10:05")
    }

    func testOvertimeShowsElapsedAndOvertime() {
        let total = day + 60 * 60, remaining = total - 75 * 60
        XCTAssertEqual(FocusCategories.timeString(total: total, remaining: remaining), "1:15:00")
        XCTAssertEqual(FocusCategories.overtime(total: total, remaining: remaining), 15 * 60)
    }

    func testLifeBlockHasNoOvertimeAndAFullRing() {
        XCTAssertNil(FocusCategories.overtime(total: day, remaining: day - 600))
        XCTAssertEqual(FocusCategories.progress(total: day, remaining: day - 600), 1)
        XCTAssertEqual(FocusCategories.countdown(total: day), 0)
    }
}

final class DurationTextTests: XCTestCase {
    func testNoZeroMinuteTails() {
        XCTAssertEqual(durationText(minutes: 420), "7h")
        XCTAssertEqual(durationText(minutes: 425.9), "7h 5m")
        XCTAssertEqual(durationText(minutes: 45), "45m")
        XCTAssertEqual(durationText(minutes: 0.4), "0m")
    }
}
