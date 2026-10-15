import XCTest
@testable import FocusCore

final class CoachDayTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ h: Int, _ m: Int, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    func testPromptClipsToTheDayAndKeepsEvidence() {
        let pack = CoachDay.Pack(
            day: at(12, 0),
            commitment: nil,
            sessions: [.init(start: at(23, 30, day: 13), end: at(0, 30), label: "Math"),
                       .init(start: at(12, 19), end: at(12, 39), label: "SWE")],
            blocks: [.init(start: at(12, 19), end: at(12, 39), screenCategory: "SWE", tracked: "SWE",
                           windows: [("ChatGPT: C and Systems Midterm Review", 19.8)],
                           bullets: ["PSET 01: Unix tools, echo, and C strings"])],
            imageLabels: ["12:32 Preview: cpsc3231-midterm-cheat-sheet.pdf"])
        let p = CoachDay.prompt(pack, calendar: calendar)
        XCTAssertTrue(p.contains("Day: Wednesday October 14, 2026"))
        XCTAssertTrue(p.contains("Tracked minutes by category: Math 30, SWE 20"))
        XCTAssertTrue(p.contains("- 00:00–00:30 Math (30 min)"))
        XCTAssertTrue(p.contains("windows: ChatGPT: C and Systems Midterm Review (20m)"))
        XCTAssertTrue(p.contains("  · PSET 01: Unix tools, echo, and C strings"))
        XCTAssertTrue(p.contains("Image 1: 12:32 Preview: cpsc3231-midterm-cheat-sheet.pdf"))
        XCTAssertTrue(p.contains("Morning commitment: (none)"))
    }

    func testSchemaIsStrictAndComplete() throws {
        let s = CoachDay.schema
        XCTAssertEqual(s["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(s["required"] as? [String] ?? []),
                       ["headline", "timeline", "study", "questions", "other", "planVsActual", "observations"])
        let q = try XCTUnwrap(((s["properties"] as? [String: Any])?["questions"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(Set(q["required"] as? [String] ?? []), ["course", "topic", "question", "answer", "source"])
    }

    func testContentDropsBlankQuestionsAndCaps() throws {
        let q = { (text: String) in
            ["course": "MATH 244", "topic": "posets", "question": text, "answer": "a", "source": "s"] as [String: Any]
        }
        let json: [String: Any] = [
            "headline": "h", "timeline": [], "study": [], "other": [], "planVsActual": NSNull(),
            "observations": ["1", "2", "3", "4", "5"],
            "questions": [q(" "), q("one"), q("two"), q("three"), q("four")],
        ]
        let c = try CoachDay.content(from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(c.questions.map(\.question), ["one", "two", "three"])
        XCTAssertEqual(c.observations.count, 4)
        XCTAssertNil(c.planVsActual)
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("days-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = CoachDay.Content(headline: "h", timeline: [], study: [], questions: [], other: [],
                                       planVsActual: nil, observations: [])
        let record = CoachDay.Record(day: CoachDay.dayKey(at(12, 0), calendar: calendar), content: content,
                                     generatedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "grok-4.7",
                                     costUSD: 0.075, images: 8, promptVersion: CoachDay.promptVersion)
        try CoachDay.save(record, to: dir)
        XCTAssertEqual(CoachDay.load(at(12, 0), from: dir, calendar: calendar), record)
        XCTAssertNil(CoachDay.load(at(12, 0, day: 15), from: dir, calendar: calendar))
    }

    func testObservationLinesMergeSameTopicRuns() {
        func rec(_ h: Int, _ m: Int, topic: String, concepts: [String], questions: [String] = [],
                 prompts: [String] = []) -> CoachEpisode.Record {
            let row = ScreenJournal.Row(at: at(h, m), end: at(h, m).addingTimeInterval(15), app: "ChatGPT",
                                        bundle: "com.openai.chat", windowID: "1:2", title: "Plan MATH 244 midterm prep",
                                        url: nil, category: "Math", trackedCategory: "Math", active: true, idleSeconds: 0,
                                        privacy: .notBrowser, evidenceImageID: nil, text: "x")
            let u = CoachEpisode.Understanding(topic: topic, course: "MATH 244", activity: "solving", concepts: concepts,
                                               summary: "Worked a problem.", notes: [], askedByUser: questions,
                                               onScreenPrompts: prompts,
                                               transcription: nil, diagram: false, unreadable: false, struggle: nil,
                                               confidence: .high)
            return CoachEpisode.Record(source: row, understanding: u, model: "grok-4.3", usage: [], needsReview: false)
        }
        let lines = CoachDay.observationLines([
            rec(12, 20, topic: "Inclusion–exclusion", concepts: ["empty boxes"], questions: ["Why (b) and not (c)?"]),
            rec(12, 24, topic: "Inclusion–exclusion", concepts: ["empty boxes", "signs"],
                prompts: ["15(b): distribute 12 balls into 5 boxes, none empty"]),
            rec(12, 50, topic: "Inclusion–exclusion", concepts: ["union bound"]),
            rec(12, 52, topic: "Union bound", concepts: ["complements"]),
        ], calendar: calendar)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("- 12:20–12:24 ChatGPT · MATH 244 · solving · Inclusion–exclusion"))
        XCTAssertTrue(lines[0].contains("concepts: empty boxes, signs"))
        XCTAssertTrue(lines[0].contains("you asked: Why (b) and not (c)?"))
        XCTAssertTrue(lines[0].contains("on screen: 15(b): distribute 12 balls into 5 boxes, none empty"))
        XCTAssertTrue(lines[2].contains("Union bound"))
    }

    /// 10/15: the record written at 1 PM saw the saved log end with a break at
    /// 11:51–11:53 and called the rest "untracked", while Math ran from 11:53.
    func testMidDayRecordIncludesTheRunningBlockClippedAtNow() {
        let saved: [CoachDay.Session] = [
            .init(start: at(0, 0, day: 15), end: at(10, 10, day: 15), label: "Sleep"),
            .init(start: at(10, 8, day: 15), end: at(11, 51, day: 15), label: "Math"),
            .init(start: at(11, 51, day: 15), end: at(11, 53, day: 15), label: "Break"),
        ]
        let running = CoachDay.Session(start: at(11, 53, day: 15), end: at(11, 53, day: 15), label: "Math")
        let sessions = CoachDay.trackedSessions(saved: saved, running: running, now: at(13, 0, day: 15))
        XCTAssertEqual(sessions.last, .init(start: at(11, 53, day: 15), end: at(13, 0, day: 15), label: "Math", running: true))
        XCTAssertEqual(sessions.count, 4)
        let pack = CoachDay.Pack(day: at(12, 0, day: 15), commitment: "MATH 244 midterm review", sessions: sessions,
                                 blocks: [], imageLabels: [], asOf: at(13, 0, day: 15))
        let p = CoachDay.prompt(pack, calendar: calendar)
        XCTAssertTrue(p.contains("- 11:53–13:00 Math (67 min, still running)"))
        XCTAssertTrue(p.contains("So far: evidence up to 13:00; the day isn't over."))
        XCTAssertTrue(p.contains("a timeline of the day so far"))
        XCTAssertTrue(p.contains("Tracked minutes by category: Sleep 610, Math 170, Break 2"))
        XCTAssertFalse(CoachDay.prompt(CoachDay.Pack(day: at(12, 0), commitment: nil, sessions: saved, blocks: [], imageLabels: []),
                                       calendar: calendar).contains("So far"))
    }

    func testRunningBlockWinsOverlapsAndNothingRunningChangesNothing() {
        let saved: [CoachDay.Session] = [
            .init(start: at(11, 40, day: 15), end: at(12, 0, day: 15), label: "Break"),
            .init(start: at(11, 53, day: 15), end: at(12, 30, day: 15), label: "Math"),
        ]
        let running = CoachDay.Session(start: at(11, 53, day: 15), end: at(11, 53, day: 15), label: "Math")
        XCTAssertEqual(CoachDay.trackedSessions(saved: saved, running: running, now: at(13, 0, day: 15)), [
            .init(start: at(11, 40, day: 15), end: at(11, 53, day: 15), label: "Break"),
            .init(start: at(11, 53, day: 15), end: at(13, 0, day: 15), label: "Math", running: true),
        ])
        XCTAssertEqual(CoachDay.trackedSessions(saved: saved.reversed(), running: nil, now: at(13, 0, day: 15)), saved)
        XCTAssertEqual(CoachDay.trackedSessions(saved: saved, running: .init(start: at(14, 0, day: 15), end: at(14, 0, day: 15),
                                                                             label: "Math"), now: at(13, 0, day: 15)), saved)
    }

    func testObservationLinesMarkInferredCourses() {
        let row = ScreenJournal.Row(at: at(12, 39), end: at(12, 39).addingTimeInterval(15), app: "Preview",
                                    bundle: "com.apple.Preview", windowID: "1", title: "midterm1_review.pdf", url: nil,
                                    category: "Math", trackedCategory: "Math", active: true, idleSeconds: 0,
                                    privacy: .notBrowser, evidenceImageID: nil, text: "x")
        let u = CoachEpisode.Understanding(topic: "Derangements", course: nil, activity: "reading", concepts: [], summary: "s",
                                           notes: [], askedByUser: [], onScreenPrompts: [], transcription: nil, diagram: false,
                                           unreadable: false, struggle: nil, confidence: .high)
        let r = CoachEpisode.Record(source: row, understanding: u, model: "grok-4.3", usage: [], needsReview: false)
        XCTAssertTrue(CoachDay.observationLines([r], calendar: calendar)[0].contains("· no course ·"))
        let inferred = [r.source.id: CoachCourse.Attribution(course: "MATH 244", basis: .neighbour)]
        XCTAssertTrue(CoachDay.observationLines([r], courses: inferred, calendar: calendar)[0].contains("· MATH 244 (inferred) ·"))
        let titled = [r.source.id: CoachCourse.Attribution(course: "MATH 244", basis: .title)]
        XCTAssertTrue(CoachDay.observationLines([r], courses: titled, calendar: calendar)[0].contains("· MATH 244 · reading"))
    }
}
