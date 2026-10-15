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
    func testPrivateOrUnobservableFocusNeverReusesOldRegularTab() {
        XCTAssertEqual(decide(id: -1), .incognito)
        XCTAssertEqual(decide(incognito: true), .incognito)
        XCTAssertEqual(BrowserWindowPrivacy.decide(report: nil, capturedTitle: "Article",
            windowChangedAt: at.addingTimeInterval(-10), capturedAt: at, nativeWindowMatches: true, isChrome: true), .unknown)
    }
}
