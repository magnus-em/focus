import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The seven groups every category, old or new, is shown under. Locked by the
/// user on 11/13 (CATEGORIES.md: "I don't want a million categories", and old
/// data shown the same way over time). The table is applied when drawing;
/// saved blocks keep the category they were logged with.
///
/// Counting toward focus stays per category, as before: everything in School,
/// Career and Learning & projects counts except Class.
public enum CategoryGroup: String, CaseIterable, Codable, Sendable {
    case school = "School"
    case career = "Career"
    case learning = "Learning & projects"
    case wellbeing = "Wellbeing"
    case sleep = "Sleep"
    case life = "Life"
    case freeTime = "Free time"

    /// SWE is School: on screen it was mostly CPSC 3231/4585 coursework.
    /// Quant was May's interview prep. AI holds deep learning, CPSC 7770 included,
    /// as the Deep learning goal does.
    public static let table: [String: CategoryGroup] = [
        "HW": .school, "Math": .school, "SWE": .school, "Class": .school,
        "Recruiting": .career, "LeetCode": .career, "Quant": .career,
        "AI": .learning,
        "Reading": .wellbeing, "Journaling": .wellbeing, "Exercise": .wellbeing,
        "Sleep": .sleep,
        "Meals": .life, "Chores": .life, "Commute": .life, "Admin": .life,
        "Leisure": .freeTime, "Social": .freeTime, "Break": .freeTime,
    ]

    /// School, Career and Learning & projects hold the focus categories.
    public var holdsFocus: Bool { self == .school || self == .career || self == .learning }

    /// Hues borrowed from each group's main category (Math blue, LeetCode
    /// orange, AI purple, Leisure pink), lightness spread so neighbours in a
    /// stacked bar differ by 10+ L* (DESIGN.md: distinct in lightness, not
    /// only hue). Wellbeing leans cyan so it isn't read as "good" green.
    /// School, Wellbeing and Sleep lighten in dark mode to keep 3:1 on the
    /// dark card; Life sits well apart from the "not logged" grey; Free time
    /// (Break too) stays soft, as a life group should.
    public var color: Color {
        switch self {
        case .school: return Self.schoolColor
        case .career: return Color(red: 0.90, green: 0.40, blue: 0.08)
        case .learning: return Self.learningColor
        case .wellbeing: return Self.wellbeingColor
        case .sleep: return Self.sleepColor
        case .life: return Color(red: 0.61, green: 0.51, blue: 0.37)
        case .freeTime: return Color(red: 0.89, green: 0.64, blue: 0.75)
        }
    }

    // Built once: two dynamic colours built separately never compare equal.
    private static let schoolColor = dynamic(light: (0.12, 0.36, 1.00), dark: (0.43, 0.52, 1.00))
    // Dark: lighter and toward violet-magenta, or it matched dark School (review 11/13).
    private static let learningColor = dynamic(light: (0.70, 0.55, 0.95), dark: (0.84, 0.62, 0.98))
    private static let wellbeingColor = dynamic(light: (0.16, 0.51, 0.59), dark: (0.30, 0.64, 0.71))
    private static let sleepColor = dynamic(light: (0.28, 0.30, 0.46), dark: (0.40, 0.42, 0.62))

    /// Untracked time in charts of the groups: a grey that reads as a fill,
    /// not as empty plot area.
    public static let untrackedColor = dynamic(light: (0.89, 0.89, 0.92), dark: (0.17, 0.17, 0.22))

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }

    /// The group for a block. Breaks and unlabeled blocks are Free time. A
    /// category added later without a table entry falls back on focus vs
    /// life (Learning & projects or Life) until it's given a group.
    public static func of(_ label: String?, isBreak: Bool = false, isLife: Bool? = nil) -> CategoryGroup {
        if isBreak { return .freeTime }
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return .freeTime }
        if let g = table[label] ?? table.first(where: { $0.key.caseInsensitiveCompare(label) == .orderedSame })?.value {
            return g
        }
        return (isLife ?? FocusCategories.isLife(label)) ? .life : .learning
    }
}
