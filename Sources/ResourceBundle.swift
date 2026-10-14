import Foundation

extension Bundle {
    /// The app's resource bundle (KaTeX, the LeetCode catalog). SwiftPM's
    /// `Bundle.module` only looks next to the .app and then in the folder it
    /// was built in, and traps if neither exists: an install built in a
    /// since-deleted worktree crashed at launch (10/14). build.sh copies the
    /// bundle into Contents/Resources, so look there and never trap.
    static let focusResources: Bundle? = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
            .compactMap { $0?.appendingPathComponent("Focus_Focus.bundle") }
        return candidates.lazy.compactMap { Bundle(url: $0) }.first
    }()
}
