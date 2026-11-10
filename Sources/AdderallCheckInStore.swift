import Foundation
import Combine
import FocusCore
import UserNotifications

/// Daily Adderall check-ins: `Focus/adderall-checkins.json`, mirrored to iCloud
/// KVS (`adderallCheckIns`) so another device can read and answer them later.
final class AdderallCheckInStore: ObservableObject {
    static let shared = AdderallCheckInStore()
    static let kvsKey = "adderallCheckIns"
    static let reminderPrefix = "adderall-checkin-"

    @Published private(set) var all: [String: AdderallCheckIn] = [:]
    @Published private(set) var saveError: String?

    @Published var reminderOn: Bool { didSet { defaults.set(reminderOn, forKey: "adderallCheckInReminder"); scheduleReminders() } }
    /// Minutes after midnight.
    @Published var reminderMinutes: Int { didSet { defaults.set(reminderMinutes, forKey: "adderallCheckInMinutes"); scheduleReminders() } }

    private let defaults = UserDefaults.standard
    private let kvs = NSUbiquitousKeyValueStore.default
    private let url: URL
    private var observer: NSObjectProtocol?

    private init() {
        defaults.register(defaults: ["adderallCheckInReminder": false, "adderallCheckInMinutes": 21 * 60 + 30])
        reminderOn = defaults.bool(forKey: "adderallCheckInReminder")
        reminderMinutes = defaults.integer(forKey: "adderallCheckInMinutes")
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/adderall-checkins.json")
        let local = (try? Data(contentsOf: url)).flatMap(Self.decode) ?? [:]
        all = AdderallCheckIn.merge(local, readKVS())
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main
        ) { [weak self] note in
            guard let self, (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])?.contains(Self.kvsKey) == true else { return }
            let merged = AdderallCheckIn.merge(self.all, self.readKVS())
            if merged != self.all { self.all = merged; self.writeFile(); self.scheduleReminders() }
        }
    }

    func checkIn(on day: Date) -> AdderallCheckIn? { all[AdderallCheckIn.dayKey(day)] }

    @discardableResult
    func save(_ checkIn: AdderallCheckIn) -> Bool {
        var c = checkIn
        c.updatedAt = Date()
        if !c.tookDose { c.hoursWorked = nil; c.comedown = nil; c.worthIt = nil }
        let before = all
        all[c.day] = c
        guard writeFile() else { all = before; return false }
        writeKVS()
        scheduleReminders()
        return true
    }

    func summary(days: Int, end: Date = Date()) -> CheckInSummary { CheckInSummary.make(all, days: days, end: end) }

    // MARK: - Persistence

    private static func decode(_ data: Data) -> [String: AdderallCheckIn]? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode([String: AdderallCheckIn].self, from: data)
    }

    private static func encode(_ all: [String: AdderallCheckIn]) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(all)
    }

    private func readKVS() -> [String: AdderallCheckIn] { kvs.data(forKey: Self.kvsKey).flatMap(Self.decode) ?? [:] }

    @discardableResult
    private func writeFile() -> Bool {
        do {
            guard let data = Self.encode(all) else { throw CocoaError(.coderInvalidValue) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func writeKVS() {
        let merged = AdderallCheckIn.merge(readKVS(), all)
        guard let data = Self.encode(merged) else { return }
        kvs.set(data, forKey: Self.kvsKey)
        kvs.synchronize()
    }

    // MARK: - Evening reminder

    /// One request per evening for the next week, skipping days already answered.
    func scheduleReminders(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [weak self] pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            DispatchQueue.main.async { self?.addReminders(center: center, now: now) }
        }
    }

    private func addReminders(center: UNUserNotificationCenter, now: Date) {
        guard reminderOn else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  checkIn(on: day) == nil,
                  let fire = cal.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: day),
                  fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "How did Adderall treat you today?"
            content.body = "Record how you felt, including anxiety and other side effects. You can record off days too."
            content.sound = .default
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(identifier: Self.reminderPrefix + AdderallCheckIn.dayKey(day), content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    /// The day a tapped reminder asked about.
    static func day(fromReminder id: String) -> Date? {
        guard id.hasPrefix(reminderPrefix) else { return nil }
        return AdderallCheckIn.date(String(id.dropFirst(reminderPrefix.count)))
    }
}
