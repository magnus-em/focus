import XCTest
@testable import FocusCore

final class DayStoryTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private let focus: Set<String> = ["Math", "SWE", "HW", "AI", "Quant"]
    private var day: Date { calendar.startOfDay(for: at(12, 0)) }
    private func at(_ h: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: h, minute: m))!
    }
    private func obs(_ h: Int, _ m: Int, tracked: String, screen: String?, topic: String, activity: String = "asking-ai",
                     concepts: [String] = [], course: String? = nil, questions: [String] = []) -> CoachEpisode.Record {
        let row = ScreenJournal.Row(at: at(h, m), end: at(h, m).addingTimeInterval(15), app: "ChatGPT", bundle: "com.openai.chat",
                                    windowID: "1:2", title: "t", url: nil, category: screen, trackedCategory: tracked,
                                    active: true, idleSeconds: 0, privacy: .notBrowser, evidenceImageID: nil, text: "x")
        let u = CoachEpisode.Understanding(topic: topic, course: course, activity: activity, concepts: concepts, summary: "",
                                           notes: [], askedByUser: questions, onScreenPrompts: ["Write the adjacency matrix of G."],
                                           transcription: nil, diagram: false,
                                           unreadable: false, struggle: nil, confidence: .high)
        return CoachEpisode.Record(source: row, understanding: u, model: "grok-4.3", usage: [], needsReview: false)
    }
    private func entry(_ a: String, _ b: String, _ c: String, _ w: String) -> CoachDay.Entry {
        CoachDay.Entry(start: a, end: b, category: c, what: w)
    }

    private var record: CoachDay.Record {
        let content = CoachDay.Content(
            headline: "MATH 244 midterm review, mostly asking ChatGPT.",
            timeline: [
                entry("00:00", "10:10", "Sleep", "Slept until late morning."),
                entry("10:08", "10:23", "Math", "Opened the MATH 244 review sheet: induction."),
                entry("10:23", "10:24", "Admin", "Focus app work."),
                entry("10:24", "10:57", "Math", "Relations and what composition gives."),
                entry("10:57", "11:27", "Math", "Partial orders and Hasse diagrams."),
                entry("11:51", "11:53", "Break", "Short break."),
                entry("11:53", "12:37", "Math", "Graph isomorphism."),
                entry("12:41", "12:43", "Admin", "Agent review."),
                entry("12:46", "12:55", "Math", "Derangements, then the binomial theorem."),
            ],
            study: [CoachDay.Study(course: "MATH 244", category: "Math", topics: ["induction", "relations"],
                                   digest: "Midterm review.", shaky: ["Why symmetry is one implication"])],
            questions: [], other: [], planVsActual: nil, observations: ["Mostly reading the chat."])
        return CoachDay.Record(day: "2026-10-15", content: content, generatedAt: at(13, 0), model: "grok-4.7",
                               costUSD: 0.05, images: 3, promptVersion: 3)
    }

    private var tracked: [DayStory.Tracked] {
        [.init(start: day, end: at(10, 10), label: "Sleep"),
         .init(start: at(10, 10), end: at(11, 51), label: "Math"),
         .init(start: at(11, 51), end: at(11, 53), label: "Break"),
         .init(start: at(11, 53), end: at(14, 10), label: "Math"),
         .init(start: at(14, 53), end: at(15, 35), label: "Chores", running: true)]
    }

    private func story() -> DayStory.Story {
        let observations = [
            obs(15, 26, tracked: "Chores", screen: "Admin", topic: "Coach.md onboarding", activity: "admin"),
            obs(15, 30, tracked: "Chores", screen: "Admin", topic: "Coach.md and Codex onboarding", activity: "admin"),
            obs(12, 30, tracked: "Math", screen: "Math", topic: "Before the record's cutoff"),
        ]
        return DayStory.build(day: day, now: at(15, 35), tracked: tracked, record: record, observations: observations,
                              events: [.init(start: at(13, 5), end: at(14, 20), title: "MATH 244 Midterm 1")],
                              screen: [.init(start: at(14, 53), end: at(15, 35), category: "Admin")],
                              focus: focus, calendar: calendar)
    }

    func testStudyOfOneCourseIsOneBlockWithItsSideTrips() {
        let s = story()
        XCTAssertEqual(s.headline, "MATH 244 midterm review, mostly asking ChatGPT.")
        XCTAssertEqual(s.headlineAsOf, at(13, 0))
        let morning = s.blocks.first { $0.start == at(10, 8) }
        XCTAssertEqual(morning?.course, "MATH 244")
        XCTAssertEqual(morning?.end, at(11, 27))
        XCTAssertEqual(morning?.moments.count, 3)
        XCTAssertEqual(morning?.interruptions.map(\.start), [at(10, 23)])
        XCTAssertTrue(morning?.study == true)
        XCTAssertTrue(s.blocks.first?.quiet == true, "sleep is one quiet line")
        XCTAssertFalse(s.blocks.contains { $0.moments.contains { $0.text == "Before the record's cutoff" } },
                       "observations the record already covers aren't repeated")
    }

    func testCalendarExamTrackedAsMathIsAFixToClass() {
        let s = story()
        let exam = s.blocks.first { $0.event == "MATH 244 Midterm 1" }
        XCTAssertEqual(exam?.start, at(13, 5))
        XCTAssertEqual(exam?.end, at(14, 10))
        XCTAssertEqual(exam?.fixes.first?.kind, .calendar(event: "MATH 244 Midterm 1"))
        XCTAssertEqual(exam?.fixes.first?.suggestion, "Class")
        XCTAssertEqual(s.fixes.first?.kind, .calendar(event: "MATH 244 Midterm 1"))
    }

    func testUntrackedGapAndScreenDisagreementOnTheRunningBlock() {
        let s = story()
        let gap = s.blocks.first { $0.category == nil }
        XCTAssertEqual(gap?.start, at(14, 10))
        XCTAssertEqual(gap?.end, at(14, 53))
        XCTAssertEqual(gap?.fixes.first?.kind, .untracked(seen: nil))
        let chores = s.blocks.last
        XCTAssertEqual(chores?.category, "Chores")
        XCTAssertTrue(chores?.running == true)
        XCTAssertEqual(chores?.moments.count, 1, "the admin observations are one moment")
        XCTAssertEqual(chores?.fixes.first?.kind, .screenDiffers(seen: "Admin"))
        XCTAssertEqual(chores?.fixes.first?.suggestion, "Admin")
        XCTAssertTrue(chores?.fixes.first?.running == true)
    }

    func testCourseSummaryTakesTheRecordsTopicsAndShakyPoints() {
        let c = story().courses.first
        XCTAssertEqual(c?.code, "MATH 244")
        XCTAssertEqual(c?.topics, ["induction", "relations"])
        XCTAssertEqual(c?.shaky, ["Why symmetry is one implication"])
        XCTAssertGreaterThan(c?.minutes ?? 0, 100)
    }

    func testObservationRunsMergeTopicVariantsAndKeepOwnQuestions() {
        let records = [
            obs(16, 50, tracked: "Math", screen: "Math", topic: "Binomial theorem induction and Pascal's identity",
                concepts: ["binomial theorem", "Pascal's identity"], course: "MATH 244", questions: ["What's Pascal's identity?"]),
            obs(16, 52, tracked: "Math", screen: "Math", topic: "Binomial theorem induction with Pascal's identity",
                concepts: ["Pascal's identity"], questions: ["what's pascal's identity?"]),
            obs(16, 53, tracked: "Math", screen: "Math", topic: "Binomial theorem induction and Pascal's identity",
                activity: "solving", concepts: ["binomial theorem"]),
            obs(16, 54, tracked: "Math", screen: "Admin", topic: "Review agent work", activity: "admin"),
        ]
        let runs = DayStory.runs(records, asked: { $0.understanding.askedByUser })
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].moment.text, "Binomial theorem induction and Pascal's identity")
        XCTAssertEqual(runs[0].moment.asked, ["What's Pascal's identity?"])
        XCTAssertEqual(runs[0].moment.activities.first, "asking-ai")
        XCTAssertEqual(runs[1].moment.activities, ["admin"])
    }

    func testTodayWithoutARecordUsesObservationsAndPracticeShare() {
        let records = [
            obs(10, 0, tracked: "Math", screen: "Math", topic: "Inclusion-exclusion", activity: "solving",
                concepts: ["inclusion-exclusion"], course: "MATH 244"),
            obs(10, 5, tracked: "Math", screen: "Math", topic: "Inclusion-exclusion", activity: "asking-ai",
                concepts: ["inclusion-exclusion"]),
            obs(10, 8, tracked: "Math", screen: "Math", topic: "Inclusion-exclusion", activity: "asking-ai",
                concepts: ["inclusion-exclusion"]),
        ]
        let s = DayStory.build(day: day, now: at(11, 0),
                               tracked: [.init(start: at(9, 58), end: at(11, 0), label: "Math", running: true)],
                               record: nil, observations: records, focus: focus, calendar: calendar)
        XCTAssertNil(s.headline)
        XCTAssertTrue(s.hasCoach)
        XCTAssertEqual(s.blocks.first?.course, "MATH 244")
        XCTAssertEqual(s.courses.first?.code, "MATH 244")
        XCTAssertEqual(s.courses.first?.practiceShare ?? 0, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertTrue(s.fixes.isEmpty)
    }

    func testAClassSkippedForStudyIsNoFixAndDuplicatesCollapse() {
        let tracked: [DayStory.Tracked] = [.init(start: at(10, 0), end: at(12, 0), label: "Math"),
                                           .init(start: at(10, 0), end: at(12, 0), label: "Math")]
        let events: [DayStory.CalendarEvent] = [.init(start: at(10, 30), end: at(11, 0), title: "AI Apps"),
                                                .init(start: at(11, 15), end: at(11, 45), title: "MATH 244 Midterm 1")]
        let s = DayStory.build(day: day, now: at(13, 0), tracked: tracked, record: nil, observations: [], events: events,
                               screen: [.init(start: at(10, 0), end: at(11, 10), category: "Math")],
                               focus: focus, calendar: calendar)
        XCTAssertEqual(s.fixes.map(\.kind), [.calendar(event: "MATH 244 Midterm 1")])
        XCTAssertNil(s.blocks.first { $0.event == "AI Apps" }, "an unflagged class doesn't split the story")
    }

    func testCourseNumbersFromTheNewCatalogMatchTheRecordsName() {
        XCTAssertEqual(DayStory.canonical("CPSC 3231", known: ["CPSC 323"]), "CPSC 323")
        XCTAssertEqual(DayStory.canonical("MATH 244", known: ["CPSC 323"]), "MATH 244")
    }

    /// 10/13: a vague five-hour SWE entry borrowed CPSC 3231 from a 13-minute
    /// one and the Week page showed 7h 51m of CPSC 3231; an hour of SWE chats
    /// that mentioned "planning MATH 244 prep" counted as MATH 244.
    func testLongVagueEntriesAndOtherSubjectsDontCountAsACourse() {
        let content = CoachDay.Content(
            headline: "Mostly SWE chats.",
            timeline: [
                entry("10:47", "11:00", "SWE", "ChatGPT on CPSC 3231 C basics: stdio, main, printf."),
                entry("11:01", "15:54", "SWE", "Long tracked SWE block, mostly ChatGPT. Specific problems were not on screen."),
                entry("15:55", "16:10", "SWE", "Back to ChatGPT under tracked SWE."),
                entry("18:53", "19:59", "SWE", "ChatGPT titles for reviewing C and planning MATH 244 prep."),
                entry("19:59", "20:10", "Math", "MATH 244 prep: minimal elements of a poset."),
            ],
            study: [], questions: [], other: [], planVsActual: nil, observations: [])
        let rec = CoachDay.Record(day: "2026-10-15", content: content, generatedAt: at(23, 59), model: "grok-4.7",
                                  costUSD: 0.05, images: 0, promptVersion: 4)
        let s = DayStory.build(day: day, now: at(23, 59), tracked: [.init(start: at(10, 30), end: at(20, 10), label: "SWE")],
                               record: rec, observations: [], focus: focus, calendar: calendar)
        XCTAssertEqual(s.courses.map(\.code), ["CPSC 3231", "MATH 244"])
        XCTAssertEqual(s.courses.first?.minutes, 13)
        XCTAssertEqual(s.courses.last?.minutes, 11)
        XCTAssertEqual(s.courses.last?.category, "Math")
    }

    func testAFixSpanningSeveralBlocksShowsOnTheOneItCoversMost() {
        let tracked: [DayStory.Tracked] = [.init(start: at(13, 0), end: at(13, 20), label: "Admin"),
                                           .init(start: at(13, 20), end: at(14, 30), label: "Leisure")]
        let events: [DayStory.CalendarEvent] = [.init(start: at(13, 5), end: at(14, 20), title: "MATH 244 Midterm 1")]
        let s = DayStory.build(day: day, now: at(15, 0), tracked: tracked, record: nil, observations: [], events: events,
                               focus: focus, calendar: calendar)
        XCTAssertEqual(s.fixes.count, 2)
        for f in s.fixes {
            XCTAssertEqual(s.blocks.filter { $0.fixes.contains(f) }.count, 1, "each fix sits on one row")
        }
    }

    func testTopicsThatDifferOnlyInAParentheticalAreOneRun() {
        XCTAssertEqual(DayStory.baseTopic("In-context learning as Bayesian inference (777 class)"),
                       "In-context learning as Bayesian inference")
        XCTAssertEqual(DayStory.baseTopic("(untitled)"), "(untitled)")
        let runs = DayStory.runs([obs(16, 6, tracked: "Class", screen: nil, topic: "In-context learning as Bayesian inference (777 class)"),
                                  obs(16, 7, tracked: "Class", screen: "AI", topic: "In-context learning as Bayesian inference (CPSC 7770)")],
                                 asked: { $0.understanding.askedByUser })
        XCTAssertEqual(runs.count, 1)
    }

    func testWeekMergesOneCourseNamedTwoWaysUnderTheLongerName() {
        func course(_ code: String, _ minutes: Double) -> DayStory.Course {
            DayStory.Course(code: code, category: "SWE", minutes: minutes, topics: [], shaky: [], digest: nil, activity: [:])
        }
        let names = DayStory.weekCourseNames([[course("CPSC 3231", 471)], [course("CPSC 323", 57), course("CPSC 171", 262)],
                                              [course("MATH 244", 448)]])
        XCTAssertEqual(names["CPSC 323"], "CPSC 3231")
        XCTAssertEqual(names["CPSC 3231"], "CPSC 3231")
        XCTAssertEqual(names["CPSC 171"], "CPSC 171", "a different number in the same subject stays its own course")
        XCTAssertEqual(names["MATH 244"], "MATH 244")
    }

    func testCoachOffFallsBackToTrackedSessionsAndNotes() {
        let s = DayStory.build(day: day, now: at(12, 0),
                               tracked: [.init(start: at(9, 0), end: at(10, 0), label: "SWE")],
                               record: nil, observations: [],
                               notes: [.init(start: at(9, 5), end: at(9, 50), title: "Two pointers")],
                               focus: focus, calendar: calendar)
        XCTAssertFalse(s.hasCoach)
        XCTAssertEqual(s.blocks.count, 1)
        XCTAssertEqual(s.blocks.first?.moments.first?.text, "Two pointers")
    }
}
