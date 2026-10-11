import ActivityKit
import Foundation

/// Lock Screen / Dynamic Island card for whatever is being tracked.
struct FocusActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var label: String
        var isBreak: Bool
        /// Focus (counts toward the goal) vs a life category.
        var isFocus: Bool
        var since: Date
        /// One-tap switch targets, most used first (not the running one).
        var quick: [String]? = nil
    }
}

/// App ↔ widget extension handoff. The extension has its own defaults, so
/// anything it needs (the category list) is mirrored into the app group.
enum SharedStore {
    static let appGroup = "group.com.magnus.focus"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static var tags: [String] {
        defaults.stringArray(forKey: "tags") ?? UserDefaults.standard.stringArray(forKey: "tags") ?? []
    }
}
