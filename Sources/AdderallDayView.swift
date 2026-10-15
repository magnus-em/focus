import SwiftUI
import FocusCore

struct AdderallDayView: View {
    @ObservedObject var store: HealthStore
    var preview = false
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var doseTime = Date()
    @State private var kind: HealthKind = .adderallIR10
    @State private var justLogged: UUID?
    @State private var editing: HealthEvent?

    private var doses: [HealthEvent] {
        if preview { return previewDoses(on: day) }
        return store.doses(on: day)
    }
    private var today: Bool { Calendar.current.isDateInToday(day) }
    private var total: Int { doses.map(\.kind.amount).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                    .help("Previous day").accessibilityLabel("Previous day")
                Spacer()
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().accessibilityLabel("Dose history day")
                Spacer()
                Button { moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                    .disabled(today).help("Next day").accessibilityLabel("Next day")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(today ? "Adderall today" : "Adderall that day").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(total) mg").font(.system(size: 26, weight: .semibold).monospacedDigit())
                }
                if let first = doses.first {
                    if today {
                        TimelineView(.everyMinute) { context in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(durationText(minutes: max(0, context.date.timeIntervalSince(first.date) / 60).rounded(.down))) since first dose")
                                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                                Text("Started at \(time(first.date)) · \(first.kind.displayName)")
                                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            }
                        }
                    } else {
                        Text("First dose at \(time(first.date))").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    }
                    if doses.count > 1, let latest = doses.last {
                        Text("Latest: \(latest.kind.displayName) at \(time(latest.date))")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                } else {
                    Text(today ? "Log when you took it to start today's clock." : "No doses logged for this day.")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                }
            }
            .padding(16).contentCard()

            VStack(alignment: .leading, spacing: 12) {
                Text("Log a dose").font(.system(size: 15, weight: .semibold))
                Picker("Dose", selection: $kind) {
                    ForEach(HealthTracker.adderall.kinds) { Text($0.displayName).tag($0) }
                }
                DatePicker("Taken at", selection: $doseTime, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Text("Use the time you actually took it. The morning clock starts there, even if you log it later.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                Button("Log \(kind.displayName) at \(time(doseTime))") {
                    guard !preview else { return }
                    justLogged = store.log(kind, at: doseTime)
                    if justLogged != nil { day = Calendar.current.startOfDay(for: doseTime) }
                }
                .buttonStyle(.bordered).controlSize(.large)
                if let id = justLogged {
                    HStack {
                        Label("Dose logged", systemImage: "checkmark.circle")
                        Spacer()
                        Button("Undo") { if !preview { store.delete(id: id); justLogged = nil } }
                    }
                    .font(.system(size: 13))
                }
                if let error = store.saveError {
                    Text("Couldn't save: \(error)").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 13))
            .padding(16).contentCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("Dose times").font(.system(size: 15, weight: .semibold))
                if doses.isEmpty {
                    Text("Nothing logged.").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                }
                ForEach(doses) { dose in
                    HStack(spacing: 8) {
                        Text(time(dose.date)).monospacedDigit()
                        Spacer()
                        Text(dose.kind.displayName)
                        Button { editing = dose } label: {
                            Image(systemName: "pencil").frame(width: 36, height: 36)
                        }
                        .help("Edit dose or time").accessibilityLabel("Edit \(dose.kind.displayName) taken at \(time(dose.date))")
                    }
                    .font(.system(size: 13)).buttonStyle(.plain)
                }
            }
            .padding(16).contentCard()

            VStack(alignment: .leading, spacing: 12) {
                Text("Day by day").font(.system(size: 15, weight: .semibold))
                ForEach(0..<7, id: \.self) { back in
                    if let date = Calendar.current.date(byAdding: .day, value: -back, to: Calendar.current.startOfDay(for: Date())) {
                        let entries = preview ? previewDoses(on: date) : store.doses(on: date)
                        Button { day = date } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    Spacer()
                                    Text("\(entries.map(\.kind.amount).reduce(0, +)) mg").fontWeight(.semibold)
                                }
                                Text(entries.isEmpty ? "Nothing logged" : entries.map { "\($0.kind.displayName) at \(time($0.date))" }.joined(separator: " · "))
                                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .font(.system(size: 13)).buttonStyle(.plain)
                    }
                }
            }
            .padding(16).contentCard()
        }
        .onAppear {
            if !preview, let latest = store.events(.adderall).first { kind = latest.kind }
        }
        .onChange(of: day) { _, newDay in
            let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
            doseTime = min(Date(), Calendar.current.date(bySettingHour: components.hour ?? 8, minute: components.minute ?? 0, second: 0, of: newDay) ?? newDay)
        }
        .sheet(item: $editing) { dose in
            DoseEditView(store: store, dose: dose, preview: preview)
        }
    }

    private func moveDay(_ offset: Int) {
        if let date = Calendar.current.date(byAdding: .day, value: offset, to: day) { day = date }
    }
    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private func previewDoses(on date: Date) -> [HealthEvent] {
        let morning = Calendar.current.date(bySettingHour: 8, minute: 15, second: 0, of: date)!
        return [HealthEvent(id: UUID(), date: morning, kind: .adderallXR20)]
    }
}

private struct DoseEditView: View {
    @ObservedObject var store: HealthStore
    let dose: HealthEvent
    let preview: Bool
    @State private var kind: HealthKind
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(store: HealthStore, dose: HealthEvent, preview: Bool) {
        self.store = store; self.dose = dose; self.preview = preview
        _kind = State(initialValue: dose.kind); _date = State(initialValue: dose.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit dose").font(.system(size: 15, weight: .semibold))
            Picker("Dose", selection: $kind) {
                ForEach(HealthTracker.adderall.kinds) { Text($0.displayName).tag($0) }
            }
            DatePicker("Taken at", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            if let error = store.saveError { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Delete dose", role: .destructive) { if !preview { store.delete(id: dose.id); if store.saveError == nil { dismiss() } } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { if !preview, store.update(id: dose.id, kind: kind, at: date) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13)).padding(24).frame(width: 420)
    }
}
