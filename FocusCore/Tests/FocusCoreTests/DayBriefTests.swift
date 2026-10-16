import XCTest
@testable import FocusCore

final class DayBriefTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ h: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: h, minute: m))!
    }

    func testBriefCarriesFixesAndBlocksAndSurvivesCoding() throws {
        let tracked = [
            DayStory.Tracked(start: at(0, 0), end: at(8, 30), label: "Sleep", running: false),
            DayStory.Tracked(start: at(9, 30), end: at(10, 0), label: "Reading", running: true),
        ]
        let story = DayStory.build(day: at(12, 0), now: at(10, 0), tracked: tracked, record: nil, observations: [],
                                   focus: ["Math", "SWE"], calendar: calendar)
        let brief = DayBrief.make(day: at(12, 0), story: story, written: at(10, 0))
        XCTAssertEqual(brief.day, DayBrief.dayKey(at(12, 0)))
        XCTAssertTrue(brief.fixes.contains { $0.text.hasPrefix("Nothing logged") && $0.start == at(8, 30) })
        XCTAssertEqual(brief.blocks.first?.title, "Sleep")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(DayBrief.self, from: encoder.encode(brief)), brief)
    }
}
