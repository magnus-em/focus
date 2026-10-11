import SwiftUI
import FocusCore

struct TimerView: View {
    @ObservedObject var timer: TimerManager
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var dayStore: DayStore
    @Binding var showCommitment: Bool
    @Binding var reviewTarget: DayRecord?
    @Binding var showDayReview: Bool
    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared

    @State private var showAllCategories = false

    private static let focusRed = Color(red: 0.96, green: 0.36, blue: 0.36)
    private static let breakBlue = Color(red: 0.27, green: 0.62, blue: 0.83)

    private var isLifeLabel: Bool { FocusCategories.isLife(timer.currentLabel) }

    private var phaseColor: Color {
        if timer.isOnBreak { return Self.breakBlue }
        return isLifeLabel ? categoryColor(timer.currentLabel) : Self.focusRed
    }

    private var phaseTitle: String {
        if timer.isOnBreak { return "BREAK" }
        return isLifeLabel ? "LIFE" : "FOCUS"
    }

    /// Life blocks and breaks have no target: they just count up.
    private var isCountingUp: Bool {
        timer.isActive && FocusCategories.isOpenEnded(total: timer.totalTime)
            && FocusCategories.countdown(total: timer.totalTime) == 0
    }

    private var liveFocusMinutes: Double {
        guard let s = timer.currentInProgressSession, s.isFocus else { return 0 }
        return s.durationMinutes
    }

    private var todayFocusMinutes: Double { store.todayWorkMinutes + liveFocusMinutes }

    private var todayBreakMinutes: Double {
        store.todayBreakMinutes + (timer.currentInProgressBreak?.durationMinutes ?? 0)
    }

    private var overtime: TimeInterval? {
        FocusCategories.overtime(total: timer.totalTime, remaining: timer.timeRemaining)
    }

    private var collapseCategories: Bool {
        timer.isActive && (timer.isOnBreak || !timer.currentLabel.isEmpty) && !showAllCategories
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
                Text(phaseTitle)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(phaseColor)
            }

            if settings.tags.isEmpty {
                Text("Add categories in Settings")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else if collapseCategories {
                currentCategoryPill
            } else {
                categoryPicker
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
                    .stroke(phaseColor.opacity(isCountingUp ? 0.45 : 1), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: timer.progress)

                VStack(spacing: 4) {
                    Text(timer.timeString)
                        .font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 116)
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.3), value: timer.timeString)

                    if isCountingUp, let start = timer.sessionStartTime {
                        Text("since \(clockStr(start))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(phaseColor)
                    } else if let over = overtime {
                        let target = Int(FocusCategories.countdown(total: timer.totalTime) / 60)
                        Text("\(target)m done · +\(Int(over) / 60)m")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(timer.isOnBreak ? phaseColor : .green)
                    } else if !timer.isOnBreak && store.todaySessionCount > 0 {
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

                }
            }

            Divider().padding(.horizontal, 8)

            if settings.dailyGoal > 0 {
                let hoursToday = todayFocusMinutes / 60.0
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
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
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
                    Text(formatMinutes(todayFocusMinutes))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("Focus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(formatMinutes(todayBreakMinutes))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Text("Break")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                let pending = todayFocusMinutes < 1
                let streak = store.currentStreak + (store.todayWorkMinutes < 1 && !pending ? 1 : 0)
                VStack(spacing: 2) {
                    Text("\(streak)d")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(streak > 0 ? Color.orange.opacity(pending ? 0.45 : 1) : .secondary)
                    Text(pending && streak > 0 ? "Streak · today?" : "Streak")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(pending && streak > 0 ? "Log some focus today to keep the streak" : "")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
    }

    private var currentCategoryPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showAllCategories = true }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(timer.isOnBreak ? Self.breakBlue : categoryColor(timer.currentLabel)).frame(width: 7, height: 7)
                Text(timer.isOnBreak ? "Break" : timer.currentLabel)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassChip()
        }
        .buttonStyle(.plain)
        .help("Switch category (⌃⌥⌘J)")
    }

    private var categoryPicker: some View {
        let focusTags = settings.tags.filter { !settings.lifeTags.contains($0) }
        let lifeTags = settings.tags.filter { settings.lifeTags.contains($0) }
        return VStack(spacing: 6) {
            if !focusTags.isEmpty { chipFlow(focusTags, life: false) }
            if !lifeTags.isEmpty {
                HStack(spacing: 6) {
                    Text("LIFE")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.tertiary)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                }
                .padding(.horizontal, 4)
                chipFlow(lifeTags, life: true)
            }
            if timer.isActive {
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllCategories = false }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
            }
        }
    }

    private func chipFlow(_ tags: [String], life: Bool) -> some View {
        glassChipGroup {
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    let selected = timer.currentLabel == tag && timer.isActive && !timer.isOnBreak
                        || (!timer.isActive && timer.currentLabel == tag)
                    let tint = categoryColor(tag)
                    Button(tag) {
                        if timer.isActive || life {
                            if !selected { timer.switchTo(tag) }
                            showAllCategories = false
                        } else {
                            timer.currentLabel = timer.currentLabel == tag ? "" : tag
                        }
                    }
                        .font(.system(size: life ? 10 : 11, weight: life ? .regular : .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(selected ? tint : (life ? Color.secondary.opacity(0.8) : Color.primary.opacity(0.75)))
                        .glassChip(selected: selected, tint: tint)
                        .buttonStyle(.plain)
                }
                if life {
                    let onBreak = timer.isOnBreak && timer.isActive
                    Button {
                        if !onBreak { timer.startManualBreak(minutes: 0) }
                        showAllCategories = false
                    } label: {
                        Label("Break", systemImage: "cup.and.saucer").labelStyle(.titleAndIcon)
                    }
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(onBreak ? Self.breakBlue : Color.secondary.opacity(0.8))
                        .glassChip(selected: onBreak, tint: Self.breakBlue)
                        .buttonStyle(.plain)
                        .help("Saves what's running, then counts up until you switch")
                }
            }
        }
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
                .glassEffect(.clear, in: Circle())
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
            let holes = store.untrackedMinutes(on: store.reviewWindow().from)
            if holes >= 15 {
                Button { showDayReview = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.badge.questionmark").font(.system(size: 9))
                        Text("Yesterday: \(Int(holes) / 60)h \(Int(holes) % 60)m untracked")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassChip()
                }
                .buttonStyle(.plain)
                .help("Fill in the holes since yesterday")
            }
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

    private func formatMinutes(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func clockStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"; return f.string(from: d)
    }
}

