import Foundation
import HealthKit
import SwiftData
import FocusCore

/// Apple Health → the day log: sleep (merged into nights of 3h+) becomes
/// Sleep and workouts (10 min+) become Exercise, but only in time nothing
/// else covers. It never overwrites what you tracked, so running it again
/// (or the Mac's morning fill-in running first) changes nothing.
@MainActor
enum HealthImport {
    static let enabledKey = "healthImport"
    static let lastAttemptKey = "healthImportLastAttempt"
    static let lastSuccessKey = "healthImportLastSuccess"
    static let lastResultKey = "healthImportLastResult"
    static let lastErrorKey = "healthImportLastError"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let store = HKHealthStore()
    private static var lastRun = Date.distantPast
    private static var importing = false

    static func run(container: ModelContainer, tags: [String], runningSince: Date?, force: Bool = false) async {
        guard enabled, !importing, force || Date().timeIntervalSince(lastRun) > 600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAttemptKey)
        guard HKHealthStore.isHealthDataAvailable() else {
            UserDefaults.standard.set("Apple Health isn't available on this device.", forKey: lastErrorKey)
            return
        }
        lastRun = Date()
        importing = true
        defer { importing = false }
        let sleep = HKCategoryType(.sleepAnalysis)
        do {
            try await store.requestAuthorization(toShare: [], read: [sleep, HKObjectType.workoutType()])
            let from = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
            var blocks: [(start: Date, end: Date, label: String)] = []
            if tags.contains("Sleep") { blocks += try await nights(since: from).map { ($0.start, $0.end, "Sleep") } }
            if tags.contains("Exercise") { blocks += try await workouts(since: from).map { ($0.start, $0.end, "Exercise") } }
            let limit = min(runningSince ?? Date(), Date())
            let inserted = try fill(blocks.compactMap { b in b.start < limit ? (b.start, min(b.end, limit), b.label) : nil }, container: container)
            let result = !tags.contains("Sleep") && !tags.contains("Exercise")
                ? "Add Sleep or Exercise to your categories to import Health time."
                : blocks.isEmpty ? "No readable sleep or workout data in the last three days. Check Health access if you expected some."
                : inserted == 0 ? "No new Health time to add to untracked gaps."
                : "Added \(inserted) \(inserted == 1 ? "time block" : "time blocks") to untracked gaps."
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSuccessKey)
            UserDefaults.standard.set(result, forKey: lastResultKey)
            UserDefaults.standard.set("", forKey: lastErrorKey)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: lastErrorKey)
        }
    }

    private static func nights(since from: Date) async throws -> [DateInterval] {
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: from, end: Date()))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = try await query.result(for: store)
        // Watch and phone both write stages; brief wakes don't end the night.
        var merged: [DateInterval] = []
        for s in samples where asleep.contains(s.value) {
            if let last = merged.last, s.startDate.timeIntervalSince(last.end) < 45 * 60 {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, s.endDate))
            } else {
                merged.append(DateInterval(start: s.startDate, end: s.endDate))
            }
        }
        return merged.filter { $0.duration >= 3 * 3600 }
    }

    private static func workouts(since from: Date) async throws -> [DateInterval] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: from, end: Date()))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let list = try await query.result(for: store)
        return list.map { DateInterval(start: $0.startDate, end: $0.endDate) }.filter { $0.duration >= 10 * 60 }
    }

    /// Inserts each block's uncovered parts of 10 min or more.
    private static func fill(_ blocks: [(Date, Date, String)], container: ModelContainer) throws -> Int {
        guard !blocks.isEmpty else { return 0 }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        var inserted = 0
        for (start, end, label) in blocks where end.timeIntervalSince(start) >= 600 {
            let descriptor = FetchDescriptor<StoredWorkSession>(predicate: #Predicate { $0.startTime < end })
            let covered = (try context.fetch(descriptor))
                .map { DateInterval(start: $0.startTime, end: $0.startTime.addingTimeInterval($0.durationMinutes * 60)) }
                .filter { $0.end > start }
                .sorted { $0.start < $1.start }
            var cursor = start
            var gaps: [DateInterval] = []
            for c in covered {
                if c.start > cursor { gaps.append(DateInterval(start: cursor, end: min(c.start, end))) }
                cursor = max(cursor, c.end)
                if cursor >= end { break }
            }
            if cursor < end { gaps.append(DateInterval(start: cursor, end: end)) }
            for g in gaps where g.duration >= 600 {
                context.insert(StoredWorkSession(value: WorkSession(startTime: g.start, durationMinutes: g.duration / 60,
                                                                    type: .work, label: label)))
                inserted += 1
            }
        }
        if inserted > 0 { try context.save() }
        return inserted
    }
}
