import ActivityKit
import Combine
import Foundation
import SwiftData
import FocusCore

/// Keeps one Live Activity in step with the timer. By default only focus
/// blocks get one: something is tracked all day, and iOS mirrors every Live
/// Activity to the Watch Smart Stack, where it sat on the watch face all day.
/// Changes made on the Mac reach it when this app next runs (foreground, or a
/// background CloudKit push).
@MainActor
enum FocusLiveActivity {
    enum Mode: String, CaseIterable {
        case focus, always, off
        var title: String {
            switch self {
            case .focus: return "Focus blocks"
            case .always: return "Everything tracked"
            case .off: return "Off"
            }
        }
    }

    static let modeKey = "liveActivityMode"
    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .focus }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey); apply() }
    }

    private static var current: Activity<FocusActivityAttributes>? {
        Activity<FocusActivityAttributes>.activities.first
    }

    static func show(label: String, isBreak: Bool, since: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = FocusActivityAttributes.ContentState(
            label: label.isEmpty ? "Focus" : label, isBreak: isBreak,
            isFocus: !isBreak && !FocusCategories.isLife(label), since: since,
            quick: quickCategories(excluding: isBreak ? nil : label)
        )
        if let a = current {
            guard a.content.state != state else { return }
            await a.update(ActivityContent(state: state, staleDate: nil))
        } else {
            _ = try? Activity.request(attributes: FocusActivityAttributes(),
                                      content: ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Most-switched-to categories over the last two weeks, topped up from
    /// the category list so a new device still gets buttons.
    private static func quickCategories(excluding running: String?, limit: Int = 4) -> [String] {
        let since = Date().addingTimeInterval(-14 * 86400)
        let work = WorkSession.SessionType.work.rawValue
        let descriptor = FetchDescriptor<StoredWorkSession>(
            predicate: #Predicate { $0.startTime > since && $0.typeRaw == work }
        )
        let rows = (try? ModelContext(FocusPadApp.sharedContainer).fetch(descriptor)) ?? []
        var counts: [String: Int] = [:]
        for r in rows { if let l = r.label, !l.isEmpty { counts[l, default: 0] += 1 } }
        let tags = SharedStore.tags
        let rank = { (t: String) in tags.firstIndex(of: t) ?? tags.count }
        var out = counts.sorted { $0.value != $1.value ? $0.value > $1.value : rank($0.key) < rank($1.key) }.map(\.key).filter { tags.isEmpty || tags.contains($0) }
        out += tags.filter { !out.contains($0) }
        return Array(out.filter { $0 != running }.prefix(limit))
    }

    static func end() async {
        for a in Activity<FocusActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static var observer: AnyCancellable?
    private static weak var engine: FocusTimerEngine?

    /// Mirror the engine (which also applies peers' state) into the activity.
    static func follow(_ engine: FocusTimerEngine) {
        self.engine = engine
        observer = engine.$sessionStartTime
            .combineLatest(engine.$currentLabel, engine.$phase)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { start, label, phase in
                Task { @MainActor in await sync(start: start, label: label, isBreak: phase.isBreak) }
            }
    }

    static func apply() {
        guard let e = engine else { return }
        Task { await sync(start: e.sessionStartTime, label: e.currentLabel, isBreak: e.phase.isBreak) }
    }

    private static func sync(start: Date?, label: String, isBreak: Bool) async {
        let wanted: Bool
        switch mode {
        case .always: wanted = start != nil
        case .focus: wanted = start != nil && !isBreak && !FocusCategories.isLife(label)
        case .off: wanted = false
        }
        if wanted, let start {
            await show(label: isBreak ? "Break" : label, isBreak: isBreak, since: start)
        } else {
            await end()
        }
    }
}
