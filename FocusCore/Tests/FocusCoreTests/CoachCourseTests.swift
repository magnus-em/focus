import XCTest
@testable import FocusCore

/// Shaped like 10/15: a MATH 244 midterm review in ChatGPT and a review PDF,
/// with Focus-project chats in between, where the model named a course on 4
/// of 54 observations.
final class CoachCourseTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: h, minute: m, second: s))!
    }
    private func rec(_ h: Int, _ m: Int, _ s: Int = 0, app: String = "ChatGPT", bundle: String = "com.openai.codex",
                     title: String, url: String? = nil, screen: String? = "Math", tracked: String? = "Math",
                     activity: String = "asking-ai", topic: String = "t", course: String? = nil) -> CoachEpisode.Record {
        let row = ScreenJournal.Row(at: at(h, m, s), end: at(h, m, s).addingTimeInterval(15), app: app, bundle: bundle,
                                    windowID: "1", title: title, url: url, category: screen, trackedCategory: tracked,
                                    active: true, idleSeconds: 0, privacy: url == nil ? .notBrowser : .regular,
                                    evidenceImageID: nil, text: "x")
        let u = CoachEpisode.Understanding(topic: topic, course: course, activity: activity, concepts: [], summary: "s",
                                           notes: [], askedByUser: [], onScreenPrompts: [], transcription: nil,
                                           diagram: false, unreadable: false, struggle: nil, confidence: .high)
        let record = CoachEpisode.Record(source: row, understanding: u, model: "grok-4.3", usage: [], needsReview: false)
        // Rows from before enforceDepth (an Admin chat with "CPSC 323") are still on disk; decode one as stored.
        guard course != nil, screen == "Admin" else { return record }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        var json = try! JSONSerialization.jsonObject(with: e.encode(record)) as! [String: Any]
        var understanding = json["understanding"] as! [String: Any]
        understanding["course"] = course
        json["understanding"] = understanding
        return try! d.decode(CoachEpisode.Record.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testCodesAreCanonicalToTheSemestersCourses() {
        let context = CoachCourse.Context()
        XCTAssertEqual(CoachCourse.codes(in: "Plan MAIH 244 miaterm prep", context: context), ["MATH 244"])
        XCTAssertEqual(CoachCourse.codes(in: "MATH 2440 Discrete Mathematics", context: context), ["MATH 244"])
        XCTAssertEqual(CoachCourse.codes(in: "cpsc3231-midterm-cheat-sheet.pdf", context: context), ["CPSC 3231"])
        XCTAssertEqual(CoachCourse.codes(in: "CPSC 323 exam topics", context: context), ["CPSC 3231"])
        XCTAssertEqual(CoachCourse.codes(in: "3231 Study Guides", context: context), ["CPSC 3231"])
        XCTAssertEqual(CoachCourse.codes(in: "CPSC 171 slides", context: context), ["CPSC 1710"])
        XCTAssertEqual(CoachCourse.codes(in: "ECON 1150 problem set", context: context), ["ECON 1150"])
        XCTAssertEqual(CoachCourse.codes(in: "midterm1_review.pdf", context: context), [])
        XCTAssertEqual(CoachCourse.codes(in: "page 244 of 300", context: context), [])
        XCTAssertEqual(CoachCourse.codes(in: "PAGE 244", context: context), [])
        let calendar = CoachCourse.Context(coursePrefixes: ["2440": "MATH", "4770": "CPSC"])
        XCTAssertEqual(CoachCourse.codes(in: "4770 lecture notes", context: calendar), ["CPSC 4770"])
        XCTAssertEqual(CoachCourse.codes(in: "777 class", context: calendar), [])
        XCTAssertEqual(calendar.courses.map(\.code), ["CPSC 3231", "MATH 244", "CPSC 1710", "CPSC 4770"])
    }

    func testStudyObservationsGetACourseFromTheBestEvidence() {
        let review = [
            rec(12, 23, title: "Plan MAIH 244 miaterm prep", activity: "solving", course: "MATH 244"),
            rec(12, 38, title: "It has 5 vertices, 6 edges, and degrees", course: "MATH 244"),
            rec(12, 39, app: "Preview", bundle: "com.apple.Preview", title: "midterm1_review.pdf", activity: "reading"),
            rec(12, 41, title: "keview agent work ana plan next", screen: "Admin", activity: "admin"),
            rec(12, 46, title: "Explain Two Problems"),
            rec(12, 50, 36, title: "Explain binomial theorem induction"),
            rec(12, 55, 18, title: "Explain binomial theorem induction"),
            rec(13, 2, title: "Plan MATH 244 midterm prep", activity: "solving"),
            rec(15, 26, title: "Explain binomial theorem induction", tracked: "Chores"),
            rec(17, 43, app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Focus Screens Rethink",
                screen: "Admin", tracked: "Commute", activity: "admin", course: "CPSC 323"),
        ]
        let courses = CoachCourse.attribute(review, context: CoachCourse.Context())
        func basis(_ i: Int) -> CoachCourse.Basis? { courses[review[i].source.id]?.basis }
        XCTAssertEqual(review.map { courses[$0.source.id]?.course }, [
            "MATH 244", "MATH 244", "MATH 244", nil, "MATH 244", "MATH 244", "MATH 244", "MATH 244", "MATH 244", nil,
        ])
        XCTAssertEqual(basis(0), .model)
        XCTAssertEqual(basis(2), .neighbour)
        XCTAssertEqual(basis(4), .neighbour)
        XCTAssertEqual(basis(7), .title)
        XCTAssertEqual(basis(8), .category)
        let resolve = CoachCourse.resolver(review, context: CoachCourse.Context())
        XCTAssertEqual(resolve(review[2]), "MATH 244")
        XCTAssertEqual(CoachCourse.course(for: review[2], neighbours: review, context: CoachCourse.Context()), "MATH 244")
        XCTAssertNil(CoachCourse.course(for: review[2], neighbours: [], context: CoachCourse.Context()))
    }

    func testSameChatWindowCarriesItsCourseAcrossTheDay() {
        let day = [
            rec(10, 10, title: "Plan MATH 244 midterm prep", activity: "solving"),
            rec(15, 0, title: "Plan MATH 244 midterm prep", screen: "SWE", tracked: "SWE", course: "CPSC 3231"),
            rec(16, 0, title: "Explain binomial theorem induction", course: "MATH 244"),
            rec(19, 0, title: "Explain binomial theorem induction", screen: "Reading", tracked: "Reading"),
        ]
        let courses = CoachCourse.attribute(day, context: CoachCourse.Context())
        XCTAssertEqual(courses[day[3].source.id], .init(course: "MATH 244", basis: .window))
        XCTAssertEqual(courses[day[1].source.id], .init(course: "CPSC 3231", basis: .model))
    }

    func testCalendarClassesNameTheCourseInClass() {
        let lecture = CoachCourse.ClassEvent(start: at(16, 0), end: at(17, 15), title: "CPSC 1710 AI Applications")
        let context = CoachCourse.Context(classes: [lecture])
        let inClass = rec(16, 6, title: "Context Learning Bayesian Inference", screen: "AI", tracked: "Class")
        let mathInClass = rec(16, 10, title: "Some proof", screen: "Math", tracked: "Math")
        let after = rec(18, 0, title: "Another chat", screen: "AI", tracked: "AI")
        let courses = CoachCourse.attribute([inClass, mathInClass, after], context: context)
        XCTAssertEqual(courses[inClass.source.id], .init(course: "CPSC 1710", basis: .calendar))
        XCTAssertNil(courses[mathInClass.source.id])
        XCTAssertEqual(courses[after.source.id], .init(course: "CPSC 1710", basis: .category))
    }

    func testCategoryOnlyWhenOneCourseFitsAndItWasSeen() {
        let sheet = rec(9, 0, app: "Preview", bundle: "com.apple.Preview", title: "cpsc3231-midterm-cheat-sheet.pdf",
                        screen: "SWE", tracked: "SWE", activity: "reading")
        let pointers = rec(14, 0, title: "C pointers and arrays", screen: "SWE", tracked: "SWE", activity: "coding")
        let leetcode = rec(9, 5, app: "Google Chrome", bundle: "com.google.Chrome", title: "Two Sum - LeetCode",
                           url: "https://leetcode.com/problems/two-sum/", screen: "SWE", tracked: "SWE", activity: "coding")
        var courses = CoachCourse.attribute([sheet, pointers, leetcode], context: CoachCourse.Context())
        XCTAssertEqual(courses[sheet.source.id], .init(course: "CPSC 3231", basis: .title))
        XCTAssertEqual(courses[pointers.source.id], .init(course: "CPSC 3231", basis: .category))
        XCTAssertNil(courses[leetcode.source.id])
        XCTAssertNil(CoachCourse.attribute([pointers], context: CoachCourse.Context())[pointers.source.id])
        // A second SWE course on the calendar makes the category ambiguous.
        courses = CoachCourse.attribute([sheet, pointers], context: CoachCourse.Context(coursePrefixes: ["4770": "CPSC"]))
        XCTAssertNil(courses[pointers.source.id])
    }

    func testStretchesFromObservationsTitlesCalendarOrCategory() {
        let day = [
            rec(10, 20, title: "Plan MATH 244 midterm prep", activity: "solving"),
            rec(10, 30, app: "Preview", bundle: "com.apple.Preview", title: "midterm1_review.pdf", activity: "reading"),
        ]
        let exam = CoachCourse.ClassEvent(start: at(13, 5), end: at(14, 20), title: "MATH 244 Midterm 1")
        let context = CoachCourse.Context(classes: [exam])
        XCTAssertEqual(CoachCourse.stretch(start: at(10, 8), end: at(11, 51), category: "Math", records: day, context: context),
                       .init(course: "MATH 244", basis: .title))
        XCTAssertEqual(CoachCourse.stretch(start: at(11, 53), end: at(13, 0), category: "Math", records: day, context: context),
                       .init(course: "MATH 244", basis: .category))
        XCTAssertEqual(CoachCourse.stretch(start: at(13, 0), end: at(14, 20), category: "Class", records: day, context: context),
                       .init(course: "MATH 244", basis: .calendar))
        XCTAssertEqual(CoachCourse.stretch(start: at(15, 0), end: at(16, 0), category: "SWE",
                                           titles: ["Preview: cpsc3231-midterm-cheat-sheet.pdf"], records: day, context: context),
                       .init(course: "CPSC 3231", basis: .title))
        XCTAssertNil(CoachCourse.stretch(start: at(15, 0), end: at(16, 0), category: "SWE", records: day, context: context))
        XCTAssertNil(CoachCourse.stretch(start: at(15, 0), end: at(16, 0), category: "Math", records: [], context: context))
    }
}
