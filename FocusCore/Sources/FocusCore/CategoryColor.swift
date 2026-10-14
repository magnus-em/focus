import SwiftUI

/// Focus categories get vivid, well-separated hues (and lightness, so they
/// still differ in grayscale); life categories are quieter. Math and SWE
/// were a shade apart until 10/13.
public func categoryColor(_ tag: String) -> Color {
    switch tag.lowercased() {
    case "swe":      return Color(red: 0.20, green: 0.74, blue: 0.47)
    case "math":     return Color(red: 0.12, green: 0.36, blue: 1.00)
    case "quant":    return Color(red: 0.35, green: 0.78, blue: 0.98)
    case "ai", "ai/ml": return Color(red: 0.66, green: 0.38, blue: 0.94)
    case "hw":       return Color(red: 0.98, green: 0.70, blue: 0.16)
    case "class":    return Color(red: 1.00, green: 0.48, blue: 0.27)
    case "leisure":  return Color(red: 0.93, green: 0.42, blue: 0.62)
    case "social":   return Color(red: 0.78, green: 0.40, blue: 0.76)
    case "exercise": return Color(red: 0.58, green: 0.76, blue: 0.32)
    case "meals":    return Color(red: 0.80, green: 0.60, blue: 0.44)
    case "reading":  return Color(red: 0.80, green: 0.74, blue: 0.40)
    case "sleep":    return Color(red: 0.36, green: 0.38, blue: 0.52)
    case "chores":   return Color(red: 0.62, green: 0.58, blue: 0.52)
    case "commute":  return Color(red: 0.48, green: 0.56, blue: 0.62)
    case "admin":    return Color(red: 0.60, green: 0.50, blue: 0.42)
    default:         return Color(red: 0.30, green: 0.70, blue: 0.70)
    }
}

public func categoryIcon(_ category: String) -> String {
    switch category.lowercased() {
    case "sleep": return "bed.double.fill"
    case "meals": return "fork.knife"
    case "exercise": return "figure.run"
    case "class": return "graduationcap.fill"
    case "commute": return "tram.fill"
    case "social": return "person.2.fill"
    case "leisure": return "gamecontroller.fill"
    case "chores": return "basket.fill"
    case "admin": return "tray.full.fill"
    case "swe": return "chevron.left.forwardslash.chevron.right"
    case "quant": return "function"
    case "ai": return "sparkles"
    case "hw": return "pencil.and.list.clipboard"
    default: return "scope"
    }
}
