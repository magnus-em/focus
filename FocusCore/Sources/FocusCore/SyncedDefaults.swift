import Foundation

/// Settings that should sync across the user's devices use this instead of
/// `UserDefaults.standard`. It writes to BOTH UserDefaults (fast local read,
/// works offline) AND `NSUbiquitousKeyValueStore` (iCloud key-value store,
/// 1MB / 1024 keys, auto-syncs to all this-user's devices).
///
/// On launch we pull any newer iCloud values down to UserDefaults so the
/// app starts with the synced state. While running, external KVS changes
/// (from another device) fire `NSUbiquitousKeyValueStore.didChangeExternally`
/// — we mirror those into UserDefaults and post a Darwin notification so
/// observable settings classes can refresh.
public final class SyncedDefaults {
    public static let shared = SyncedDefaults()

    /// Posted when external iCloud changes have been mirrored into
    /// UserDefaults. Settings classes should observe this and re-read.
    public static let didImportRemoteChanges = Notification.Name("FocusCore.SyncedDefaults.didImportRemoteChanges")

    private let kvs = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var observer: NSObjectProtocol?

    /// Keys we want to sync. Anything not in this set stays device-local.
    public static let syncedKeys: Set<String> = [
        "workMinutes",
        "shortBreakMinutes",
        "longBreakMinutes",
        "sessionsBeforeLongBreak",
        "dailyGoalHours",
        "autoStartBreaks",
        "autoStartWork",
        "soundEnabled",
        "pauseGraceMinutes",
        "autoBreakEnabled",
        "tags",
        "lifeTags",
        "quantGoal",
        "quantWeeklyGoal",
        "sweGoal",
        "sweWeeklyGoal",
        "homeworkDailyGoal",
        "problemSources",
        "interviewDate",
        "commitmentEnabled",
        "todayCommitment",
        "lastCommitmentDateEpoch",
    ]

    private init() {
        #if !targetEnvironment(simulator)
        // ONLY pull from iCloud the very first time this device sees the
        // synced-settings layer. After that, local UserDefaults is the
        // source of truth — incoming KVS changes come in via the
        // didChangeExternally observer, which fires only when *iCloud*
        // says it has newer data. This prevents the launch import from
        // clobbering a value the user just changed locally.
        let firstRunKey = "syncedDefaults.didImportOnce"
        if !defaults.bool(forKey: firstRunKey) {
            importRemote()
            defaults.set(true, forKey: firstRunKey)
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs, queue: .main
        ) { [weak self] note in
            self?.handleExternalChange(note)
        }

        // Kick the KVS to fetch the latest snapshot. If it has newer data,
        // didChangeExternally will fire and the observer will handle it.
        kvs.synchronize()
        #endif
    }

    /// True while a settings object reloads itself from imported values: its
    /// didSets must not push those values back to iCloud, or a device that
    /// hasn't received every key yet reverts the others (it once undid
    /// today's commitment date with yesterday's).
    public var isReloading = false

    /// Call from any settings setter. Writes to both stores.
    public func set(_ value: Any?, forKey key: String) {
        guard !isReloading else { return }
        defaults.set(value, forKey: key)
        #if !targetEnvironment(simulator)
        guard Self.syncedKeys.contains(key) else { return }
        if let value {
            kvs.set(value, forKey: key)
        } else {
            kvs.removeObject(forKey: key)
        }
        #endif
    }

    /// Force a KVS push (most app lifecycle moments do this implicitly).
    public func synchronize() {
        #if !targetEnvironment(simulator)
        kvs.synchronize()
        #endif
    }

    private func importRemote() {
        for key in Self.syncedKeys {
            guard let remote = kvs.object(forKey: key) else { continue }
            // Always trust iCloud's view on launch — assumes it's at least as
            // recent. (KVS only fires didChangeExternally for *newer* values.)
            defaults.set(remote, forKey: key)
        }
    }

    private func handleExternalChange(_ note: Notification) {
        guard let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        else { return }
        var imported = false
        for key in changedKeys where Self.syncedKeys.contains(key) {
            if let v = kvs.object(forKey: key) {
                defaults.set(v, forKey: key)
                imported = true
            }
        }
        if imported {
            NotificationCenter.default.post(name: Self.didImportRemoteChanges, object: nil)
        }
    }
}
