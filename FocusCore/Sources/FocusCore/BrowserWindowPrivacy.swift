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
        guard report.windowID >= 0 else { return .unknown }
        return sameTab(windowTitle: capturedTitle, tabTitle: report.title) ? .regular : .unknown
    }

    /// Whether Chrome's window title shows this tab title. The window title
    /// can end in " - Google Chrome" or a sound/playback mark, and Chrome
    /// cuts a long one in the middle, more so with 🔊 after it ("(713) The
    /// Most Successful Ide…Computer Science - YouTube 🔊"); both ends of a
    /// cut title must match.
    public static func sameTab(windowTitle: String, tabTitle: String) -> Bool {
        guard !tabTitle.isEmpty else { return false }
        let suffix = " - Google Chrome"
        var w = windowTitle.trimmingCharacters(in: .whitespaces)
        if w.hasSuffix(suffix) { w = String(w.dropLast(suffix.count)) }
        for indicator in [" 🔊", " 🔇", " ▶️", " ⏸️", " ▶", " ⏸"] where w.hasSuffix(indicator) {
            w = String(w.dropLast(indicator.count))
        }
        if w == tabTitle { return true }
        guard let ellipsis = w.range(of: "…") else { return false }
        let prefix = String(w[..<ellipsis.lowerBound]), end = String(w[ellipsis.upperBound...])
        return !prefix.isEmpty && !end.isEmpty && tabTitle.hasPrefix(prefix) && tabTitle.hasSuffix(end)
    }
}
