import AppIntents
import SwiftUI
import WidgetKit
import FocusCore

private let doseOrange = Color(red: 0.95, green: 0.55, blue: 0.2)

struct DoseEntry: TimelineEntry {
    let date: Date
    let doses: [DoseMirror.Dose]

    var first: DoseMirror.Dose? { doses.first }
    var later: DoseMirror.Dose? { doses.count > 1 ? doses.last : nil }
    var totalMG: Int { doses.compactMap { $0.healthKind?.amount }.reduce(0, +) }
}

struct DoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoseEntry {
        DoseEntry(date: Date(), doses: [.init(date: Date().addingTimeInterval(-8040), kind: HealthKind.adderallXR20.rawValue)])
    }

    func getSnapshot(in context: Context, completion: @escaping (DoseEntry) -> Void) {
        let entry = DoseEntry(date: Date(), doses: DoseMirror.doses(on: Date()))
        completion(context.isPreview && entry.doses.isEmpty ? placeholder(in: context) : entry)
    }

    /// Today's doses now, then an empty day from midnight. The clock itself
    /// ticks on its own (`Text(timerInterval:)`); the app reloads this when
    /// a dose is logged here or arrives from the Mac.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoseEntry>) -> Void) {
        let now = Date()
        let all = DoseMirror.read()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400 + 60)
        var entries = [DoseEntry(date: now, doses: DoseMirror.doses(on: now, from: all, now: now))]
        // A dose logged ahead of time (rare) starts the clock when it's due.
        for dose in all where dose.date > now && dose.date < midnight {
            entries.append(DoseEntry(date: dose.date, doses: DoseMirror.doses(on: now, from: all, now: dose.date)))
        }
        entries.append(DoseEntry(date: midnight, doses: []))
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }
}

struct DoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DoseMirror.widgetKind, provider: DoseProvider()) { entry in
            DoseWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
                .widgetURL(URL(string: "focus://adderall"))
        }
        .configurationDisplayName("Adderall clock")
        .description("Time since today's first dose.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .systemSmall, .systemMedium])
    }
}

private struct DoseWidgetView: View {
    let entry: DoseEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private func clock(_ dose: DoseMirror.Dose) -> Text {
        Text(timerInterval: dose.date...Date.distantFuture, countsDown: false)
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private var detail: String {
        guard let first = entry.first else { return "" }
        return "since \(time(first.date)) · \(first.healthKind?.shortName ?? "")"
    }

    private var inline: some View {
        Group {
            if let first = entry.first {
                Label { clock(first) } icon: { Image(systemName: "pills.fill") }
            } else {
                Label("No dose today", systemImage: "pills")
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: entry.first == nil ? "pills" : "pills.fill")
                    .font(.system(size: 13, weight: .semibold))
                if let first = entry.first {
                    clock(first)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("—").font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 4)
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Adderall", systemImage: "pills.fill")
                .font(.system(size: 13, weight: .semibold))
                .widgetAccentable()
            if let first = entry.first {
                clock(first)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                Text(laterLine ?? detail)
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Text("No dose today").font(.system(size: 17, weight: .semibold))
                Text("Tap to log").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var laterLine: String? {
        guard let later = entry.later else { return nil }
        return "+ \(later.healthKind?.shortName ?? "dose") at \(time(later.date))"
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Adderall", systemImage: "pills.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(doseOrange)
            Spacer(minLength: 0)
            if let first = entry.first {
                clock(first)
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("since first dose").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(time(first.date)) · \(first.healthKind?.shortName ?? "")")
                    .font(.system(size: 12, weight: .medium))
                if let line = laterLine {
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("No dose yet today").font(.system(size: 17, weight: .semibold))
                Text(family == .systemMedium ? "Tap a dose when you take it." : "Tap to log one.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var small: some View { summary }

    private var medium: some View {
        HStack(spacing: 12) {
            summary
            VStack(spacing: 6) {
                ForEach([AdderallDose.ir10, .ir20, .xr20], id: \.self) { dose in
                    Button(intent: LogDoseIntent(dose: dose)) {
                        Text(dose.kind.shortName)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(doseOrange)
                }
                Text("Logs it as taken now").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 112)
        }
    }
}

// MARK: - Control Center / Lock Screen / Action Button

struct DoseControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Dose"
    @Parameter(title: "Dose") var dose: AdderallDose?
}

struct LogDoseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.magnus.focus.dose.log", intent: DoseControlConfiguration.self) { config in
            let dose = config.dose ?? .ir20
            ControlWidgetButton(action: LogDoseIntent(dose: dose)) {
                Label("Took \(dose.kind.shortName)", systemImage: "pills.fill")
            }
            .tint(doseOrange)
        }
        .displayName("Log Adderall")
        .description("Log a dose taken now. Pick which dose this button logs.")
        .promptsForUserConfiguration()
    }
}
