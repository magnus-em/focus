import XCTest
@testable import FocusCore

final class LeetCodeCategoryTests: XCTestCase {
    func testSavedAndLiveLeetCodeRollUpOnceIntoSWE() {
        let day = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let saved = [
            WorkSession(startTime: day.addingTimeInterval(-3600), durationMinutes: 20, type: .work, label: "SWE"),
            WorkSession(startTime: day.addingTimeInterval(-2400), durationMinutes: 15, type: .work, label: "LeetCode")
        ]
        let live = WorkSession(startTime: day.addingTimeInterval(-600), durationMinutes: 10, type: .work, label: "LeetCode")
        let detail = FocusStats.focusCategoryMinutes(saved, live: live, on: day, through: day, lifeTags: Set(FocusCategories.defaultLifeTags))
        XCTAssertEqual(detail["LeetCode"], 25)
        XCTAssertEqual(FocusCategories.rolledUp(detail), ["SWE": 45])
        XCTAssertEqual(FocusCategories.rolledUp(detail).values.reduce(0, +), 45)
        XCTAssertTrue(saved[1].isFocus)
        XCTAssertFalse(FocusCategories.neverBlocks.contains("LeetCode"))
    }

    func testDailyMinimumUsesSolvesOnTheSelectedCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
        func problem(_ title: String, _ source: String, _ url: String, _ date: Date, domain: ProblemDomain = .swe) -> ProblemEntry {
            ProblemEntry(id: UUID(), date: date, title: title, domain: domain, categories: [], difficulty: .medium, source: source, url: url)
        }
        let problems = [
            problem("Outside the catalog", "", "https://leetcode.com/problems/new-problem/", today),
            problem("Manual solve", "LeetCode", "", today),
            problem("Two Sum", "", "", today),
            problem("Other SWE", "Textbook", "", today),
            problem("Yesterday", "LeetCode", "", today.addingTimeInterval(-86400)),
            problem("Tomorrow", "LeetCode", "", today.addingTimeInterval(86400)),
            problem("Wrong domain", "LeetCode", "", today, domain: .quant),
            problem("Spoofed host", "", "https://leetcode.com.evil.example/problems/a/", today)
        ]
        XCTAssertEqual(LeetCodeDailyGoal.count(problems, on: today, calendar: calendar), 3)
        XCTAssertEqual(LeetCodeDailyGoal.count(problems, on: today.addingTimeInterval(86400), calendar: calendar), 1)
        XCTAssertEqual(LeetCodeDailyGoal.count([], on: today, calendar: calendar), 0)
    }

    func testParentScreenLabelDoesNotSwitchAwayFromChosenSubcategory() {
        XCTAssertTrue(FocusCategories.screenAgrees("SWE", running: "LeetCode"))
        XCTAssertFalse(FocusCategories.screenAgrees("Admin", running: "LeetCode"))
        XCTAssertFalse(FocusCategories.screenAgrees("Math", running: "LeetCode"))
        XCTAssertFalse(FocusCategories.screenAgrees("LeetCode", running: "SWE"))
    }
}
