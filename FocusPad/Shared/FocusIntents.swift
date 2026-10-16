import AppIntents
import Foundation
import FocusCore
#if FOCUS_APP
import UIKit
#endif

/// Siri / Shortcuts / Action Button / Control Center / Live Activity entry
/// points. They only append a `TimerCommand` (timestamped now); whichever
/// device is running the timer applies it, so a suspended phone with stale
/// timer state can't clobber the session on the Mac.
///
/// Compiled into the widget extension too (controls and Live Activity
/// buttons reference them), but as `LiveActivityIntent`s they always run in
/// the app's process, where the store is.
struct FocusCategory: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static var defaultQuery = FocusCategoryQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct FocusCategoryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FocusCategory] {
        identifiers.map(FocusCategory.init)
    }

    func entities(matching string: String) async throws -> [FocusCategory] {
        SharedStore.tags.filter { $0.localizedCaseInsensitiveContains(string) }.map(FocusCategory.init)
    }

    func suggestedEntities() async throws -> [FocusCategory] {
        SharedStore.tags.map(FocusCategory.init)
    }
}

#if FOCUS_APP
@MainActor
enum FocusCommandSender {
    static func send(_ action: TimerCommand.Action, label: String = "", minutes: Double = 0) async {
        TimerCommand.send(action, label: label, minutes: minutes,
                          deviceID: TimerStateSync.persistedDeviceID(),
                          container: FocusPadApp.sharedContainer)
        // Show the change on the Lock Screen now rather than after the round trip.
        switch action {
        case .switchTo: await FocusLiveActivity.show(label: label, isBreak: false, since: Date())
        case .startBreak: await FocusLiveActivity.show(label: "Break", isBreak: true, since: Date())
        case .stop: await FocusLiveActivity.end()
        }
        if let engine = FocusPadApp.liveEngine, UIApplication.shared.applicationState == .active {
            engine.stateSync.pokeForRemote()
            return
        }
        // Launched in the background just for this intent: stay alive long
        // enough for the CloudKit mirror to export the command.
        let task = UIApplication.shared.beginBackgroundTask(withName: "focusCommandExport")
        try? await Task.sleep(for: .seconds(12))
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}
#endif

struct SwitchFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Switch Focus"
    static var description = IntentDescription("Start tracking a category. Whatever was being tracked is saved up to now.")

    @Parameter(title: "Category") var category: FocusCategory

    init() {}
    init(category: FocusCategory) { self.category = category }

    static var parameterSummary: some ParameterSummary { Summary("Switch to \(\.$category)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if FOCUS_APP
        await FocusCommandSender.send(.switchTo, label: category.id)
        #endif
        return .result(dialog: "Tracking \(category.id).")
    }
}

struct StopFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Focus Timer"
    static var description = IntentDescription("Stop and save whatever is being tracked.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if FOCUS_APP
        await FocusCommandSender.send(.stop)
        #endif
        return .result(dialog: "Stopped.")
    }
}

struct TakeBreakIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Take a Break"
    static var description = IntentDescription("Save the current focus and start a break. 0 minutes = open-ended.")

    @Parameter(title: "Minutes", default: 0, inclusiveRange: (0, 480)) var minutes: Int

    init() {}
    init(minutes: Int) { self.minutes = minutes }

    static var parameterSummary: some ParameterSummary { Summary("Take a \(\.$minutes) minute break") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if FOCUS_APP
        await FocusCommandSender.send(.startBreak, minutes: Double(minutes))
        #endif
        return .result(dialog: minutes > 0 ? "Break for \(minutes) minutes." : "On a break.")
    }
}

#if FOCUS_APP
import SwiftData

/// "Hey Siri, how much have I focused today in Focus?" — on the phone, or a
/// HomePod through the phone. Reads the synced log, so it counts the Mac too.
struct FocusTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus Today"
    static var description = IntentDescription("How much you've focused today, against your goal, and what's running.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(FocusPadApp.sharedContainer)
        let now = Date()
        let rows = try context.fetch(FetchDescriptor<StoredWorkSession>(predicate: #Predicate { $0.startTime < now }))
        var live: DailyFocusTotal.Live?
        var running = ""
        if let e = FocusPadApp.liveEngine, e.isActive, let start = e.sessionStartTime {
            let active = e.activeElapsedSeconds
            let elapsed = active.isFinite ? max(0, min(active, now.timeIntervalSince(start))) : 0
            let label = e.isOnBreak ? "Break" : e.currentLabel.isEmpty ? "Focus" : e.currentLabel
            running = " \(e.isRunning ? "Right now" : "Paused"): \(label), \(Self.spoken(elapsed / 60))."
            live = .init(start: start, activeSeconds: elapsed, label: label, isBreak: e.isOnBreak)
        }
        let life = Set(UserDefaults.standard.stringArray(forKey: FocusCategories.lifeTagsKey) ?? FocusCategories.defaultLifeTags)
        let byLabel = DailyFocusTotal.categoryMinutes(saved: rows.map(\.asValue), live: live, on: now, through: now, lifeTags: life)
        let total = byLabel.values.reduce(0, +)
        let goal = Double(UserDefaults.standard.object(forKey: "dailyGoalHours") as? Int ?? 4) * 60
        let top = byLabel.max { $0.value < $1.value }?.key
        var text = total < 1 ? "No focus logged yet today." : "You've focused \(Self.spoken(total)) today\(top.map { ", mostly \($0)" } ?? "")."
        if goal > 0, total >= 1 {
            text += total >= goal ? " That's your \(Int(goal / 60))-hour goal done." : " \(Self.spoken(goal - total)) to your goal."
        }
        return .result(dialog: "\(text + running)")
    }

    static func spoken(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        let hs = h == 1 ? "1 hour" : "\(h) hours", ms = m == 1 ? "1 minute" : "\(m) minutes"
        return h == 0 ? ms : m == 0 ? hs : "\(hs) \(ms)"
    }
}

struct FocusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SwitchFocusIntent(),
            phrases: [
                "Switch to \(\.$category) in \(.applicationName)",
                "Track \(\.$category) in \(.applicationName)",
                "Switch \(.applicationName) category",
            ],
            shortTitle: "Switch",
            systemImageName: "arrow.triangle.swap"
        )
        AppShortcut(
            intent: StopFocusIntent(),
            phrases: ["Stop tracking in \(.applicationName)"],
            shortTitle: "Stop",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: FocusTodayIntent(),
            phrases: [
                "How much have I focused today in \(.applicationName)",
                "How's my day in \(.applicationName)",
            ],
            shortTitle: "Focus today",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: LogDoseIntent(),
            phrases: [
                "Log Adderall in \(.applicationName)",
                "Log \(\.$dose) in \(.applicationName)",
            ],
            shortTitle: "Log Adderall",
            systemImageName: "pills.fill"
        )
        AppShortcut(
            intent: TakeBreakIntent(),
            phrases: ["Take a break in \(.applicationName)"],
            shortTitle: "Break",
            systemImageName: "cup.and.saucer.fill"
        )
    }
}
#endif
