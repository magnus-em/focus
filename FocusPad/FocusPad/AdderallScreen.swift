import SwiftUI
import SwiftData
import FocusCore

/// Log doses and see the time since today's first one. Same records as the
/// Mac's Health → Adderall (synced); the widgets read a copy (`DoseMirror`).
struct AdderallScreen: View {
    @Query(sort: \StoredHealthEvent.date, order: .reverse) private var events: [StoredHealthEvent]
    @State private var kind: HealthKind = .adderallIR20
    @State private var takenAt = Date()
    @State private var justLogged: UUID?
    @State private var saveFailed = false
    @State private var editing: StoredHealthEvent?

    private var doses: [StoredHealthEvent] {
        events.filter { HealthKind(rawValue: $0.kind)?.tracker == .adderall }
    }

    private func doses(on day: Date, now: Date = Date()) -> [StoredHealthEvent] {
        doses.filter { Calendar.current.isDate($0.date, inSameDayAs: day) && $0.date <= now }.reversed()
    }

    var body: some View {
        let today = doses(on: Date())
        List {
            Section { clock(today) }
            logSection
            Section("Doses today") {
                if today.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                }
                ForEach(today) { dose in
                    Button { editing = dose } label: { doseRow(dose) }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { DoseLog.delete(id: dose.id) }
                        }
                }
            }
            Section("Last 7 days") { week }
            Section {
                Label("Add the Adderall clock to your Lock Screen or Home Screen: touch and hold it, tap Customize or Edit, then pick Focus. The Log Adderall control logs a dose from the Lock Screen or Control Center.",
                      systemImage: "lock.iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Adderall")
        .onAppear {
            takenAt = Date()
            if let last = doses.first.flatMap({ HealthKind(rawValue: $0.kind) }) { kind = last }
            DoseMirror.update()
        }
        .sheet(item: $editing) { dose in
            DoseEditSheet(dose: dose)
        }
    }

    @ViewBuilder
    private func clock(_ today: [StoredHealthEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.headline)
                Spacer()
                Text("\(today.compactMap { HealthKind(rawValue: $0.kind)?.amount }.reduce(0, +)) mg")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            if let first = today.first {
                Text(timerInterval: first.date...Date.distantFuture, countsDown: false)
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                Text("since first dose at \(time(first.date)) · \(name(first))")
                    .font(.subheadline).foregroundStyle(.secondary)
                if today.count > 1, let latest = today.last {
                    Text("Latest: \(name(latest)) at \(time(latest.date))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("No dose yet today").font(.title2.weight(.semibold))
                Text("Log when you took it to start today's clock.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var logSection: some View {
        Section {
            Picker("Dose", selection: $kind) {
                ForEach(HealthTracker.adderall.kinds) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            DatePicker("Taken at", selection: $takenAt, in: ...Date().addingTimeInterval(60),
                       displayedComponents: [.date, .hourAndMinute])
            Button {
                saveFailed = false
                justLogged = DoseLog.log(kind, at: min(takenAt, Date()))
                saveFailed = justLogged == nil
                takenAt = Date()
            } label: {
                Text("Log \(kind.shortName) at \(time(min(takenAt, Date())))")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if let id = justLogged {
                HStack {
                    Label("Dose logged", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Undo") { DoseLog.delete(id: id); justLogged = nil }
                }
            }
            if saveFailed {
                Text("Couldn't save. Try again.").foregroundStyle(.orange)
            }
        } header: {
            Text("Log a dose")
        } footer: {
            Text("Use the time you actually took it. Today's clock starts at the first dose, even if you log it later.")
        }
    }

    private var week: some View {
        ForEach(0..<7, id: \.self) { back in
            if let day = Calendar.current.date(byAdding: .day, value: -back, to: Calendar.current.startOfDay(for: Date())) {
                let list = doses(on: day)
                HStack {
                    Text(back == 0 ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    Spacer()
                    if let first = list.first {
                        Text("\(time(first.date)) · \(list.compactMap { HealthKind(rawValue: $0.kind)?.amount }.reduce(0, +)) mg")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("None").foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func doseRow(_ dose: StoredHealthEvent) -> some View {
        HStack {
            Text(time(dose.date)).monospacedDigit()
            Spacer()
            Text(name(dose)).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private func name(_ dose: StoredHealthEvent) -> String { HealthKind(rawValue: dose.kind)?.displayName ?? dose.kind }
    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

private struct DoseEditSheet: View {
    let dose: StoredHealthEvent
    @Environment(\.dismiss) private var dismiss
    @State private var kind: HealthKind = .adderallIR20
    @State private var takenAt = Date()

    var body: some View {
        NavigationStack {
            Form {
                Picker("Dose", selection: $kind) {
                    ForEach(HealthTracker.adderall.kinds) { Text($0.displayName).tag($0) }
                }
                DatePicker("Taken at", selection: $takenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Section {
                    Button("Delete dose", role: .destructive) {
                        DoseLog.delete(id: dose.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        DoseLog.update(id: dose.id, kind: kind, at: takenAt)
                        dismiss()
                    }
                }
            }
            .onAppear {
                kind = HealthKind(rawValue: dose.kind) ?? .adderallIR20
                takenAt = dose.date
            }
        }
        .presentationDetents([.medium])
    }
}
