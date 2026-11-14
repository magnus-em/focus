import XCTest
@testable import FocusCore

final class ScreenCourseTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_763_100_000)
    private var context: CoachCourse.Context { CoachCourse.Context() }

    private func resolve(_ category: String?, title: String, url: String? = nil, taught: String? = nil, cloud: String? = nil,
                         earlier: ScreenCourse.Reading? = nil, context: CoachCourse.Context? = nil) -> ScreenCourse.Reading? {
        ScreenCourse.resolve(category: category, title: title, url: url, at: at, taught: taught, cloud: cloud,
                             earlier: earlier, context: context ?? self.context)
    }

    func testYourAnswerBeatsEverything() {
        XCTAssertEqual(resolve("Math", title: "cpsc3231 notes.pdf", taught: "MATH 244", cloud: "CPSC 3231"),
                       .init(course: "MATH 244", basis: .you))
    }

    func testNotAClassMeansNone() {
        XCTAssertNil(resolve("Math", title: "MATH 244 pset 5", taught: ScreenCourse.notAClass))
    }

    func testCloudCourseIsCanonical() {
        XCTAssertEqual(resolve("SWE", title: "notes", cloud: "CPSC 323"), .init(course: "CPSC 3231", basis: .model))
    }

    func testCodeInTitleOrAddress() {
        XCTAssertEqual(resolve("Math", title: "Plan MAIH 244 miaterm prep"), .init(course: "MATH 244", basis: .title))
        XCTAssertEqual(resolve("SWE", title: "Lab 3", url: "https://canvas.yale.edu/courses/cpsc3231-lab3.pdf"),
                       .init(course: "CPSC 3231", basis: .title))
    }

    func testCalendarClassOnlyWhenTheSubjectFits() {
        let classes = [CoachCourse.ClassEvent(start: at.addingTimeInterval(-600), end: at.addingTimeInterval(3000), title: "MATH 244 Lecture")]
        let ctx = CoachCourse.Context(classes: classes)
        XCTAssertEqual(resolve("Math", title: "Lecture notes", context: ctx), .init(course: "MATH 244", basis: .calendar))
        XCTAssertNil(resolve("SWE", title: "terminal", context: ctx))
    }

    func testSameWindowEarlierLendsItsCourse() {
        XCTAssertEqual(resolve("AI", title: "Attention notebook", earlier: .init(course: "CPSC 7770", basis: .title)),
                       .init(course: "CPSC 7770", basis: .window))
    }

    /// AI is also your own projects (micrograd, the bigram notebook), so no
    /// course from the category alone.
    func testNoCourseFromCategoryAlone() {
        XCTAssertNil(resolve("AI", title: "language.ipynb — ml"))
        XCTAssertNil(resolve("SWE", title: "main.swift — focus"))
    }

    func testLifeAndInterviewPrepGetNoCourse() {
        XCTAssertNil(resolve("Leisure", title: "MATH 244 memes"))
        XCTAssertNil(resolve("LeetCode", title: "CPSC 3231 two sum", taught: "CPSC 3231"))
    }

    func testCourseCategoryAndName() {
        XCTAssertEqual(ScreenCourse.category(of: "MATH 244"), "Math")
        XCTAssertEqual(ScreenCourse.category(of: "CPSC 7770"), "AI")
        XCTAssertEqual(CoachCourse.name(of: "MATH 244"), "Discrete Math")
        XCTAssertNil(CoachCourse.name(of: "ECON 101"))
    }
}
