import XCTest
@testable import FocusCore

final class BrowserWindowPrivacyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private func decide(id: Int = 2, title: String = "Article", age: Double = 5, changedAge: Double = 10,
                        native: Bool = true, chrome: Bool = true, incognito: Bool = false) -> ScreenJournal.Privacy {
        BrowserWindowPrivacy.decide(report: .init(windowID: id, incognito: incognito, title: title, at: at.addingTimeInterval(-age)),
            capturedTitle: "Article - Google Chrome", windowChangedAt: at.addingTimeInterval(-changedAge),
            capturedAt: at, nativeWindowMatches: native, isChrome: chrome)
    }
    func testOnlyFreshNormalFocusBoundToNativeWindowAllowsCloud() {
        XCTAssertEqual(decide(), .regular)
        XCTAssertEqual(decide(age: 50), .unknown)
        XCTAssertEqual(decide(age: -1), .unknown)
        XCTAssertEqual(decide(changedAge: 1), .unknown)
        XCTAssertEqual(decide(native: false), .unknown)
        XCTAssertEqual(decide(chrome: false), .unknown)
        XCTAssertEqual(decide(title: "Other article"), .unknown)
        XCTAssertEqual(decide(title: ""), .unknown)
    }
    func testChromeAudioAndMiddleTruncationStillRequireFreshWindowBinding() {
        let report = BrowserWindowPrivacy.Report(windowID: 2, incognito: false, title: "Amazon.com: Countertop Ice Maker : Appliances", at: at.addingTimeInterval(-5))
        for title in ["Amazon.com: Countertop Ice Maker : Appliances 🔊", "Amazon.com: Countertop… : Appliances", "Amazon.com: Countertop… : Appliances 🔊 - Google Chrome"] {
            XCTAssertEqual(BrowserWindowPrivacy.decide(report: report, capturedTitle: title, windowChangedAt: at.addingTimeInterval(-10),
                capturedAt: at, nativeWindowMatches: true, isChrome: true), .regular)
            XCTAssertEqual(BrowserWindowPrivacy.decide(report: report, capturedTitle: title, windowChangedAt: at,
                capturedAt: at, nativeWindowMatches: true, isChrome: true), .unknown)
        }
        for title in ["…Appliances", "Amazon.com:…", "Wrong…Appliances"] {
            XCTAssertEqual(BrowserWindowPrivacy.decide(report: report, capturedTitle: title, windowChangedAt: at.addingTimeInterval(-10),
                capturedAt: at, nativeWindowMatches: true, isChrome: true), .unknown)
        }
    }

    func testPrivateOrUnobservableFocusNeverReusesOldRegularTab() {
        XCTAssertEqual(decide(id: -1), .incognito)
        XCTAssertEqual(decide(incognito: true), .incognito)
        XCTAssertEqual(BrowserWindowPrivacy.decide(report: nil, capturedTitle: "Article",
            windowChangedAt: at.addingTimeInterval(-10), capturedAt: at, nativeWindowMatches: true, isChrome: true), .unknown)
    }

    /// 11/14: full-screen YouTube. The window log blanked the title and the
    /// reading lost the video's address because only a plain prefix was checked.
    func testCutTitleWithSoundMarkIsTheSameTab() {
        let tab = "(713) The Most Successful Idea in Computer Science - YouTube"
        XCTAssertTrue(BrowserWindowPrivacy.sameTab(windowTitle: "(713) The Most Successful Ide…Computer Science - YouTube 🔊", tabTitle: tab))
        XCTAssertTrue(BrowserWindowPrivacy.sameTab(windowTitle: tab + " 🔊 - Google Chrome", tabTitle: tab))
        XCTAssertTrue(BrowserWindowPrivacy.sameTab(windowTitle: tab, tabTitle: tab))
        XCTAssertFalse(BrowserWindowPrivacy.sameTab(windowTitle: "(713) A PROGRAM is not a PROCESS. - YouTube 🔊", tabTitle: tab))
        XCTAssertFalse(BrowserWindowPrivacy.sameTab(windowTitle: "(713) The Most Successful Ide…Biology - YouTube 🔊", tabTitle: tab))
        XCTAssertFalse(BrowserWindowPrivacy.sameTab(windowTitle: "…Computer Science - YouTube", tabTitle: tab))
        XCTAssertFalse(BrowserWindowPrivacy.sameTab(windowTitle: "", tabTitle: tab))
    }
}
