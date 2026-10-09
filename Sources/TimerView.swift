import SwiftUI
import FocusCore

struct TimerView: View {
    @ObservedObject var timer: TimerManager
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var dayStore: DayStore
    @Binding var showCommitment: Bool
    @Binding var reviewTarget: DayRecord?
    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared

    @State private var showBreakPicker = false
    @State private var customBreakMinutes: Double = 30
    @State private var selectedBreakKinds: Set<BreakKind> = []

    private var phaseColor: Color {
        switch timer.currentPhase {
        case .work:       return Color(red: 0.96, green: 0.36, blue: 0.36)
        case .shortBreak, .longBreak: return Color(red: 0.27, green: 0.62, blue: 0.83)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            dayStatusRow

            if syncMonitor.health == .failing || syncMonitor.health == .stale {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.icloud").font(.system(size: 9))
                    Text(syncMonitor.health == .failing ? "iCloud sync failing — see Settings" : "iCloud hasn't synced in 3+ days")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.orange)
            }

            // The pause countdown takes the phase label's slot so pausing and
            // resuming never shifts the layout.
            if timer.pauseRemainingSeconds > 0 {
                let s = Int(timer.pauseRemainingSeconds.rounded(.up))
                Text("PAUSED · ENDS IN \(s / 60):\(String(format: "%02d", s % 60))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.orange)
                    .help("Resume before this runs out, or the session is saved and ended")
            } else {
                Text(timer.currentPhase.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(phaseColor)
            }

            if !timer.isOnBreak {
                if settings.tags.isEmpty {
                    Text("Add categories in the Stats tab")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                } else {
                    glassChipGroup {
                        FlowLayout(spacing: 5) {
                            ForEach(settings.tags, id: \.self) { tag in
                                let selected = timer.currentLabel == tag
                                Button(tag) {
                                    if timer.isActive && !timer.isOnBreak {
                                        if !selected { timer.switchTo(tag) }
                                    } else {
                                        timer.currentLabel = selected ? "" : tag
                                    }
                                }
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(selected ? phaseColor : Color.secondary)
                                    .glassChip(selected: selected, tint: phaseColor)
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if timer.isBlockingActive {
                HStack(spacing: 4) {
                    Image(systemName: "shield.fill").font(.system(size: 9))
                    Text("Sites Blocked").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(phaseColor.opacity(0.7))
            }

            if !timer.isActive && !timer.isOnBreak && !FocusCategories.isLife(timer.currentLabel) {
                glassChipGroup {
                    HStack(spacing: 6) {
                        ForEach([15, 25, 45, 60], id: \.self) { mins in
                            let selected = Int(timer.totalTime / 60) == mins
                            Button("\(mins)m") { timer.setSessionDuration(Double(mins)) }
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(selected ? phaseColor : Color.secondary)
                                .glassChip(selected: selected, tint: phaseColor)
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            ZStack {
                ringLens
                Circle()
                    .stroke(phaseColor.opacity(0.12), lineWidth: 8)
                    .frame(width: 140, height: 140)
                Circle()
                    .trim(from: 0, to: timer.progress)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: timer.progress)

                VStack(spacing: 4) {
                    Text(timer.timeString)
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.3), value: timer.timeString)

                    if !timer.isOnBreak && store.todaySessionCount > 0 {
                        Text("Session \(store.todaySessionCount + (timer.isActive ? 1 : 0))")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(phaseColor.opacity(0.5))
                    }
                }
            }

            glassChipGroup {
                HStack(spacing: 12) {
                    controlSecondaryButton(
                        systemImage: timer.isActive ? "stop.fill" : "arrow.counterclockwise",
                        help: timer.isActive ? "End session (saves progress)" : "Reset timer"
                    ) { timer.reset() }

                    controlPrimaryButton(
                        systemImage: timer.isRunning ? "pause.fill" : "play.fill",
                        tint: phaseColor
                    ) { timer.isRunning ? timer.pause() : timer.start() }

                    controlSecondaryButton(
                        systemImage: "forward.fill",
                        help: "Skip"
                    ) { timer.skip() }
                }
            }

            takeBreakSection

            Divider().padding(.horizontal, 8)

            if settings.dailyGoal > 0 {
                let hoursToday = store.todayWorkMinutes / 60.0
                let pct = min(1.0, hoursToday / Double(settings.dailyGoal))
                let goalMet = hoursToday >= Double(settings.dailyGoal)
                let barColor: Color = goalMet ? .green : phaseColor

                VStack(spacing: 4) {
                    HStack {
                        Text("Daily Goal")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1fh / %dh", hoursToday, settings.dailyGoal))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(goalMet ? Color.green : .primary)
                            .contentTransition(.numericText())
                        if goalMet {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule()
                                .fill(barColor)
                                .frame(width: geo.size.width * CGFloat(pct))
                                .animation(.spring(response: 0.5), value: pct)
                        }
                    }
                    .frame(height: 5)
                }
                .padding(.horizontal, 4)
            }

            HStack {
                VStack(spacing: 2) {
                    Text(formatMinutes(store.todayWorkMinutes))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("Focus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(formatMinutes(store.todayBreakMinutes))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Text("Break")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text("\(store.currentStreak)d")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(store.currentStreak > 0 ? .orange : .secondary)
                    Text("Streak")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var takeBreakSection: some View {
        if !timer.isOnBreak {
            if showBreakPicker {
                inlineBreakPicker
            } else {
                Button {
                    showBreakPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cup.and.saucer")
                            .font(.system(size: 10))
                        Text("Take a Break")
                            .font(.system(size: 11, weight: .medium))
                        if timer.isActive {
                            Text("· ends session")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .glassChip()
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var inlineBreakPicker: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Take a Break")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showBreakPicker = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            glassChipGroup {
                HStack(spacing: 6) {
                    ForEach(BreakKind.allCases) { kind in
                        let sel = selectedBreakKinds.contains(kind)
                        Button {
                            if sel { selectedBreakKinds.remove(kind) }
                            else   { selectedBreakKinds.insert(kind) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: kind.icon).font(.system(size: 9))
                                Text(kind.displayName).font(.system(size: 11, weight: .medium))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(sel ? Color(red: 0.27, green: 0.62, blue: 0.83) : Color.secondary)
                        .glassChip(selected: sel, tint: Color(red: 0.27, green: 0.62, blue: 0.83))
                        .buttonStyle(.plain)
                    }
                }
            }

            glassChipGroup {
                HStack(spacing: 6) {
                    ForEach([10.0, 15.0, 30.0, 60.0, 120.0, 180.0], id: \.self) { mins in
                        let label = mins < 60 ? "\(Int(mins))m" : "\(Int(mins / 60))h"
                        Button(label) {
                            startBreak(minutes: mins)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color(red: 0.27, green: 0.62, blue: 0.83))
                        .glassChip()
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    customBreakMinutes = max(5, customBreakMinutes - 5)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.22), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.downArrow, modifiers: [])

                Text("\(Int(customBreakMinutes)) min")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 54)

                Button {
                    customBreakMinutes = min(480, customBreakMinutes + 5)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.22), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.upArrow, modifiers: [])

                Spacer()

                Button("Start") {
                    startBreak(minutes: customBreakMinutes)
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(Color(red: 0.27, green: 0.62, blue: 0.83))
                .glassChip()
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    // Native glass button styles own their hit region, unlike a
    // `.glassEffect` modifier on a plain Button, which intermittently
    // swallowed play clicks on Tahoe (see 6ab52b9).
    @ViewBuilder
    private func controlPrimaryButton(systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(tint)
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(tint)
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func controlSecondaryButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass(.clear))
            .buttonBorderShape(.circle)
            .help(help)
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    // A clear lens inside the ring so the desktop bends through the countdown.
    @ViewBuilder
    private var ringLens: some View {
        if #available(macOS 26.0, *) {
            Circle()
                .fill(.clear)
                .frame(width: 124, height: 124)
                .glassEffect(timer.isRunning ? .clear.tint(phaseColor.opacity(0.10)) : .clear, in: Circle())
        }
    }

    @ViewBuilder
    private var dayStatusRow: some View {
        HStack {
            if let start = dayStore.todayRecord?.dayStart {
                HStack(spacing: 3) {
                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Since \(clockStr(start))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("End Day") {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    dayStore.endDay()
                }
                if dayStore.todayCommitmentNeedsReview, let r = dayStore.todayRecord {
                    reviewTarget = r
                }
            }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassChip()
                .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    private func startBreak(minutes: Double) {
        let kinds = BreakKind.allCases.filter { selectedBreakKinds.contains($0) }
        showBreakPicker = false
        let captured = kinds
        selectedBreakKinds = []
        timer.startManualBreak(minutes: minutes, kinds: captured)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func clockStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"; return f.string(from: d)
    }
}

