import XCTest
@testable import FocusCore

final class LearnedTitlePolicyTests: XCTestCase {
    func testRejectsActualLeakedLogTitleAndOtherNonTitles() {
        for title in ["2026-10-13 22:27:24.175 xcodebuild[36709:200932", "22:27:24.175 compiling Focus",
                      "[4/8] Compiling FocusCore", "warning: no such module", "$ swift test",
                      "func classify(title: String) {", "let category: String = \"Math\"",
                      "def classify(title):", "import Foundation", "#include <stdio.h>",
                      "if let title = window.title {", "xcodebuild -scheme Focus", "git diff --stat",
                      "first line\nsecond line", String(repeating: "x", count: 201), "  "] {
            XCTAssertNotNil(LearnedTitlePolicy.reason(title), title)
            XCTAssertNotNil(LearnedTitlePolicy.reason(title.lowercased()), "Lowercased learned key: \(title)")
        }
    }

    func testKeepsActualSubjectsAndProjectFileTitles() {
        for title in ["Plan MATH 244 midterm prep", "POSIX threads tutorial", "Understanding class inheritance",
                      "Introduction to probability", "Import substitution and development", "ScreenWatcher.swift",
                      "2026 midterm review", "Math 244 — Chapter 4: Partial orders", "Focus project settings",
                      "Why does let x = 3 work?", "git rebase explained", "Attention Is All You Need"] {
            XCTAssertNil(LearnedTitlePolicy.reason(title), title)
        }
    }
}
