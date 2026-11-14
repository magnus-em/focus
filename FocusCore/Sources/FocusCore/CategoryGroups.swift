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
    public var color: Color {
        switch self {
        case .school: return Color(red: 0.12, green: 0.36, blue: 1.00)
        case .career: return Color(red: 0.90, green: 0.40, blue: 0.08)
        case .learning: return Color(red: 0.70, green: 0.55, blue: 0.95)
        case .wellbeing: return Color(red: 0.16, green: 0.51, blue: 0.59)
        case .sleep: return Color(red: 0.28, green: 0.30, blue: 0.46)
        case .life: return Color(red: 0.84, green: 0.80, blue: 0.71)
        case .freeTime: return Color(red: 0.90, green: 0.55, blue: 0.69)
        }
    }

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
