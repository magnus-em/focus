import SwiftUI

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

    /// Borrowed from each group's main category so the colors already mean
    /// something: Math blue, LeetCode orange, AI purple, Leisure pink. Focus
    /// groups vivid, the rest quieter (DESIGN.md), apart in lightness too.
    public var color: Color {
        switch self {
        case .school: return Color(red: 0.12, green: 0.36, blue: 1.00)
        case .career: return Color(red: 0.90, green: 0.40, blue: 0.08)
        case .learning: return Color(red: 0.66, green: 0.38, blue: 0.94)
        case .wellbeing: return Color(red: 0.50, green: 0.72, blue: 0.34)
        case .sleep: return Color(red: 0.33, green: 0.35, blue: 0.50)
        case .life: return Color(red: 0.66, green: 0.58, blue: 0.48)
        case .freeTime: return Color(red: 0.93, green: 0.48, blue: 0.66)
        }
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
