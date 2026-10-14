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

final class DailyFocusCategoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))! }

    func testAggregatesRepeatedFocusAndLiveWorkWithoutLifeOrBreaks() {
        let sessions = [
            WorkSession(startTime: day, durationMinutes: 1, type: .work, label: "Math"),
            WorkSession(startTime: day.addingTimeInterval(120), durationMinutes: 1.5, type: .work, label: "Math"),
            WorkSession(startTime: day, durationMinutes: 30, type: .work, label: "Admin"),
            WorkSession(startTime: day, durationMinutes: 20, type: .shortBreak, label: "Math"),
            WorkSession(startTime: day, durationMinutes: 2, type: .work, label: "AI")
        ]
        let live = WorkSession(startTime: day.addingTimeInterval(600), durationMinutes: 3, type: .work, label: "SWE")
        let totals = FocusStats.focusCategoryMinutes(sessions, live: live, on: day,
                                                     through: day.addingTimeInterval(3600), lifeTags: ["Admin"], calendar: calendar)
        XCTAssertEqual(totals["Math"], 2.5)
        XCTAssertEqual(totals["SWE"], 3)
        XCTAssertNil(totals["Admin"])
        XCTAssertEqual(Set(totals.filter { $0.value > 2 }.keys), ["Math", "SWE"])
    }

    func testClipsMidnightSessionsAndIgnoresFutureTime() {
        let sessions = [
            WorkSession(startTime: day.addingTimeInterval(-900), durationMinutes: 45, type: .work, label: "Math"),
            WorkSession(startTime: day.addingTimeInterval(7200), durationMinutes: 60, type: .work, label: "SWE")
        ]
        let totals = FocusStats.focusCategoryMinutes(sessions, on: day, through: day.addingTimeInterval(600),
                                                     lifeTags: [], calendar: calendar)
        XCTAssertEqual(totals["Math"], 10)
        XCTAssertNil(totals["SWE"])
    }
}
