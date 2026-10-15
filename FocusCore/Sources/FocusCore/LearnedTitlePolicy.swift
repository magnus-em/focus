import Foundation

public enum LearnedTitlePolicy {
    private static let patterns: [(String, String)] = [
        (#"^\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}"#, "Starts with a log timestamp"),
        (#"^\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?\s+"#, "Starts with a log timestamp"),
        (#"(?i)\b(?:xcodebuild|swiftc|swift-frontend|clang|Focus)\[\d+(?::\d+)?\]"#, "Looks like process log output"),
        (#"(?i)^\[(?:\d+/\d+|INFO|DEBUG|ERROR|WARN|TRACE)\]"#, "Looks like build or log output"),
        (#"^(?:error|warning|fatal error):\s"#, "Looks like a compiler message"),
        (#"^(?:\$|%)\s+\S"#, "Looks like a terminal command"),
        (#"^(?:public\s+|private\s+|final\s+|static\s+)*(?:func|struct|enum|class|extension|protocol)\s+\w+.*[\{(]"#, "Looks like a line of code"),
        (#"^(?:let|var|const)\s+\w+\s*(?::[^=]+)?="#, "Looks like a variable assignment"),
        (#"^(?:async\s+)?def\s+\w+\s*\(.*\)\s*:"#, "Looks like a line of code"),
        (#"(?i)^(?:import\s+(?:Foundation|SwiftUI|AppKit|UIKit|SwiftData|FocusCore|Combine|HealthKit|AVFoundation|CoreGraphics|Vision|FoundationModels)|#include\s+[<\"].+[>\"])$"#, "Looks like an import statement"),
        (#"^(?:if|for|while|guard|switch)\s+.+[{};]"#, "Looks like a line of code"),
        (#"^(?:xcodebuild|swiftc|swift-frontend|clang|git|npm|python3?)\s+(?:-{1,2}[\w-]|\S.*\s-{1,2}[\w-])"#, "Looks like a terminal command")
    ]

    public static func reason(_ title: String) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Has no window title" }
        if title.count > 200 { return "Too long to be a stable window title" }
        if title.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1 {
            return "Contains several lines of text"
        }
        for (pattern, reason) in patterns where title.range(of: pattern, options: .regularExpression) != nil {
            return reason
        }
        return nil
    }
}
