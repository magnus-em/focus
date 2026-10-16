import Foundation
import FocusCore

/// The Mac's `DayBrief`s, read from iCloud's key-value store and kept current
/// as the Mac rewrites them.
@MainActor
final class DayBriefStore: ObservableObject {
    static let shared = DayBriefStore()

    @Published private(set) var briefs: [String: DayBrief] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        NSUbiquitousKeyValueStore.default.synchronize()
        briefs = DayBrief.readAll()
        #if DEBUG && targetEnvironment(simulator)
        if briefs.isEmpty, ProcessInfo.processInfo.arguments.contains("-seedDemo") { briefs = DemoSeed.briefs() }
        #endif
    }

    func brief(for day: Date) -> DayBrief? { briefs[DayBrief.dayKey(day)] }
}
