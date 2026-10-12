import AppIntents
import FocusCore
import UIKit

/// For Shortcuts personal automations ("When YouTube is opened → Log App"):
/// tells the Mac's activity log which app is in front on this device.
struct LogAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Log App"
    static var description = IntentDescription("Record that an app was opened or closed on this device, for Focus's activity log on the Mac.")
    static var openAppWhenRun = false

    enum Event: String, AppEnum {
        case opened, closed
        static var typeDisplayRepresentation: TypeDisplayRepresentation = "Event"
        static var caseDisplayRepresentations: [Event: DisplayRepresentation] = [.opened: "Opened", .closed: "Closed"]
    }

    @Parameter(title: "App") var app: String
    @Parameter(title: "Event", default: .opened) var event: Event

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$app) \(\.$event)") }

    func perform() async throws -> some IntentResult {
        let device = await UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .result() }
        try? await DeviceActivityCloud.save(DeviceActivity(
            kind: event == .opened ? .open : .close, device: device, app: name, date: Date()
        ))
        return .result()
    }
}
