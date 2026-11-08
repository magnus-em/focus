import XCTest
@testable import FocusCore

final class YouTubeFeedTests: XCTestCase {
    func video(_ title: String, _ channel: String) -> YouTubeFeed.Video { .init(id: "x", title: title, channel: channel) }

    func testChannelKeyIgnoresCaseAndPunctuation() {
        XCTAssertEqual(YouTubeFeed.channelKey("@3Blue1Brown"), "3blue1brown")
        XCTAssertEqual(YouTubeFeed.channelKey("Kurzgesagt – In a Nutshell"), YouTubeFeed.channelKey("kurzgesagt in a nutshell"))
    }

    func testYourChannelRuleWinsOverEverything() {
        let rules = [YouTubeFeed.channelKey("Veritasium"): false, YouTubeFeed.channelKey("MrBeast"): true]
        XCTAssertEqual(YouTubeFeed.quick(video("The Surprising Physics of Ice", "Veritasium"), rules: rules), .init(keep: false, source: .you))
        XCTAssertEqual(YouTubeFeed.quick(video("Reaction to my reaction", "MrBeast"), rules: rules), .init(keep: true, source: .you))
    }

    func testKnownChannelsKeepButTitleMarksHide() {
        XCTAssertEqual(YouTubeFeed.quick(video("Let's build GPT: from scratch", "Andrej Karpathy"), rules: [:]), .init(keep: true, source: .known))
        XCTAssertEqual(YouTubeFeed.quick(video("Trailer: new series #shorts", "3Blue1Brown"), rules: [:])?.keep, false)
        XCTAssertNil(YouTubeFeed.quick(video("What is a manifold?", "Some Channel"), rules: [:]))
    }

    func testFallbackNeedsAnEducationalMark() {
        XCTAssertTrue(YouTubeFeed.fallback(video("Linear Algebra Lecture 3", "Prof X")).keep)
        XCTAssertFalse(YouTubeFeed.fallback(video("I spent 50 hours in a cave", "Someone")).keep)
    }

    func testPromptNumbersEveryVideoInOrder() {
        let p = YouTubeFeed.prompt([video("A", "c1"), video("B", "c2")])
        XCTAssertEqual(p, "v1: \"A\" by c1\nv2: \"B\" by c2")
    }

    func testEducationalTitleMarks() {
        XCTAssertTrue(YouTubeFeed.soundsEducational("Karpathy Bigram explained in 10min"))
        XCTAssertTrue(YouTubeFeed.soundsEducational("Linear Algebra Crash Course"))
        XCTAssertFalse(YouTubeFeed.soundsEducational("Of course I cheated"))
        XCTAssertFalse(YouTubeFeed.soundsEducational("Vector VS Thanos"))
    }
}
