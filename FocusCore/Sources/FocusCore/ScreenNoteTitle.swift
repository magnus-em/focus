import Foundation

public enum ScreenNoteTitle {
    public static func clean(_ title: String, category: String) -> String? {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "#*\" "))
        if value.lowercased().hasPrefix("title:") { value = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let lower = value.lowercased()
        guard !value.isEmpty, lower != category.lowercased(),
              !["notes so far", "earlier notes", "earlier notes for this block", "study notes", "notes", "new screen text", "activity notes"].contains(lower),
              value.range(of: #"(?i)^(category|windows?|earlier notes|new screen text|system|assistant|user)\s*[:：]"#, options: .regularExpression) == nil,
              LearnedTitlePolicy.reason(value) == nil else { return nil }
        return String(value.prefix(80))
    }
    public static func resolve(_ proposed: String, previous: String?, windows: [String], category: String) -> String {
        for candidate in [proposed] + [previous].compactMap({ $0 }) + windows {
            if let title = clean(candidate, category: category) { return title }
        }
        return "Activity notes"
    }
}
