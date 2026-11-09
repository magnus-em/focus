import XCTest
@testable import FocusCore

final class YouTubeFeedTests: XCTestCase {
    func video(_ title: String, _ channel: String) -> YouTubeFeed.Video { .init(id: "x", title: title, channel: channel) }

    func testChannelKeyIgnoresCaseAndPunctuation() {
        XCTAssertEqual(YouTubeFeed.channelKey("@3Blue1Brown"), "3blue1brown")
        XCTAssertEqual(YouTubeFeed.channelKey("Kurzgesagt – In a Nutshell"), YouTubeFeed.channelKey("kurzgesagt in a nutshell"))
    }

    func testYourChannelRuleWinsOverEverything() {
        let rules = [YouTubeFeed.channelKey("Veritasium"): false, YouTubeFeed.channelKey("CNN"): true]
        XCTAssertEqual(YouTubeFeed.quick(video("The Surprising Physics of Ice", "Veritasium"), rules: rules), .init(keep: false, source: .you))
        XCTAssertEqual(YouTubeFeed.quick(video("Trump reacts to the election", "CNN"), rules: rules), .init(keep: true, source: .you))
    }

    func testKnownChannelsKeepButTitleMarksHide() {
        XCTAssertEqual(YouTubeFeed.quick(video("Let's build GPT: from scratch", "Andrej Karpathy"), rules: [:]), .init(keep: true, source: .known))
        XCTAssertEqual(YouTubeFeed.quick(video("Trailer: new series #shorts", "3Blue1Brown"), rules: [:])?.keep, false)
        XCTAssertNil(YouTubeFeed.quick(video("What is a manifold?", "Some Channel"), rules: [:]))
    }

    func testPoliticsAndNewsHideWithTheirReason() {
        XCTAssertEqual(YouTubeFeed.quick(video("Extended Interview: President Trump on 60 Minutes", "60 Minutes"), rules: [:]),
                       .init(keep: false, source: .title, why: "politics"))
        XCTAssertEqual(YouTubeFeed.quick(video("Inside the Fed's rate decision", "CNBC Television"), rules: [:]),
                       .init(keep: false, source: .known, why: "news"))
        XCTAssertEqual(YouTubeFeed.quick(video("Bubu Mobile - SNL", "Saturday Night Liveand Druski"), rules: [:])?.why, "comedy")
    }

    func testMarksMatchWholeWords() {
        XCTAssertNil(YouTubeFeed.quick(video("Trumpet scales for beginners", "Music Lessons"), rules: [:]))
        XCTAssertNil(YouTubeFeed.quick(video("Troubleshooting a flaky CI pipeline", "Dev"), rules: [:]))
        XCTAssertEqual(YouTubeFeed.quick(video("Why Republicans lost", "Pundit"), rules: [:])?.why, "politics")
    }

    func testCollaborationsMatchTheFirstChannel() {
        XCTAssertEqual(YouTubeFeed.quick(video("The future of intelligence", "Google DeepMindand Hannah Fry"), rules: [:])?.keep, true)
        XCTAssertNil(YouTubeFeed.quick(video("MITMISCHEN INVITES - DBBD", "MITMISCHEN"), rules: [:]))
    }

    func testFallbackNeedsAMarkOfSomethingWorthwhile() {
        XCTAssertTrue(YouTubeFeed.fallback(video("Linear Algebra Lecture 3", "Prof X")).keep)
        XCTAssertTrue(YouTubeFeed.fallback(video("3 hours deep focus music for coding", "Lofi")).keep)
        XCTAssertFalse(YouTubeFeed.fallback(video("I spent 50 hours in a cave", "Someone")).keep)
    }

    func testDecideHidesPoliticsInAnyFormAndKeepsGoodKinds() {
        XCTAssertEqual(YouTubeFeed.decide(kind: "talk, interview or podcast", topic: "politics or war", title: "x").why, "politics")
        XCTAssertEqual(YouTubeFeed.decide(kind: "gaming", topic: "programming or AI", title: "x").why, "gaming")
        XCTAssertTrue(YouTubeFeed.decide(kind: "lecture or course", topic: "other", title: "x").keep)
        XCTAssertTrue(YouTubeFeed.decide(kind: "other", topic: "health, fitness or food", title: "x").keep)
        XCTAssertFalse(YouTubeFeed.decide(kind: "other", topic: "other", title: "x").keep)
        XCTAssertFalse(YouTubeFeed.decide(kind: "other", topic: "entertainment", title: "x").keep)
    }

    func testFocusMusicNeedsAMusicWordInTheTitle() {
        XCTAssertTrue(YouTubeFeed.decide(kind: "focus, study or sleep music", topic: "other", title: "2 hour pomodoro playlist").keep)
        XCTAssertFalse(YouTubeFeed.decide(kind: "focus, study or sleep music", topic: "other", title: "Biscuit has the hiccups").keep)
    }

    func testCloudAnswersKeepTheirOrderAndReason() throws {
        let json = Data(#"{"v1":{"keep":true,"why":"learning"},"v2":{"keep":false,"why":" Politics "},"v3":{"oops":1}}"#.utf8)
        let out = try XCTUnwrap(YouTubeFeed.parseCloud(json, count: 3))
        XCTAssertEqual(out[0], .init(keep: true, source: .cloud))
        XCTAssertEqual(out[1], .init(keep: false, source: .cloud, why: "politics"))
        XCTAssertNil(out[2])
        XCTAssertNil(YouTubeFeed.parseCloud(Data("{}".utf8), count: 2))
        let schema = YouTubeFeed.cloudSchema(count: 2)
        XCTAssertEqual(schema["required"] as? [String], ["v1", "v2"])
    }

    func testCloudPromptNumbersEveryVideoInOrder() {
        XCTAssertEqual(YouTubeFeed.cloudPrompt([video("A", "c1"), video("B", "c2")]), "v1: \"A\" by c1\nv2: \"B\" by c2")
    }
}
