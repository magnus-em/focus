import XCTest
@testable import FocusCore

final class CoachChatTests: XCTestCase {
    private func record(_ day: String) -> CoachDay.Record {
        CoachDay.Record(day: day, content: .init(headline: "headline \(day)", timeline: [], study: [], questions: [],
                                                 other: [], planVsActual: nil, observations: []),
                        generatedAt: Date(), model: "grok-4.7", costUSD: 0, images: 0, promptVersion: 2)
    }

    func testPromptOrdersDaysAndTrimsHistory() {
        let history = (1...20).map { CoachChat.Turn(fromUser: $0 % 2 == 1, text: "turn \($0)") }
        let p = CoachChat.prompt(records: [record("2026-10-14"), record("2026-10-12")], today: "Day: Thursday",
                                 history: history, question: "What did I do?")
        XCTAssertLessThan(p.range(of: "## 2026-10-12")!.lowerBound, p.range(of: "## 2026-10-14")!.lowerBound)
        XCTAssertTrue(p.contains("\"headline\":\"headline 2026-10-14\""))
        XCTAssertFalse(p.contains("turn 8\n"))
        XCTAssertTrue(p.contains("Coach: turn 20"))
        XCTAssertTrue(p.hasSuffix("Student: What did I do?"))
    }

    func testEmptyPrompt() {
        let p = CoachChat.prompt(records: [], today: nil, history: [], question: "Hi")
        XCTAssertTrue(p.contains("(none yet)"))
        XCTAssertTrue(p.contains("(no evidence yet)"))
        XCTAssertTrue(p.contains("(new conversation)"))
    }
}
