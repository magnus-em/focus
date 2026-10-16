import AppIntents
import Foundation
import FocusCore
#if FOCUS_APP
import SwiftData
import UIKit
import WidgetKit
#endif

/// Adderall doses copied into the app group for the widgets, which can't open
/// the synced store. The app rewrites it whenever doses change here or arrive
/// from the Mac.
enum DoseMirror {
    struct Dose: Codable, Hashable {
        var date: Date
        var kind: String
        var healthKind: HealthKind? { HealthKind(rawValue: kind) }
    }

    static let widgetKind = "com.magnus.focus.dose"
    private static let key = "adderallDoses"

    static func read() -> [Dose] {
        guard let data = SharedStore.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Dose].self, from: data)) ?? []
    }

    /// Oldest first, only doses already taken.
    static func doses(on day: Date, from all: [Dose] = read(), now: Date = Date()) -> [Dose] {
        all.filter { Calendar.current.isDate($0.date, inSameDayAs: day) && $0.date <= now }
            .sorted { $0.date < $1.date }
    }

    #if FOCUS_APP
    @MainActor
    static func update(from container: ModelContainer = FocusPadApp.sharedContainer) {
        let since = Date().addingTimeInterval(-2 * 86400)
        let kinds = HealthTracker.adderall.kinds.map(\.rawValue)
        let descriptor = FetchDescriptor<StoredHealthEvent>(predicate: #Predicate { $0.date > since })
        let doses = ((try? container.mainContext.fetch(descriptor)) ?? [])
            .filter { kinds.contains($0.kind) }
            .map { Dose(date: $0.date, kind: $0.kind) }
            .sorted { $0.date < $1.date }
        guard doses != read(), let data = try? JSONEncoder().encode(doses) else { return }
        SharedStore.defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    private static var remoteObserver: NSObjectProtocol?

    /// Doses logged on the Mac reach the phone through the CloudKit mirror,
    /// sometimes while the app is only woken in the background.
    static func followRemoteChanges() {
        guard remoteObserver == nil else { return }
        remoteObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                update()
            }
        }
    }
    #endif
}

#if FOCUS_APP
@MainActor
enum DoseLog {
    @discardableResult
    static func log(_ kind: HealthKind, at date: Date) -> UUID? {
        let context = FocusPadApp.sharedContainer.mainContext
        let model = StoredHealthEvent(date: date, kind: kind.rawValue)
        context.insert(model)
        guard save(context) else { return nil }
        return model.id
    }

    @discardableResult
    static func update(id: UUID, kind: HealthKind, at date: Date) -> Bool {
        let context = FocusPadApp.sharedContainer.mainContext
        guard let model = try? context.fetch(FetchDescriptor<StoredHealthEvent>(predicate: #Predicate { $0.id == id })).first
        else { return false }
        model.kind = kind.rawValue
        model.date = date
        return save(context)
    }

    static func logFromIntent(_ kind: HealthKind, at date: Date) async -> Bool {
        guard log(kind, at: date) != nil else { return false }
        guard UIApplication.shared.applicationState != .active else { return true }
        // Launched in the background just for this: stay alive long enough
        // for the CloudKit mirror to export the dose to the Mac.
        let task = UIApplication.shared.beginBackgroundTask(withName: "focusDoseExport")
        try? await Task.sleep(for: .seconds(12))
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        return true
    }

    static func delete(id: UUID) {
        let context = FocusPadApp.sharedContainer.mainContext
        try? context.delete(model: StoredHealthEvent.self, where: #Predicate { $0.id == id })
        save(context)
    }

    @discardableResult
    private static func save(_ context: ModelContext) -> Bool {
        do {
            try context.save()
        } catch {
            context.rollback()
            return false
        }
        DoseMirror.update()
        return true
    }
}
#endif

enum AdderallDose: String, AppEnum {
    case ir10 = "adderallIR10"
    case ir20 = "adderallIR20"
    case xr20 = "adderallXR20"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dose"
    static var caseDisplayRepresentations: [AdderallDose: DisplayRepresentation] = [
        .ir10: "IR 10 mg", .ir20: "IR 20 mg", .xr20: "XR 20 mg",
    ]

    var kind: HealthKind { HealthKind(rawValue: rawValue) ?? .adderallIR20 }
}

/// A `LiveActivityIntent` so widget and Control Center buttons run it in the
/// app's process, where the store is.
struct LogDoseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Log Adderall"
    static var description = IntentDescription("Log an Adderall dose taken now. Today's clock starts at the first dose.")

    @Parameter(title: "Dose", default: .ir20) var dose: AdderallDose

    init() {}
    init(dose: AdderallDose) { self.dose = dose }

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$dose)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        #if FOCUS_APP
        guard await DoseLog.logFromIntent(dose.kind, at: now) else {
            return .result(dialog: "Couldn't save the dose. Open Focus and try again.")
        }
        #endif
        return .result(dialog: "Logged \(dose.kind.shortName) at \(now.formatted(date: .omitted, time: .shortened)).")
    }
}
