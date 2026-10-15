import Foundation

/// "Last time on MATH 244 (12:52): inclusion–exclusion; you asked why (b)
/// needs it." The latest observation tracked under the running category that
/// ended at least 20 minutes ago, so coming back to a subject starts from where
/// it was left. Only the topic and the user's own questions or struggle are
/// shown, never anything the model inferred about them.
public enum WhereWasI {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// A confirmed non-private https address to reopen, if the source had one.
        public var url: URL?
        public var bundle: String

        public init(text: String, url: URL?, bundle: String) {
            self.text = text
            self.url = url
            self.bundle = bundle
        }
    }

    public static func line(_ episodes: [CoachEpisode.Record], running: String, now: Date,
                            calendar: Calendar = .current) -> Line? {
        let latest = episodes
            .filter { $0.source.trackedCategory == running && $0.understanding.activity != "admin"
                && ($0.source.privacy == .notBrowser || $0.source.privacy == .regular) }
            .max { $0.source.end < $1.source.end }
        guard let e = latest, now.timeIntervalSince(e.source.end) >= 20 * 60,
              now.timeIntervalSince(e.source.end) < 7 * 86400 else { return nil }
        let u = e.understanding
        let clock = DateFormatter()
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.dateFormat = calendar.isDate(e.source.end, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        var text = "Last time on \(u.course ?? running) (\(clock.string(from: e.source.end))): \(u.topic)"
        if let q = u.questions.first, !q.isEmpty {
            text += "; you asked: \(q)"
        } else if let s = u.struggle, !s.isEmpty {
            text += "; stuck on: \(s)"
        }
        let url = e.source.privacy == .regular ? e.source.url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } : nil
        return Line(text: text, url: url, bundle: e.source.bundle)
    }
}
