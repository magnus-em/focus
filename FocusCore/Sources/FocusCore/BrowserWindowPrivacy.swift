import Foundation

public enum BrowserWindowPrivacy {
    public struct Report: Sendable {
        public let windowID: Int
        public let incognito: Bool
        public let title: String
        public let at: Date
        public init(windowID: Int, incognito: Bool, title: String, at: Date) {
            self.windowID = windowID; self.incognito = incognito; self.title = title; self.at = at
        }
    }
    public static func decide(report: Report?, capturedTitle: String, windowChangedAt: Date,
                              capturedAt: Date, nativeWindowMatches: Bool, isChrome: Bool) -> ScreenJournal.Privacy {
        guard isChrome, nativeWindowMatches, let report, report.at > windowChangedAt,
              capturedAt.timeIntervalSince(report.at) >= 0, capturedAt.timeIntervalSince(report.at) <= 45 else { return .unknown }
        if report.incognito || report.windowID == -1 { return .incognito }
        guard report.windowID >= 0, !report.title.isEmpty else { return .unknown }
        let suffix = " - Google Chrome"
        let normalized = capturedTitle.hasSuffix(suffix) ? String(capturedTitle.dropLast(suffix.count)) : capturedTitle
        return normalized == report.title ? .regular : .unknown
    }
}
