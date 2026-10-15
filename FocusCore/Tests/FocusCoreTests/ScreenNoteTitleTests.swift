import XCTest
@testable import FocusCore

final class ScreenNoteTitleTests: XCTestCase {
    func testPromptLabelsCannotBecomeNoteTopics() {
        for bad in ["Category: Admin", "CATEGORY: Math", "Windows: Notes", "Notes so far", "Earlier notes for this block", "Admin"] {
            XCTAssertNil(ScreenNoteTitle.clean(bad, category: "Admin"), bad)
        }
        XCTAssertEqual(ScreenNoteTitle.resolve("Category: Admin", previous: "Category: Admin", windows: ["Focus settings"], category: "Admin"), "Focus settings")
    }
    func testValidTopicAndFallbackDoNotInventContent() {
        XCTAssertEqual(ScreenNoteTitle.clean("**Title: Partial orders**", category:"Math"), "Partial orders")
        XCTAssertEqual(ScreenNoteTitle.resolve("Category: Math", previous: nil, windows: [], category:"Math"), "Activity notes")
    }
}
