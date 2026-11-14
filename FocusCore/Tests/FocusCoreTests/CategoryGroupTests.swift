import XCTest
@testable import FocusCore

final class CategoryGroupTests: XCTestCase {
    /// Every label in the log since 5/11.
    let logged = ["Sleep", "Leisure", "AI", "Quant", "Break", "SWE", "Exercise", "HW", "Math", "Class", "Reading",
                  "Admin", "Commute", "Meals", "Chores", "LeetCode", "Recruiting", "Journaling", "Social"]

    func testEveryLoggedCategoryHasAGroup() {
        for label in logged { XCTAssertNotNil(CategoryGroup.table[label], label) }
        XCTAssertEqual(Set(CategoryGroup.table.values), Set(CategoryGroup.allCases))
    }

    func testFocusTotalsDoNotMove() {
        let life = Set(FocusCategories.defaultLifeTags).union(["Break"])
        let focusGroups: Set<CategoryGroup> = [.school, .career, .learning]
        for (label, group) in CategoryGroup.table where label != "Class" {
            XCTAssertEqual(focusGroups.contains(group), !life.contains(label), label)
        }
        XCTAssertEqual(CategoryGroup.of("Class"), .school)
        XCTAssertTrue(life.contains("Class"))
    }

    func testDecidedHomes() {
        XCTAssertEqual(CategoryGroup.of("SWE"), .school)
        XCTAssertEqual(CategoryGroup.of("Quant"), .career)
        XCTAssertEqual(CategoryGroup.of("AI"), .learning)
        XCTAssertEqual(CategoryGroup.of("Admin"), .life)
        XCTAssertEqual(CategoryGroup.of("Reading"), .wellbeing)
    }

    func testBreaksAndBlanksAreFreeTime() {
        XCTAssertEqual(CategoryGroup.of("Math", isBreak: true), .freeTime)
        XCTAssertEqual(CategoryGroup.of(nil), .freeTime)
        XCTAssertEqual(CategoryGroup.of("  "), .freeTime)
    }

    func testCaseAndUnknownLabels() {
        XCTAssertEqual(CategoryGroup.of("hw"), .school)
        XCTAssertEqual(CategoryGroup.of("Stat 110", isLife: false), .learning)
        XCTAssertEqual(CategoryGroup.of("Laundry", isLife: true), .life)
    }
}
