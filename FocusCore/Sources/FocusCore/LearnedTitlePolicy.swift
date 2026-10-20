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

    /// The part of a window title that names the page, without the unread counter
    /// and site/mailbox suffix ("Inbox (2,634) - me@yale.edu - Yale University Mail" → "inbox").
    /// 10/19: whole titles matched "magnus resume - …yale university mail" at 0.8+ on the shared
    /// suffix alone, so the inbox took that thread's SWE label.
    public static func subject(_ title: String) -> String {
        var t = title.lowercased().replacingOccurrences(of: #"^\(\d[\d,]*\+?\)\s*"#, with: "", options: .regularExpression)
        if let r = t.range(of: #"\s+[-|–—]\s+"#, options: .regularExpression) {
            let head = String(t[..<r.lowerBound])
            if head.count >= 4 { t = head }
        }
        return t.replacingOccurrences(of: #"\s*\(\d[\d,]*\+?\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

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
