import Foundation
import FocusCore

/// "Wrong?" on what Focus reads in front (popover, ⌃⌥⌘'): the window learns
/// its class or category, the block it named is renamed when both are study
/// categories, and the answer goes to `Focus/screen-corrections.jsonl` for
/// the accuracy numbers on the Insights page. A life category isn't forced
/// onto a study block: leaving focus is a switch the screen makes after 8 min
/// of it, backdated, as before.
@MainActor
enum ReadingCorrection {
    /// `course`: a course code, `ScreenCourse.notAClass`, or nil to leave the course alone.
    /// Returns a line saying what changed, nil when there's nothing in front to correct.
    @discardableResult
    static func apply(category: String?, course: String?, timer: TimerManager, via: String) -> String? {
        guard let r = FocusStreakStore.shared.reading, !r.bundle.isEmpty,
              r.category != WindowTimeline.privateCategory else { return nil }
        let target = category ?? course.flatMap { $0 == ScreenCourse.notAClass ? nil : ScreenCourse.category(of: $0) }
        let block = timer.isActive && !timer.isOnBreak && !timer.currentLabel.isEmpty ? timer.currentLabel : nil
        let since = block != nil ? timer.sessionStartTime ?? Date() : Date().addingTimeInterval(-30 * 60)
        let windows = ScreenWatcher.shared.teach(bundle: r.bundle, app: r.app, title: r.title,
                                                 readAs: (r.category, r.course), since: since,
                                                 category: target, course: course)
        var renamed: String?
        if let block, let target, target != block, r.category == block,
           !FocusCategories.isLife(block), block != "Class", !FocusCategories.isLife(target) {
            timer.relabelRunning(target)
            renamed = target
        }
        FocusStreakStore.shared.corrected(category: target, course: course)
        ScreenWatcher.logCorrection(.init(
            at: Date(), app: r.app, bundle: r.bundle, title: r.title, windows: windows.sorted(), since: since,
            wasCategory: r.state == .labeled ? r.category : nil, wasCourse: r.course,
            wasSource: r.state == .labeled ? "label" : (r.state == .unsure ? "unsure" : "unread"),
            toCategory: target, toCourse: course, block: block, renamedTo: renamed, via: via))
        let name = r.title.isEmpty ? r.app : String(r.title.prefix(40))
        let what = course.map { $0 == ScreenCourse.notAClass ? "not a class" : $0 } ?? target ?? "unlabeled"
        return "\(name) is \(what)" + (renamed.map { " · this block is \($0) now" } ?? "")
    }

    /// The title menu's "Not this? It's…": the block itself was named wrong.
    static func logRename(from: String, to: String, windows: Set<String>, since: Date) {
        let r = FocusStreakStore.shared.reading
        ScreenWatcher.logCorrection(.init(
            at: Date(), app: r?.app ?? "", bundle: r?.bundle ?? "", title: r?.title ?? "", windows: windows.sorted(),
            since: since, wasCategory: from, wasCourse: r?.course, wasSource: "block", toCategory: to, toCourse: nil,
            block: from, renamedTo: to, via: "title menu"))
    }
}
