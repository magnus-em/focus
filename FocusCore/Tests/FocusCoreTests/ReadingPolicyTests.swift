import XCTest
@testable import FocusCore

final class ReadingPolicyTests: XCTestCase {
    func testEducationalLongFormStaysReading() {
        for (title, text) in [("Understanding entropy — an explainer", ""),
                              ("Chapter 2", "This book explains the history of science."),
                              ("Swift documentation", "Learn how actors work."),
                              ("An essay on philosophy", ""),
                              ("Research paper", "We study the evidence.")] {
            XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Preview", title: title, text: text).category, "Reading", title)
        }
    }

    func testNewsFeedsShoppingAndForumsAreNotReading() {
        for title in ["Breaking news — latest headlines", "Home • Threads", "Shopping cart — Amazon.com",
                      "Hacker News", "r/popular", "What's happening | Reddit", "Forum: latest topics"] {
            XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: title, text: "").category, "Leisure", title)
        }
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: "Bill payment", text: "").category, "Admin")
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: "Facebook account settings", text: "").category, "Admin")
    }

    func testOldReadingLabelsNeedFreshEvidenceWhenPageIsClearlyBrowsing() {
        for source in [ScreenClassificationPolicy.Source.learned, .held] {
            let result = ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: "Breaking news", text: "", source: source)
            XCTAssertNil(result.category)
            XCTAssertTrue(result.uncertain)
        }
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "SWE", app: "Chrome", title: "Forum: latest topics", text: "", source: .learned).category, "SWE")
    }

    func testCasualChatIsNotAutomaticallyReading() {
        let result = ScreenClassificationPolicy.evaluate(category: "Reading", app: "ChatGPT", title: "Dinner plans", text: "What should we eat tonight?")
        XCTAssertNil(result.category)
        XCTAssertTrue(result.uncertain)
    }
}
