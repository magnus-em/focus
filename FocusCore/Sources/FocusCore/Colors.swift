import SwiftUI

public extension ProblemDomain {
    var color: Color {
        switch self {
        case .quant: return Color(red: 0.27, green: 0.62, blue: 0.83)
        case .swe:   return Color(red: 0.25, green: 0.72, blue: 0.53)
        }
    }
    var icon: String {
        switch self {
        case .quant: return "function"
        case .swe:   return "chevron.left.forwardslash.chevron.right"
        }
    }
}

public extension ProblemDifficulty {
    var color: Color {
        switch self {
        case .easy:   return Color(red: 0.22, green: 0.72, blue: 0.45)
        case .medium: return Color(red: 0.98, green: 0.70, blue: 0.18)
        case .hard:   return Color(red: 0.96, green: 0.36, blue: 0.36)
        }
    }
}

public extension Confidence {
    var color: Color {
        switch self {
        case .solid:     return Color(red: 0.22, green: 0.72, blue: 0.45)
        case .shaky:     return Color(red: 0.98, green: 0.70, blue: 0.18)
        case .struggled: return Color(red: 0.96, green: 0.36, blue: 0.36)
        }
    }
}

/// Brand color palette shared across Mac + iPad.
public enum FocusColors {
    public static let focusRed   = Color(red: 0.96, green: 0.36, blue: 0.36)
    /// Break counts under Free time, so it draws in Free time's color (11/13;
    /// it was a light blue that read as School). The name stayed.
    public static let breakBlue  = CategoryGroup.freeTime.color
    public static let goalGreen  = Color(red: 0.25, green: 0.72, blue: 0.53)
    public static let goalAmber  = Color(red: 0.98, green: 0.70, blue: 0.18)
}
