import SwiftUI
import CloudKit
import FocusCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var timer: TimerManager
    @ObservedObject var store: SessionStore
    @ObservedObject private var bridge = BrowserBridge.shared
    var openOnboarding: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var showResetConfirm = false
    @State private var newSourceText = ""
    @State private var cloudStatus: String = "checking…"
    @State private var cloudDetail: String = ""
    @State private var cloudStatusColor: Color = .secondary

    // Manual session logging
    @State private var manualMinutes: Int = 60
    @State private var manualDate: Date = Date()
    @State private var manualLabel: String = ""
    @State private var manualLogged = false
    @State private var dedupResult: String = ""
    @State private var claudeKey = ""
    @State private var claudeKeySet = RecallCoach.isConfigured

    private func timeBinding(_ key: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = settings[keyPath: key]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                settings[keyPath: key] = (c.hour ?? 21) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var chromeExtensionRow: some View {
        let connected = bridge.lastContact.map { Date().timeIntervalSince($0) < 120 } ?? false
        return HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(bridge.listenError.map { "Chrome bridge failed: \($0)" }
                 ?? (connected ? "Chrome extension connected" : "Chrome extension not connected"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .help("Load the repo's ChromeExtension folder via chrome://extensions → Developer mode → Load unpacked.")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                if let openOnboarding {
                    Button { openOnboarding() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 11))
                            Text("Show welcome tour").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)

                    Divider()
                }

                SectionLabel("INTERVALS")
                IntervalRow(label: "Focus", value: $settings.workMinutes, range: 5...90, step: 5, unit: "min")

                Divider()

                SectionLabel("DAILY GOAL")
                IntRow(label: "Daily Target", value: $settings.dailyGoal, range: 0...12, suffix: "h", zeroLabel: "Off")

                Divider()

                SectionLabel("CATEGORIES")
                CategoriesEditor(settings: settings, store: store)

                Divider()

                SectionLabel("ICLOUD SYNC")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(cloudStatusColor).frame(width: 8, height: 8)
                        Text(cloudStatus)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button { probeSync() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    if !cloudDetail.isEmpty {
                        Text(cloudDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    SyncHealthRows()
                    Text("Container: \(FocusModelContainer.cloudKitContainerID)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(7)
                .onAppear { probeSync() }

                Divider()

                SectionLabel("COMMITMENT")
                ToggleRow(label: "Daily commitment prompt", isOn: $settings.commitmentEnabled)
                if settings.commitmentEnabled {
                    Text("You'll be prompted each morning to write your commitment for the day.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ToggleRow(label: "Evening check-in", isOn: $settings.commitmentReviewReminder)
                    if settings.commitmentReviewReminder {
                        HStack {
                            Text("Remind me at")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            DatePicker("", selection: timeBinding(\.commitmentReviewMinutes), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .fixedSize()
                        }
                        Text("A notification asks whether you kept today's commitment. Answer Yes/No right from the banner.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                SectionLabel("SCREEN")
                ScreenSettings(settings: settings)

                Divider()

                SectionLabel("FOCUS MODES")
                FocusModeSettings(tags: settings.tags)

                Divider()

                SectionLabel("AWAY & GAPS")
                ToggleRow(label: "Ask when I come back", isOn: $settings.awayPrompts)
                if settings.awayPrompts {
                    IntRow(label: "After being away", value: $settings.awayPromptMinutes, range: 5...120, suffix: "min")
                }
                ToggleRow(label: "Nudge when nothing's running", isOn: $settings.idleNudge)
                Text("Away = screen locked, display off, Mac asleep, or no keyboard/mouse for 10 min. A card asks what that time was; nothing changes unless you pick something.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                SectionLabel("RECALL")
                ToggleRow(label: "Recall prompt after focus", isOn: $settings.recallAfterSession)
                if settings.recallAfterSession {
                    IntRow(label: "For blocks of at least", value: $settings.recallMinMinutes, range: 5...120, suffix: "min")
                }
                ToggleRow(label: "Morning review of yesterday", isOn: $settings.morningRecall)
                if settings.morningRecall {
                    HStack(spacing: 6) {
                        Text("Send to Journal via shortcut").font(.system(size: 12))
                        Spacer()
                        TextField("off", text: $settings.journalShortcut)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 120)
                    }
                }
                IntRow(label: "Max reviews per day", value: $settings.recallDailyCap, range: 3...60)
                Text("After a focus block, write what you learned from memory. Cards come back after 1, 3, 7, 14, 30 days. ⌃⌥⌘; opens Recall.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    SecureField(claudeKeySet ? "Claude API key saved" : "Claude API key (optional)", text: $claudeKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button(claudeKey.isEmpty && claudeKeySet ? "Remove" : "Save") {
                        RecallCoach.setAPIKey(claudeKey.isEmpty ? nil : claudeKey)
                        claudeKey = ""
                        claudeKeySet = RecallCoach.isConfigured
                    }
                    .controlSize(.small)
                    .disabled(claudeKey.isEmpty && !claudeKeySet)
                }
                Text("With a key, Claude checks your recall, drafts cards, grades answers and gives hints. Stored in the Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                SectionLabel("LEETCODE")
                ToggleRow(label: "Evening nudge if under goal", isOn: $settings.leetCodeNudge)
                if settings.leetCodeNudge {
                    HStack {
                        Text("Nudge at")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        DatePicker("", selection: timeBinding(\.leetCodeNudgeMinutes), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .fixedSize()
                    }
                    Text("Only fires if you're below today's SWE problem goal — and warns when your streak is on the line.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                SectionLabel("BEHAVIOR")
                ToggleRow(label: "Auto-break after session", isOn: $settings.autoBreakEnabled)
                ToggleRow(label: "Auto-start focus", isOn: $settings.autoStartWork)
                ToggleRow(label: "Sound effects", isOn: $settings.soundEnabled)
                IntRow(label: "Auto-end pause after", value: $settings.pauseGraceMinutes, range: 2...60, suffix: "min")

                HStack {
                    Text("Quick start / stop")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: $settings.quickStartTag) {
                        ForEach(settings.tags, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Text("⌃⌥⌘K")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }

                Text("⌃⌥⌘J switcher · ⌃⌥⌘U I O P M , . / switch category · ⌃⌥⌘L break · ⌃⌥⌘0 stop · ⌃⌥⌘; recall")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack {
                    Text("Pause / resume hotkey")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⌃⌥⌘Space")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }

                Divider()

                SectionLabel("SITE BLOCKING")
                ToggleRow(label: "Block distracting sites", isOn: $settings.siteBlockingEnabled)

                if settings.siteBlockingEnabled {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SiteBlocker.isSetUp ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(SiteBlocker.isSetUp ? "Helper installed" : "Helper not installed — tap to set up")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !SiteBlocker.isSetUp {
                            Button("Set Up") {
                                DispatchQueue.global(qos: .userInitiated).async { SiteBlocker.setUp() }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
                            .buttonStyle(.plain)
                        } else {
                            Button("Re-install") {
                                DispatchQueue.global(qos: .userInitiated).async { SiteBlocker.setUp() }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .buttonStyle(.plain)
                        }
                    }
                    chromeExtensionRow
                    ToggleRow(label: "Block during breaks too", isOn: $settings.blockDuringBreaks)
                    BlockedSitesView(settings: settings)
                        .padding(.top, 2)
                }

                Divider()

                SectionLabel("INTERVIEW")

                if let date = settings.interviewDate {
                    HStack {
                        Text("Target date")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        DatePicker(
                            "",
                            selection: Binding(get: { date }, set: { settings.interviewDate = $0 }),
                            in: Date()...,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .controlSize(.small)

                        Button {
                            settings.interviewDate = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button {
                        // Default to 4 months from now
                        settings.interviewDate = Calendar.current.date(byAdding: .month, value: 4, to: Date())
                    } label: {
                        HStack {
                            Image(systemName: "calendar.badge.plus")
                            Text("Set interview date")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                SectionLabel("PRACTICE MODE")
                PracticeNewCapRow()

                Divider()

                SectionLabel("PROBLEM GOALS")
                HStack {
                    Spacer()
                    Text("Daily").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(width: 72, alignment: .trailing)
                    Text("Weekly").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(width: 72, alignment: .trailing)
                }
                ProblemGoalRow(label: "Quant", daily: $settings.quantGoal, weekly: $settings.quantWeeklyGoal)
                ProblemGoalRow(label: "SWE", daily: $settings.sweGoal, weekly: $settings.sweWeeklyGoal)
                HStack {
                    Text("Homework").font(.system(size: 12, weight: .medium))
                    Spacer()
                    InlineIntField(value: $settings.homeworkDailyGoal).frame(width: 72)
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 72, alignment: .trailing)
                }

                Divider()

                SectionLabel("PROBLEM SOURCES")

                VStack(spacing: 5) {
                    ForEach(settings.problemSources, id: \.self) { source in
                        HStack {
                            Text(source)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button {
                                settings.problemSources.removeAll { $0 == source }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("New source…", text: $newSourceText)
                            .font(.system(size: 12))
                            .textFieldStyle(.plain)
                            .onSubmit { addSource() }
                        if !newSourceText.isEmpty {
                            Button("Add") { addSource() }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(7)
                }

                Divider()

                SectionLabel("LOG MANUAL SESSION")

                VStack(spacing: 10) {
                    IntRow(label: "Duration", value: $manualMinutes, range: 1...480, suffix: "min")

                    HStack {
                        Text("Date")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        DatePicker("", selection: $manualDate, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                            .controlSize(.small)
                    }

                    if !settings.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Label (optional)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    let noneSelected = manualLabel.isEmpty
                                    Button("None") { manualLabel = "" }
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(noneSelected ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.07))
                                        .foregroundStyle(noneSelected ? .primary : .secondary)
                                        .cornerRadius(6)
                                        .buttonStyle(.plain)
                                    ForEach(settings.tags, id: \.self) { tag in
                                        let sel = manualLabel == tag
                                        Button(tag) { manualLabel = sel ? "" : tag }
                                            .font(.system(size: 10, weight: .medium))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(sel ? Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.15) : Color.secondary.opacity(0.07))
                                            .foregroundStyle(sel ? Color(red: 0.96, green: 0.36, blue: 0.36) : Color.secondary)
                                            .cornerRadius(6)
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
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
                        store.addSession(session)
                        manualLogged = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { manualLogged = false }
                    } label: {
                        HStack(spacing: 6) {
                            if manualLogged {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Logged!")
                                    .font(.system(size: 12, weight: .semibold))
                            } else {
                                Text("Log \(manualMinutes) min session")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(manualLogged ? Color.green.opacity(0.15) : Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.12))
                        .foregroundStyle(manualLogged ? Color.green : Color(red: 0.96, green: 0.36, blue: 0.36))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(manualLogged ? Color.green.opacity(0.3) : Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: manualLogged)
                }

                Divider()

                SectionLabel("DATA")
                Button {
                    DataExport.showSavePanel(container: modelContext.container)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Export Snapshot (JSON)").font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)

                Button {
                    let n = FocusMigration.dedupeWorkSessions(container: modelContext.container)
                    dedupResult = n == 0
                        ? "No exact duplicates found."
                        : "Removed \(n) duplicate session\(n == 1 ? "" : "s")."
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Clean Exact Duplicates").font(.system(size: 12, weight: .medium))
                        Spacer()
                        if !dedupResult.isEmpty {
                            Text(dedupResult)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                Text("Removes only rows matching another row on time-to-the-second, type, label, AND duration. Use if Mac/iPad show a doubled session.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)

                Divider()

                if showResetConfirm {
                    VStack(spacing: 8) {
                        Text("Delete all session history?")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                        Text("This cannot be undone.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                showResetConfirm = false
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(.secondary.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.clearAllData()
                                showResetConfirm = false
                            } label: {
                                Text("Reset")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.85))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(.secondary.opacity(0.05))
                    .cornerRadius(8)
                } else {
                    HStack {
                        Spacer()
                        Button { showResetConfirm = true } label: {
                            Text("Reset All Data")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.8))
                        Spacer()
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
        }
        .onChange(of: settings.workMinutes)       { _, _ in timer.applySettings() }
        .onChange(of: settings.shortBreakMinutes) { _, _ in timer.applySettings() }
    }

    private func addSource() {
        let t = newSourceText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !settings.problemSources.contains(t) else { newSourceText = ""; return }
        settings.problemSources.append(t)
        newSourceText = ""
    }

    // MARK: - iCloud probe

    private func probeSync() {
        cloudStatus = "checking…"
        cloudDetail = ""
        cloudStatusColor = .secondary
        let container = CKContainer(identifier: FocusModelContainer.cloudKitContainerID)
        container.accountStatus { status, error in
            DispatchQueue.main.async {
                if let error {
                    cloudStatus = "Error"
                    cloudStatusColor = .red
                    cloudDetail = error.localizedDescription
                    return
                }
                switch status {
                case .available:
                    probeZoneAccess(container: container)
                case .noAccount:
                    cloudStatus = "Not signed in to iCloud"
                    cloudStatusColor = .orange
                    cloudDetail = "Sign into iCloud in System Settings → Apple Account."
                case .restricted:
                    cloudStatus = "Restricted"
                    cloudStatusColor = .red
                    cloudDetail = "iCloud restricted by parental controls or MDM."
                case .couldNotDetermine:
                    cloudStatus = "Unknown"
                    cloudStatusColor = .orange
                    cloudDetail = "Couldn't reach iCloud servers."
                case .temporarilyUnavailable:
                    cloudStatus = "Temporarily unavailable"
                    cloudStatusColor = .orange
                default:
                    cloudStatus = "Unknown"
                    cloudStatusColor = .orange
                }
            }
        }
    }

    private func probeZoneAccess(container: CKContainer) {
        let db = container.privateCloudDatabase
        let op = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        op.fetchRecordZonesResultBlock = { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    cloudStatus = "iCloud account reachable"
                    cloudStatusColor = .green
                case .failure(let err):
                    if let ck = err as? CKError {
                        let serverMessage = ck.userInfo["ServerErrorDescription"] as? String ?? ""
                        let code = ck.code.rawValue
                        cloudStatusColor = .orange
                        if serverMessage.contains("Invalid bundle ID") {
                            cloudStatus = "Setup needed"
                            cloudDetail = "Server: \(serverMessage)\n\nThe CloudKit container isn't associated with this app's bundle ID at Apple Developer Portal. See SETUP_CLOUDKIT.md."
                        } else if !serverMessage.isEmpty {
                            cloudStatus = "Error"
                            cloudDetail = "Server: \(serverMessage) (code \(code))"
                        } else {
                            cloudStatus = "Error"
                            cloudDetail = "CKError \(code): \(err.localizedDescription)"
                        }
                    } else {
                        cloudStatus = "Error"
                        cloudStatusColor = .red
                        cloudDetail = err.localizedDescription
                    }
                }
            }
        }
        db.add(op)
    }
}

// MARK: - Subviews

/// Health of the actual CloudKit mirror (from its event stream) plus the
/// latest local backup. Separate from the account probe above, which can
/// pass while the mirror is failing.
struct SyncHealthRows: View {
    @ObservedObject private var monitor = CloudSyncMonitor.shared

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            row("Last download", s.lastImport)
            row("Last upload", s.lastExport)
            if monitor.health == .failing, let msg = s.lastErrorMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            row("Last backup", StoreBackup.latest?.date)
        }
        .padding(.top, 2)
    }

    private var title: String {
        switch monitor.health {
        case .healthy: return "Syncing"
        case .stale: return "No sync activity in 3+ days"
        case .failing: return "Sync failing"
        case .unknown: return "Waiting for first sync…"
        }
    }

    private var color: Color {
        switch monitor.health {
        case .healthy: return .green
        case .stale: return .orange
        case .failing: return .red
        case .unknown: return .secondary
        }
    }

    private func row(_ label: String, _ date: Date?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(date.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.secondary)
    }
}

private struct IntervalRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 36)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .onAppear { text = "\(Int(value))" }
        .onChange(of: value) { _, _ in text = "\(Int(value))" }
    }

    private func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
        text = "\(Int(value))"
    }
}

private struct IntRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    var zeroLabel: String? = nil

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: suffix.isEmpty ? 44 : 40)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                if !suffix.isEmpty {
                    Text(suffix).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, _ in text = "\(value)" }
    }

    private func commit() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
        text = "\(value)"
    }
}

private struct ProblemGoalRow: View {
    let label: String
    @Binding var daily: Int
    @Binding var weekly: Int

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            InlineIntField(value: $daily).frame(width: 72)
            InlineIntField(value: $weekly).frame(width: 72)
        }
    }
}

private struct InlineIntField: View {
    @Binding var value: Int
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("0", text: $text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            Text("probs").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, _ in text = "\(value)" }
    }

    private func commit() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = max(0, v)
        }
        text = "\(value)"
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(.system(size: 12, weight: .medium))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Daily-new-problem cap stepper for Practice Mode. Persisted via the
/// same @AppStorage key the idle screen reads (`practice.dailyNewCap`).
private struct PracticeNewCapRow: View {
    @AppStorage("practice.dailyNewCap") private var cap: Int = 5

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New problems per day").font(.system(size: 12, weight: .medium))
                Text("Cap on fresh familiarizations. Reviews don't count toward this.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Stepper(value: $cap, in: 1...20) {
                Text("\(cap)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 24, alignment: .trailing)
            }
            .controlSize(.small)
            .labelsHidden()
        }
    }
}

/// Order sets the ⌃⌥⌘ category hotkeys (U I O P M , . / …); Life categories are tracked but don't count toward the goal.
private struct CategoriesEditor: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: SessionStore
    @State private var newTag = ""

    var body: some View {
        let lifetime = Dictionary(store.minutesByTag(includeLife: true).map { ($0.tag, $0.minutes) },
                                  uniquingKeysWith: +)
        VStack(spacing: 4) {
            ForEach(Array(settings.tags.enumerated()), id: \.element) { i, tag in
                let isLife = settings.lifeTags.contains(tag)
                HStack(spacing: 8) {
                    Text(i < 9 ? "\(i + 1)" : "")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Circle().fill(categoryColor(tag)).frame(width: 7, height: 7)
                    Text(tag).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(hours(lifetime[tag] ?? 0))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Picker("", selection: Binding(
                        get: { isLife },
                        set: { life in
                            if life { if !isLife { settings.lifeTags.append(tag) } }
                            else { settings.lifeTags.removeAll { $0 == tag } }
                        }
                    )) {
                        Text("Focus").tag(false)
                        Text("Life").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Focus counts toward the daily goal; Life is tracked only")
                    Button {
                        guard i > 0 else { return }
                        settings.tags.swapAt(i, i - 1)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(i > 0 ? Color.secondary : Color.clear)
                    .disabled(i == 0)
                    .help("Move up (changes its hotkey number)")
                    Button {
                        settings.tags.removeAll { $0 == tag }
                        settings.lifeTags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove category (past sessions keep their label)")
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                TextField("New category…", text: $newTag)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .onSubmit(add)
                if !newTag.isEmpty {
                    Button("Add", action: add)
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(7)
            .padding(.top, 4)
        }
    }

    private func add() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        newTag = ""
        guard !t.isEmpty, !settings.tags.contains(t) else { return }
        settings.tags.append(t)
    }

    private func hours(_ m: Double) -> String {
        m >= 60 ? "\(Int(m / 60))h" : m > 0 ? "\(Int(m))m" : ""
    }
}

private struct ScreenSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var watcher = ScreenWatcher.shared
    @ObservedObject private var calendar = ClassCalendar.shared

    var body: some View {
        ToggleRow(label: "Watch what's on screen", isOn: $settings.screenWatch)
        if settings.screenWatch {
            ToggleRow(label: "Suggest switching categories", isOn: $settings.screenSuggest)
            if settings.screenSuggest {
                IntRow(label: "After the screen shows it for", value: $settings.screenSuggestMinutes, range: 1...20, suffix: "min")
                ToggleRow(label: "Switch focus categories on its own for windows I've labeled", isOn: $settings.screenAutoSwitch)
            }
            HStack(spacing: 6) {
                Text(watcher.status).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if watcher.status.hasPrefix("Needs") {
                    Button("Grant…") { watcher.requestPermission() }.controlSize(.small)
                }
            }
            Text("Classes: \(calendar.status)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let accepted = UserDefaults.standard.integer(forKey: ScreenCoach.acceptedKey)
            let declined = UserDefaults.standard.integer(forKey: ScreenCoach.declinedKey)
            if accepted + declined > 0 {
                Text("Suggestions accepted: \(accepted) of \(accepted + declined)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            let ignored = ScreenWatcher.userIgnored.sorted { $0.value < $1.value }
            HStack {
                Text(ignored.isEmpty ? "Ignored apps: none" : "Ignored apps: " + ignored.map(\.value).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Menu("Edit") {
                    ForEach(watcher.recentApps(), id: \.bundle) { a in
                        let on = ScreenWatcher.userIgnored[a.bundle] != nil
                        Button((on ? "✓ " : "") + a.name) { watcher.setIgnored(a.bundle, name: a.name, !on) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            HStack {
                Text("Prompt log: each card, what it was based on, your answer")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    if FileManager.default.fileExists(atPath: PromptLog.url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([PromptLog.url])
                    } else {
                        NSWorkspace.shared.open(PromptLog.url.deletingLastPathComponent())
                    }
                }.controlSize(.small)
            }
        }
        Text("Every 15s and on each app switch, the front window is read on-device with Apple Vision and labeled by Apple Intelligence. Screenshots and text are never sent anywhere; only the window title and a one-line summary are kept on this Mac for 30 days, plus the page text behind each switch card in the prompt log (14 days). Passwords, Messages, Mail, WhatsApp, Telegram and FaceTime are never captured. Picking \"Still X\" teaches it.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FocusModeSettings: View {
    let tags: [String]
    @ObservedObject private var modes = FocusModes.shared
    @AppStorage(FocusModes.enabledKey) private var enabled = true

    var body: some View {
        ToggleRow(label: "Set my Focus mode when I switch", isOn: $enabled)
        if enabled {
            let missing = FocusModes.modes.map(FocusModes.shortcutName).filter { !modes.installed.contains($0) }
            HStack {
                Text(missing.isEmpty ? (modes.lastResult.isEmpty ? "All shortcuts found" : modes.lastResult)
                     : "Missing shortcuts: " + missing.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(missing.isEmpty ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Recheck") { modes.refreshInstalled() }.controlSize(.small)
            }
            ForEach(tags + ["Break"], id: \.self) { tag in
                HStack {
                    Text(tag).font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(get: { modes.mode(for: tag) }, set: { modes.setMode($0, for: tag) })) {
                        ForEach(FocusModes.modes, id: \.self) { Text($0).tag($0) }
                        Text("Leave as is").tag("")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
        }
        Text("Runs your shortcut “Focus School”, “Focus Personal”, “Focus Sleep” or “Focus Off” (each one Set Focus action) when the category changes. With Share across devices on, your iPhone and iPad follow. A mode you set yourself stays until a switch wants a different one.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
