import XCTest
@testable import FocusCore

final class StudyRecallTests: XCTestCase {
    private let focus: Set<String> = ["Quant", "SWE", "AI", "HW", "Math"]
    private let day = Date(timeIntervalSince1970: 1_792_000_000)

    private func block(_ startMin: Double, _ minutes: Double, screen: String?, tracked: String?, _ title: String,
                       bullets: [String] = [], windows: [String] = []) -> StudyRecall.Block {
        StudyRecall.Block(start: day.addingTimeInterval(startMin * 60), end: day.addingTimeInterval((startMin + minutes) * 60),
                          screenCategory: screen, trackedCategory: tracked, title: title, bullets: bullets, windowTitles: windows)
    }

    /// 10/14, abridged: the old cues were the spreadsheet, the murder case
    /// and "Category: Admin"; only the C review and Math prep should remain.
    private var october14: [StudyRecall.Block] {
        [
            block(0, 23.4, screen: "Admin", tracked: "Admin", "Corey Veverka's Spreadsheet"),
            block(30, 10.6, screen: "Leisure", tracked: "SWE", "Adderall overdose and study concerns"),
            block(60, 7.8, screen: "SWE", tracked: "SWE", "ChatGPT: Review C and systems midterm topics",
                  bullets: ["Today is the next day, and I have two and a half hours to review."]),
            block(68, 1.7, screen: "SWE", tracked: "SWE", "Category: HW"),
            block(90, 14.4, screen: "Leisure", tracked: "SWE", "Yale murder case"),
            block(110, 2.9, screen: "SWE", tracked: "SWE", "Review C and systems midterm topics",
                  bullets: ["Syscalls and files: Linux x86-64 uses RAX for the syscall number."],
                  windows: ["Google Chrome: 3231 Study Guides - Google Docs"]),
            block(125, 19.8, screen: "SWE", tracked: "SWE", "C and Systems Midterm Review",
                  bullets: ["PSET 01: Unix tools, echo, and C strings"],
                  windows: ["Preview: cpsc3231-midterm-cheat-sheet.pdf"]),
            block(150, 38.4, screen: "SWE", tracked: "Class", "Array Slicing",
                  bullets: ["Array slicing is a way to access a subset of an array."]),
            block(190, 10.2, screen: "SWE", tracked: "Class", "Segmentation Fault: An OS throws a segfault when we try"),
            block(260, 46.2, screen: "Admin", tracked: "Leisure", "Category: Admin"),
            block(400, 4.7, screen: "Math", tracked: "Math", "Math 244 Midterm Prep",
                  bullets: ["Let's resume Problem 2(a).", "A relation is a collection of ordered pairs."]),
            block(700, 11.8, screen: "Leisure", tracked: "Leisure", "Is Claude Conscious? Inside Anthropic's Models"),
            block(760, 1.9, screen: "Math", tracked: "Math", "Math Midterm 1 Review",
                  bullets: ["**Problem 7**:", "(a) A chain is a subset of a partially ordered set where every pair of elements is comparable.",
                            "(b) An independent set is a subset of a partially ordered set where no two elements are comparable."],
                  windows: ["Preview: midterm1_review.pdf", "Google Chrome: MATH 2440 01 (FA26): Discrete Mathematics"]),
        ]
    }

    func testOctober14KeepsOnlyStudyGroupedByCourse() {
        let groups = StudyRecall.groups(october14, focus: focus, coursePrefixes: ["3231": "CPSC", "2440": "MATH"])
        XCTAssertEqual(groups.map(\.category), ["SWE", "Math"])
        XCTAssertEqual(groups[0].courses, ["CPSC 3231"])
        XCTAssertEqual(groups[1].courses, ["MATH 244"])
        XCTAssertEqual(groups[0].topics, ["Array Slicing", "C and systems", "Segmentation Fault", "Syscalls and files"])
        XCTAssertEqual(groups[1].topics, ["Relation", "Chain", "Independent set"])
        let titles = groups.flatMap { $0.blocks.map { october14[$0].title } }
        for junk in ["Corey Veverka's Spreadsheet", "Yale murder case", "Category: Admin", "Is Claude Conscious? Inside Anthropic's Models",
                     "Adderall overdose and study concerns"] {
            XCTAssertFalse(titles.contains(junk), junk)
        }
    }

    func testStudyRules() {
        XCTAssertTrue(StudyRecall.isStudy(block(0, 5, screen: nil, tracked: "Math", "x"), focus: focus))
        XCTAssertTrue(StudyRecall.isStudy(block(0, 5, screen: "Reading", tracked: "SWE", "x"), focus: focus))
        XCTAssertTrue(StudyRecall.isStudy(block(0, 5, screen: "SWE", tracked: nil, "x"), focus: focus))
        XCTAssertFalse(StudyRecall.isStudy(block(0, 5, screen: "Admin", tracked: "SWE", "Focus app work"), focus: focus))
        XCTAssertFalse(StudyRecall.isStudy(block(0, 5, screen: "SWE", tracked: "Leisure", "x"), focus: focus))
        XCTAssertFalse(StudyRecall.isStudy(block(0, 5, screen: "Reading", tracked: nil, "x"), focus: focus))
    }

    func testCourseCodes() {
        XCTAssertEqual(StudyRecall.courseCodes(in: "Plan MATH 244 midterm prep"), ["MATH 244"])
        XCTAssertEqual(StudyRecall.courseCodes(in: "MATH 2440 01 (FA26): Discrete Mathematics"), ["MATH 244"])
        XCTAssertEqual(StudyRecall.courseCodes(in: "cpsc3231-midterm-cheat-sheet.pdf"), ["CPSC 3231"])
        XCTAssertEqual(StudyRecall.courseCodes(in: "Midterm in WLH 201 at 1:05"), [])
        XCTAssertEqual(StudyRecall.courseCodes(in: "3231 Study Guides", prefixes: ["3231": "CPSC"]), ["CPSC 3231"])
        XCTAssertEqual(StudyRecall.courseCodes(in: "Fall 2026, 3231 notes"), [])
    }

    func testTopicFromTitle() {
        XCTAssertNil(StudyRecall.topic(fromTitle: "Category: Admin"))
        XCTAssertNil(StudyRecall.topic(fromTitle: "Math 244 Midterm Prep", categories: ["Math"]))
        XCTAssertNil(StudyRecall.topic(fromTitle: "Midterm 1 logistics, etc."))
        XCTAssertEqual(StudyRecall.topic(fromTitle: "ChatGPT: Review C and systems midterm topics"), "C and systems")
        XCTAssertEqual(StudyRecall.topic(fromTitle: "Segmentation Fault: An OS throws a segfault"), "Segmentation Fault")
    }

    func testDisplayTitleReplacesEchoedPrompt() {
        XCTAssertEqual(StudyRecall.displayTitle("Category: Admin", fallback: "Amazon"), "Amazon")
        XCTAssertEqual(StudyRecall.displayTitle("Array Slicing", fallback: "Chrome"), "Array Slicing")
    }
}
