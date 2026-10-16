import SwiftUI
import SwiftData
import CloudKit
import ReplayKit
import FocusCore

struct SettingsScreen: View {
    @EnvironmentObject var settings: PadSettings
    @EnvironmentObject var engine: FocusTimerEngine
    @Environment(\.modelContext) private var context

    @State private var newTag = ""
    @State private var cloudStatus: String = "checking…"
    @State private var cloudDetail: String = ""
    @State private var exportURL: URL? = nil
    @State private var showExportShare = false
    @State private var manualMinutes: Int = 60
    @State private var manualDate: Date = Date()
    @State private var manualLabel: String = ""
    @State private var manualLogged = false
    @State private var dedupResult: String = ""
    @AppStorage(HealthImport.lastSuccessKey) private var healthLastSuccess: Double = 0
    @AppStorage(HealthImport.lastAttemptKey) private var healthLastAttempt: Double = 0
    @AppStorage(HealthImport.lastResultKey) private var healthLastResult = ""
    @AppStorage(HealthImport.lastErrorKey) private var healthLastError = ""
    @State private var checkingHealth = false

    var body: some View {
        Form {
            Section("Daily Goal") {
                Stepper(value: $settings.dailyGoalHours, in: 1...16) {
                    HStack {
                        Text("Target")
                        Spacer()
                        Text("\(settings.dailyGoalHours)h")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Focus Session") {
                Stepper(value: $settings.workMinutes, in: 5...180, step: 5) {
                    HStack {
                        Text("Default length")
                        Spacer()
                        Text("\(Int(settings.workMinutes))m")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.breakMinutes, in: 5...60, step: 5) {
                    HStack {
                        Text("Default break")
                        Spacer()
                        Text("\(Int(settings.breakMinutes))m")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.pauseGraceMinutes, in: 1...60) {
                    HStack {
                        Text("Pause auto-end after")
                        Spacer()
                        Text("\(settings.pauseGraceMinutes)m")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Auto-start break", isOn: $settings.autoStartBreaks)
                Toggle("Auto-start next focus", isOn: $settings.autoStartWork)
                Toggle("Sound on completion", isOn: $settings.soundEnabled)
            }
            .onChange(of: settings.workMinutes) { _, _ in engine.settings = settings.engineSettings }
            .onChange(of: settings.breakMinutes) { _, _ in engine.settings = settings.engineSettings }
            .onChange(of: settings.autoStartBreaks) { _, _ in engine.settings = settings.engineSettings }
            .onChange(of: settings.autoStartWork) { _, _ in engine.settings = settings.engineSettings }
            .onChange(of: settings.pauseGraceMinutes) { _, _ in engine.settings = settings.engineSettings }

            Section("Focus Tags") {
                ForEach(settings.tags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Button(role: .destructive) {
                            settings.tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { settings.tags.remove(at: i) }
                }
                HStack {
                    TextField("New tag", text: $newTag)
                    Button("Add") {
                        let t = newTag.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty, !settings.tags.contains(t) else { return }
                        settings.tags.append(t)
                        newTag = ""
                    }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Daily Commitment") {
                Toggle("Ask each morning", isOn: $settings.commitmentEnabled)
                if !settings.todayCommitment.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today").font(.caption).foregroundStyle(.secondary)
                        Text(settings.todayCommitment).font(.callout)
                    }
                }
            }

            Section("Sync") {
                Toggle("iCloud Sync (CloudKit)", isOn: $settings.cloudKitSyncEnabled)
                HStack {
                    Text("Status")
                    Spacer()
                    Text(cloudStatus)
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !cloudDetail.isEmpty {
                    Text(cloudDetail).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Haptics.tap()
                    forceSyncProbe()
                } label: {
                    Label("Refresh Sync Status", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("Changes take effect on next launch. Requires iCloud sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { forceSyncProbe() }

            Section("Live Activity") {
                Picker("Show for", selection: Binding(
                    get: { FocusLiveActivity.mode },
                    set: { FocusLiveActivity.mode = $0 }
                )) {
                    ForEach(FocusLiveActivity.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("The Lock Screen card also shows on your Apple Watch. To keep it off the watch only: Watch app → Smart Stack → Live Activities → Focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Apple Health") {
                Toggle("Fill Sleep and Exercise from Health", isOn: Binding(
                    get: { HealthImport.enabled },
                    set: { UserDefaults.standard.set($0, forKey: HealthImport.enabledKey) }
                ))
                Text("Nights of sleep (3h+) and workouts (10 min+) fill time you didn't track. Nothing you tracked is changed.")
                    .font(.caption).foregroundStyle(.secondary)
                if healthLastSuccess > 0 {
                    LabeledContent("Last successful check", value: Date(timeIntervalSince1970: healthLastSuccess).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No successful Health check yet.").font(.caption).foregroundStyle(.secondary)
                }
                if !healthLastError.isEmpty {
                    Text("Couldn't import: \(healthLastError)").font(.caption).foregroundStyle(.orange)
                    if healthLastAttempt > 0 {
                        Text("Last attempted \(Date(timeIntervalSince1970: healthLastAttempt).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if !healthLastResult.isEmpty {
                    Text(healthLastResult).font(.caption).foregroundStyle(.secondary)
                }
                Button(checkingHealth ? "Checking Health…" : "Check now") {
                    Task {
                        checkingHealth = true
                        defer { checkingHealth = false }
                        await HealthImport.run(container: FocusPadApp.sharedContainer, tags: settings.tags,
                                               runningSince: engine.isActive ? engine.sessionStartTime : nil, force: true)
                    }
                }
                .disabled(checkingHealth || !HealthImport.enabled)
            }

            Section("Activity Log on the Mac") {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    HStack {
                        Text("Screen notes")
                        Spacer()
                        BroadcastPickerButton().frame(width: 44, height: 44)
                    }
                    Text("Tap the button and Start Broadcast. Every 15s the screen is read on this iPad and turned into study notes by Apple Intelligence; only the title and notes go to your Mac's activity log. Stop it from the red pill or Control Center.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("App tracking: in Shortcuts → Automation → New → App, pick the apps, choose Is Opened (and another for Is Closed), Run Immediately, then add Focus's \"Log App\" action with the app's name.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Log Manual Session") {
                Stepper(value: $manualMinutes, in: 1...480, step: 5) {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(manualMinutes) min").foregroundStyle(.secondary)
                    }
                }
                DatePicker("Date", selection: $manualDate, in: ...Date(), displayedComponents: .date)
                if !settings.tags.isEmpty {
                    Picker("Tag", selection: $manualLabel) {
                        Text("None").tag("")
                        ForEach(settings.tags, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button {
                    let startTime = Calendar.current.startOfDay(for: manualDate)
                    let session = WorkSession(
                        startTime: startTime,
                        durationMinutes: Double(manualMinutes),
                        type: .work,
                        label: manualLabel.isEmpty ? nil : manualLabel
                    )
                    context.insert(StoredWorkSession(value: session))
                    try? context.save()
                    Haptics.success()
                    manualLogged = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { manualLogged = false }
                } label: {
                    HStack(spacing: 6) {
                        if manualLogged {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Logged!")
                        } else {
                            Image(systemName: "plus.circle.fill")
                            Text("Log \(manualMinutes) min session")
                        }
                    }
                    .foregroundStyle(manualLogged ? FocusColors.goalGreen : FocusColors.focusRed)
                }
            }

            dataSection
            dangerZoneSection

            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Focus for iPad").font(.caption).foregroundStyle(.secondary)
                        Text("v1.0").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    private func forceSyncProbe() {
        cloudStatus = "checking…"
        cloudDetail = ""
        let container = CKContainer(identifier: FocusModelContainer.cloudKitContainerID)
        container.accountStatus { status, error in
            DispatchQueue.main.async {
                if let error {
                    self.cloudStatus = "Error"
                    self.cloudDetail = error.localizedDescription
                    return
                }
                switch status {
                case .available:
                    self.cloudStatus = "Signed in"
                    self.cloudDetail = "Container: \(FocusModelContainer.cloudKitContainerID)\nProbing zone access…"
                    self.probeZoneAccess(container: container)
                case .noAccount:
                    self.cloudStatus = "Not signed in"
                    self.cloudDetail = "Sign into iCloud in Settings → Apple ID."
                case .restricted:
                    self.cloudStatus = "Restricted"
                    self.cloudDetail = "iCloud restricted by parental controls or MDM."
                case .couldNotDetermine:
                    self.cloudStatus = "Unknown"
                    self.cloudDetail = "Couldn't reach iCloud servers."
                case .temporarilyUnavailable:
                    self.cloudStatus = "Temporarily unavailable"
                    self.cloudDetail = "iCloud is unavailable right now."
                @unknown default:
                    self.cloudStatus = "Unknown state"
                }
            }
        }
    }

    /// Talk to the private database directly to surface the real CKError
    /// the server returns. If it says "Invalid bundle ID for container",
    /// CloudKit container isn't associated with this bundle ID at Apple's
    /// developer portal — see SETUP_CLOUDKIT.md.
    private func probeZoneAccess(container: CKContainer) {
        let db = container.privateCloudDatabase
        let op = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        op.fetchRecordZonesResultBlock = { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.cloudStatus = "Working ✓"
                    self.cloudDetail = "Sync is healthy. Changes propagate automatically."
                case .failure(let err):
                    if let ck = err as? CKError {
                        let serverMessage = ck.userInfo["ServerErrorDescription"] as? String ?? ""
                        let code = ck.code.rawValue
                        self.cloudStatus = "Setup needed"
                        if serverMessage.contains("Invalid bundle ID") {
                            self.cloudDetail = "Server: \(serverMessage)\n\nThe CloudKit container isn't associated with this app's bundle ID at Apple Developer Portal. See SETUP_CLOUDKIT.md in the repo for the 1-minute fix."
                        } else if !serverMessage.isEmpty {
                            self.cloudDetail = "Server: \(serverMessage) (code \(code))"
                        } else {
                            self.cloudDetail = "CKError \(code): \(err.localizedDescription)"
                        }
                    } else {
                        self.cloudStatus = "Error"
                        self.cloudDetail = err.localizedDescription
                    }
                }
            }
        }
        db.add(op)
    }

    private var dataSection: some View {
        Section {
            Button {
                do {
                    let url = try DataExport.makeSnapshotURL(context: context)
                    exportURL = url
                    showExportShare = true
                    Haptics.success()
                } catch {
                    Haptics.warning()
                }
            } label: {
                Label("Export Snapshot (JSON)", systemImage: "square.and.arrow.up")
            }
            cleanDuplicatesButton
        } header: {
            Text("Data")
        } footer: {
            Text("Only deletes rows matching another on time-to-the-second, type, label, AND duration. Use if a session shows doubled.")
        }
    }

    private var dangerZoneSection: some View {
        Section("Danger Zone") {
            Button(role: .destructive) { clearAllData() } label: {
                Label("Clear All Local Data", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showExportShare) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
    }

    @ViewBuilder
    private var cleanDuplicatesButton: some View {
        Button {
            let n = FocusMigration.dedupeWorkSessions(container: context.container)
            dedupResult = n == 0
                ? "No exact duplicates found."
                : "Removed \(n) duplicate session\(n == 1 ? "" : "s")."
            Haptics.tap()
        } label: {
            HStack {
                Label("Clean Exact Duplicates", systemImage: "wand.and.sparkles")
                Spacer()
                if !dedupResult.isEmpty {
                    Text(dedupResult)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func clearAllData() {
        let ctx = context
        for s in (try? ctx.fetch(FetchDescriptor<StoredWorkSession>())) ?? [] { ctx.delete(s) }
        for p in (try? ctx.fetch(FetchDescriptor<StoredProblem>())) ?? [] { ctx.delete(p) }
        for h in (try? ctx.fetch(FetchDescriptor<StoredHomework>())) ?? [] { ctx.delete(h) }
        for d in (try? ctx.fetch(FetchDescriptor<StoredDayRecord>())) ?? [] { ctx.delete(d) }
        for i in (try? ctx.fetch(FetchDescriptor<StoredScratchItem>())) ?? [] { ctx.delete(i) }
        try? ctx.save()
    }
}

/// System picker that starts the Focus screen-notes broadcast.
private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = "com.magnus.focus.iPad.broadcast"
        v.showsMicrophoneButton = false
        return v
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
