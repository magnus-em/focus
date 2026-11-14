import Foundation

/// The course a single screen reading belongs to, decided when the window is
/// read. Only evidence about this window counts: your answer for it, the
/// cloud reading's course, a course code in the title or address, the
/// calendar class on now (when the reading's subject fits it), or the same
/// window earlier with one of those. No guess from the category alone: AI
/// is also your own deep-learning projects, not only CPSC 7770, and SWE is
/// not only CPSC 3231, so a reading without evidence shows no course and you
/// can name it.
public enum ScreenCourse {
    public enum Basis: String, Codable, Sendable {
        case you, model, title, calendar, window
    }

    public struct Reading: Equatable, Sendable {
        public var course: String
        public var basis: Basis

        public init(course: String, basis: Basis) {
            self.course = course
            self.basis = basis
        }
    }

    /// Your answer for a window that isn't any class.
    public static let notAClass = ""

    /// - Parameters:
    ///   - taught: your answer for this window (`notAClass` = none of them).
    ///   - cloud: the course the cloud reading of this window named, if any.
    ///   - earlier: what this window got from direct evidence earlier today.
    public static func resolve(category: String?, title: String, url: String?, at: Date,
                               taught: String?, cloud: String?, earlier: Reading?,
                               context: CoachCourse.Context) -> Reading? {
        if let category, !CoachCourse.studyCategories.contains(category) { return nil }
        if let taught { return taught == notAClass ? nil : Reading(course: taught, basis: .you) }
        if let raw = cloud?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Reading(course: CoachCourse.codes(in: raw, context: context).first ?? raw, basis: .model)
        }
        let path = url.flatMap { URL(string: $0)?.path.removingPercentEncoding }
        if let code = ([title] + (path.map { [$0] } ?? [])).lazy
            .compactMap({ CoachCourse.codes(in: $0, context: context).first }).first {
            return Reading(course: code, basis: .title)
        }
        for c in context.classes where c.start <= at && c.end > at {
            guard let code = CoachCourse.enrolledCourse(forCalendarTitle: c.title)?.code
                    ?? CoachCourse.codes(in: c.title, context: context).first else { continue }
            if category == nil || category == "Class" || CoachCourse.category(of: code, context: context) == category {
                return Reading(course: code, basis: .calendar)
            }
        }
        if let earlier { return Reading(course: earlier.course, basis: .window) }
        return nil
    }

    /// The category a course counts toward when you name it ("It's MATH 244"
    /// on a window read as SWE makes it Math).
    public static func category(of course: String) -> String? {
        CoachCourse.category(of: course, context: CoachCourse.Context())
    }
}
