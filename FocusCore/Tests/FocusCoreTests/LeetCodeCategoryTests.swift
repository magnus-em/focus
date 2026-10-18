import XCTest
@testable import FocusCore

final class LeetCodeCategoryTests: XCTestCase {
    func testSavedAndLiveLeetCodeStaySeparateAndCountTowardFocus() {
        let day = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let saved = [
            WorkSession(startTime: day.addingTimeInterval(-3600), durationMinutes: 20, type: .work, label: "SWE"),
            WorkSession(startTime: day.addingTimeInterval(-2400), durationMinutes: 15, type: .work, label: "LeetCode")
        ]
        let live = WorkSession(startTime: day.addingTimeInterval(-600), durationMinutes: 10, type: .work, label: "LeetCode")
        let detail = FocusStats.focusCategoryMinutes(saved, live: live, on: day, through: day, lifeTags: Set(FocusCategories.defaultLifeTags))
        XCTAssertEqual(detail["LeetCode"], 25)
        XCTAssertEqual(detail["SWE"], 20)
        XCTAssertEqual(detail.values.reduce(0, +), 45)
        let byTag = FocusStats.byTag(saved.map(StoredWorkSession.init(value:)))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: byTag.map { ($0.tag, $0.minutes) }), ["SWE": 20, "LeetCode": 15])
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

    func testLeetCodePracticeHasItsOwnScreenLabel() {
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Math", app: "Chrome", title: "Two Sum - LeetCode", text: "").category, "LeetCode")
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "SWE", app: "Chrome", title: "Practice | NeetCode", text: "").category, "LeetCode")
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Math", app: "Chrome", title: "Practice - HackerRank", text: "").category, "SWE")
        XCTAssertTrue(ScreenClassificationPolicy.isLeetCodePractice(title: "Two Sum", url: "https://leetcode.com/problems/two-sum/"))
        XCTAssertFalse(ScreenClassificationPolicy.isLeetCodePractice(title: "Article", url: "https://leetcode.com.evil.example/"))
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "LeetCode", app: "Codex", title: "Focus project settings", text: "Implement the LeetCode daily goal in the Focus tracker project").category, "Admin")
    }

    func testDailyGoalsRequireBothTimeAndProblems() {
        XCTAssertFalse(LeetCodeDailyGoal.isMet(problems: 4, minutes: 119, problemGoal: 4, minutesGoal: 120))
        XCTAssertFalse(LeetCodeDailyGoal.isMet(problems: 3, minutes: 140, problemGoal: 4, minutesGoal: 120))
        XCTAssertTrue(LeetCodeDailyGoal.isMet(problems: 4, minutes: 120, problemGoal: 4, minutesGoal: 120))
        XCTAssertFalse(LeetCodeDailyGoal.isMet(problems: 4, minutes: .nan, problemGoal: 4, minutesGoal: 120))
    }

    func testRepeatsOnSameDayDoNotInflateDailyWorkAndPriorSolvesAreRedos() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        func entry(_ date: Date, title: String = "Two Sum", url: String = "https://leetcode.com/problems/two-sum/") -> ProblemEntry {
            ProblemEntry(id: UUID(), date: date, title: title, domain: .swe, categories: [], difficulty: .easy, source: "LeetCode", url: url)
        }
        let problems = [entry(yesterday), entry(today), entry(today, url: ""), entry(today, title: "New Problem", url: "https://leetcode.com/problems/new-problem/")]
        let summary = LeetCodeDailyGoal.summary(problems, on: today)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.new, 1)
        XCTAssertEqual(summary.redo, 1)
    }
}
