import SwiftUI
import SwiftData
import FocusCore

@main
struct FocusPadApp: App {
    /// Shared with App Intents, including background launches with no UI.
    static let sharedContainer: ModelContainer = {
        let useCloud = UserDefaults.standard.object(forKey: "cloudKitSyncEnabled") as? Bool ?? true
        do {
            return try FocusModelContainer.make(cloudKitSync: useCloud)
        } catch {
            print("[FocusPad] CloudKit init failed, falling back to local: \(error)")
            return try! FocusModelContainer.make(cloudKitSync: false)
        }
    }()
    @MainActor static weak var liveEngine: FocusTimerEngine?

    let container: ModelContainer
    @StateObject private var settings: PadSettings
    @StateObject private var engine: FocusTimerEngine
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CloudSyncMonitor.shared.start()
        let c = Self.sharedContainer
        self.container = c
        FocusShortcuts.updateAppShortcutParameters()

        // Strict dedup at startup — key is whole-second startTime + type +
        // label + duration rounded to 0.01 min, so legitimately identical
        // back-to-back sessions don't collapse (their start seconds differ).
        // Catches the actual failure mode: Mac and iPad both inserting a row
        // for the same broadcast event with different UUIDs.
        let removed = FocusMigration.dedupeWorkSessions(container: c)
        if removed > 0 { print("[FocusPad] startup dedup removed \(removed) duplicate session(s)") }

        // Recover orphan rows that lack CloudKit metadata (NSPersistentCloudKit
        // didn't track them, so they won't sync). Re-inserts through SwiftData
        // so the export pipeline picks them up.
        let recovered = FocusMigration.recoverOrphanSessions(container: c)
        if recovered > 0 { print("[FocusPad] startup recovered \(recovered) orphan session(s) for CK sync") }

        let s = PadSettings()
        SharedStore.defaults.set(s.tags, forKey: "tags")
        _settings = StateObject(wrappedValue: s)
        let e = FocusTimerEngine(container: c, settings: s.engineSettings)
        _engine = StateObject(wrappedValue: e)
        Self.liveEngine = e
        // Set up here, not in onAppear, so a background CloudKit wake (Mac
        // switched) updates the Lock Screen too.
        FocusLiveActivity.follow(e)
        DoseMirror.followRemoteChanges()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(engine)
                .onAppear { Self.liveEngine = engine }
                .onChange(of: settings.tags) { _, tags in SharedStore.defaults.set(tags, forKey: "tags") }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else { return }
                    DoseMirror.update(from: container)
                    Task { await HealthImport.run(container: container, tags: settings.tags, runningSince: engine.isActive ? engine.sessionStartTime : nil) }
                }
        }
        .modelContainer(container)
    }
}
