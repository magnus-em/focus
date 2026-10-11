import SwiftUI

public func categoryColor(_ tag: String) -> Color {
    switch tag.lowercased() {
    case "quant":    return Color(red: 0.27, green: 0.62, blue: 0.83)
    case "swe":      return Color(red: 0.25, green: 0.72, blue: 0.53)
    case "ai", "ai/ml": return Color(red: 0.65, green: 0.40, blue: 0.90)
    case "hw":       return Color(red: 0.98, green: 0.70, blue: 0.18)
    case "class":    return Color(red: 0.36, green: 0.42, blue: 0.86)
    case "meals":    return Color(red: 0.95, green: 0.52, blue: 0.25)
    case "leisure":  return Color(red: 0.93, green: 0.42, blue: 0.62)
    case "sleep":    return Color(red: 0.33, green: 0.36, blue: 0.52)
    case "chores":   return Color(red: 0.62, green: 0.58, blue: 0.52)
    case "exercise": return Color(red: 0.55, green: 0.78, blue: 0.25)
    case "social":   return Color(red: 0.80, green: 0.35, blue: 0.80)
    case "commute":  return Color(red: 0.45, green: 0.55, blue: 0.62)
    case "admin":    return Color(red: 0.62, green: 0.50, blue: 0.40)
    default:         return Color(red: 0.30, green: 0.78, blue: 0.74)
    }
}
