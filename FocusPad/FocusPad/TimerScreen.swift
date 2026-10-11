import SwiftUI
import SwiftData
import FocusCore

struct TimerScreen: View {
    @EnvironmentObject var engine: FocusTimerEngine
    @EnvironmentObject var settings: PadSettings
    @StateObject private var priorities = TodayPriorities()

    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    @Query(sort: \StoredDayRecord.calendarDay, order: .reverse) private var dayRecords: [StoredDayRecord]

    @State private var showBreakSheet = false
    @State private var showCommitment = false
    @State private var showLabelPicker = false
    @State private var showQuickAddProblem = false
    @State private var newPriority = ""

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width > 700
            ScrollView {
                VStack(spacing: 20) {
                    dayHeaderBar
                    if isWide {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 16) {
                                nowCard
                                prioritiesCard
                            }
                            .frame(maxWidth: .infinity)
                            categoryGrid(wide: true).frame(maxWidth: .infinity)
                        }
                    } else {
                        nowCard
                        categoryGrid(wide: false)
                        prioritiesCard
                    }
                    todayFooter
                }
                .padding(PadTheme.pad)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .navigationTitle("Focus")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showQuickAddProblem = true
                } label: {
                    Label("Log Problem", systemImage: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $showBreakSheet) { BreakSheet(engine: engine) }
        .sheet(isPresented: $showCommitment) { CommitmentSheet(settings: settings) }
        .sheet(isPresented: $showLabelPicker) { LabelPickerSheet(engine: engine, settings: settings) }
        .sheet(isPresented: $showQuickAddProblem) { AddProblemSheet() }
        .onAppear {
            if settings.needsCommitmentToday && dayStarted { showCommitment = true }
            priorities.load()
        }
    }

    // MARK: - Priorities card

    private var prioritiesCard: some View {
        PadCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PadSectionHeader(title: "TODAY'S PRIORITIES")
                    Spacer()
                    Text("\(priorities.items.filter(\.done).count) / \(priorities.items.count) done")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if priorities.items.isEmpty {
                    Text("Pick the 1-3 most important things to ship today.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(priorities.items) { item in
                            HStack(spacing: 10) {
                                Button {
                                    Haptics.tap()
                                    priorities.toggle(item)
                                } label: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(item.done ? FocusColors.goalGreen : .secondary)
                                }
                                Text(item.text)
                                    .strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    priorities.remove(item)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a priority…", text: $newPriority)
                        .submitLabel(.done)
                        .onSubmit { addPriority() }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                        )
                    if !newPriority.isEmpty {
                        Button("Add") { addPriority() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func addPriority() {
        priorities.add(newPriority)
        newPriority = ""
        Haptics.tap()
    }

    // MARK: - Day header

    private var todayRecord: StoredDayRecord? {
        let cal = Calendar.current
        return dayRecords.first { cal.isDateInToday($0.calendarDay) }
    }

    private var dayStarted: Bool { todayRecord?.dayStart != nil }
    private var dayEnded: Bool { todayRecord?.dayEnd != nil }

    private var dayHeaderBar: some View {
        HStack(spacing: 10) {
            if dayEnded {
                Label("Day Ended", systemImage: "moon.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                    .foregroundStyle(Color.purple)
            } else if dayStarted {
                Label("Day Started", systemImage: "sun.max.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
                Spacer()
                Button(role: .destructive) { endDay() } label: {
                    Text("End Day").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            } else {
                Spacer()
                Button { startDay() } label: {
                    Label("Start Day", systemImage: "sun.max.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Now

    private var runningName: String {
        engine.isOnBreak ? "Break" : (engine.currentLabel.isEmpty ? "Focus" : engine.currentLabel)
    }

    private var runningColor: Color {
        engine.isOnBreak ? FocusColors.breakBlue : categoryColor(engine.currentLabel)
    }

    /// Life categories and breaks count up; focus counts down, then overtime.
    private var isCountdown: Bool {
        engine.isActive && !FocusCategories.isOpenEnded(total: engine.totalTime)
    }

    private var nowSubtitle: String {
        let since = engine.sessionStartTime.map { "since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        if isCountdown { return "left · \(since)" }
        if let over = FocusCategories.overtime(total: engine.totalTime, remaining: engine.timeRemaining) {
            return "\(Int(over / 60))m past the target · \(since)"
        }
        return since
    }

    private var nowCard: some View {
        PadCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                if engine.isActive {
                    HStack(spacing: 8) {
                        Image(systemName: engine.isOnBreak ? "cup.and.saucer.fill" : categoryIcon(engine.currentLabel))
                            .foregroundStyle(runningColor)
                        Text(runningName).font(.title2.weight(.bold))
                        Text(engine.isOnBreak || FocusCategories.isLife(engine.currentLabel) ? "LIFE" : "FOCUS")
                            .font(.system(size: 10, weight: .bold)).tracking(1.2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !engine.isRunning {
                            Text("PAUSED").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.orange)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(engine.timeString)
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(runningColor)
                        Text(nowSubtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if isCountdown {
                        ProgressView(value: engine.progress).tint(runningColor)
                        adjustChips
                    }
                    if engine.isOnBreak { breakKindsRow }
                    HStack(spacing: 10) {
                        Button { Haptics.tap(); engine.toggleRunPause() } label: {
                            Label(engine.isRunning ? "Pause" : "Resume",
                                  systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(runningColor)
                        Button { Haptics.warning(); engine.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }
                } else {
                    Text("Nothing running").font(.title2.weight(.bold))
                    Text("Tap what you're doing. Focus counts down from \(Int(settings.workMinutes))m; life and Break count up.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var adjustChips: some View {
        HStack(spacing: 8) {
            ForEach([-10, -5, 5, 10], id: \.self) { d in
                Button {
                    engine.adjustDuration(by: Double(d))
                } label: {
                    Text(d > 0 ? "+\(d)" : "\(d)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
    }

    // MARK: - Categories

    private func categoryGrid(wide: Bool) -> some View {
        let focusTags = settings.tags.filter { !FocusCategories.isLife($0) }
        let lifeTags = settings.tags.filter { FocusCategories.isLife($0) }
        let cols = { (n: Int) in Array(repeating: GridItem(.flexible(), spacing: 10), count: n) }
        return VStack(alignment: .leading, spacing: 10) {
            PadSectionHeader(title: "FOCUS")
            LazyVGrid(columns: cols(2), spacing: 10) {
                ForEach(focusTags, id: \.self) { tile($0, height: 64) }
            }
            HStack {
                PadSectionHeader(title: "LIFE")
                Spacer()
                Button("Edit") { showLabelPicker = true }.font(.caption.weight(.semibold))
            }
            .padding(.top, 6)
            LazyVGrid(columns: cols(wide ? 4 : 3), spacing: 10) {
                ForEach(lifeTags, id: \.self) { tile($0, height: 54) }
                breakTile
            }
        }
    }

    private func tile(_ tag: String, height: CGFloat) -> some View {
        let selected = engine.isActive && !engine.isOnBreak && engine.currentLabel == tag
        let color = categoryColor(tag)
        return Button {
            Haptics.medium()
            engine.switchTo(tag)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: categoryIcon(tag)).font(.system(size: height > 60 ? 20 : 16, weight: .semibold))
                Text(tag).font(.system(size: height > 60 ? 15 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? color : color.opacity(0.14)))
            .foregroundStyle(selected ? Color.white : color)
        }
        .buttonStyle(.plain)
    }

    private var breakTile: some View {
        let selected = engine.isActive && engine.isOnBreak
        return Button {
            Haptics.medium()
            engine.startBreak(minutes: 0)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 16, weight: .semibold))
                Text("Break").font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? FocusColors.breakBlue : FocusColors.breakBlue.opacity(0.14)))
            .foregroundStyle(selected ? Color.white : FocusColors.breakBlue)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Timed break…") { showBreakSheet = true }
        }
    }

    private var breakKindsRow: some View {
        HStack(spacing: 10) {
            ForEach(BreakKind.allCases) { kind in
                let on = engine.currentBreakKinds.contains(kind)
                Button {
                    if on { engine.currentBreakKinds.removeAll { $0 == kind } }
                    else { engine.currentBreakKinds.append(kind) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: kind.icon).font(.system(size: 18))
                        Text(kind.displayName).font(.caption)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(on ? FocusColors.breakBlue.opacity(0.18) : Color(.tertiarySystemFill))
                    )
                    .foregroundStyle(on ? FocusColors.breakBlue : .secondary)
                }
            }
        }
    }

    // MARK: - Today footer

    private var todayFooter: some View {
        let focus = PadStats.workMinutes(sessions, on: Date())
        let count = PadStats.sessionCount(sessions, on: Date())
        let goalMin = Double(settings.dailyGoalHours) * 60
        let pct = goalMin > 0 ? min(focus / goalMin, 1.0) : 0
        return PadCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PadSectionHeader(title: "TODAY")
                    Spacer()
                    Text("\(PadStats.fmtMinutes(focus)) / \(settings.dailyGoalHours)h")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [FocusColors.focusRed.opacity(0.7), FocusColors.focusRed],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * pct))
                    }
                }
                .frame(height: 10)

                HStack(spacing: 14) {
                    miniStat(value: "\(count)", label: "Sessions")
                    miniStat(value: "\(Int(pct * 100))%", label: "Of goal")
                    miniStat(value: "\(engine.workSessionsCompletedToday)", label: "This run")
                }
            }
        }
    }

    private func miniStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Day actions

    @Environment(\.modelContext) private var ctx

    private func startDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let existing = (try? ctx.fetch(FetchDescriptor<StoredDayRecord>(
            predicate: #Predicate { $0.calendarDay == today }
        )))?.first
        if let existing {
            existing.dayStart = Date()
        } else {
            let rec = StoredDayRecord()
            rec.calendarDay = today
            rec.dayStart = Date()
            ctx.insert(rec)
        }
        try? ctx.save()
        Haptics.success()
        if settings.commitmentEnabled && settings.needsCommitmentToday {
            showCommitment = true
        }
    }

    private func endDay() {
        let today = Calendar.current.startOfDay(for: Date())
        if let rec = (try? ctx.fetch(FetchDescriptor<StoredDayRecord>(
            predicate: #Predicate { $0.calendarDay == today }
        )))?.first {
            rec.dayEnd = Date()
            try? ctx.save()
            Haptics.success()
        }
    }
}

// MARK: - Break sheet

private struct BreakSheet: View {
    @ObservedObject var engine: FocusTimerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Double = 30
    @State private var kinds: Set<BreakKind> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Duration") {
                    HStack(spacing: 8) {
                        ForEach([15, 30, 60, 90, 120], id: \.self) { m in
                            Button {
                                minutes = Double(m)
                            } label: {
                                Text(m >= 60 ? "\(m / 60)h" : "\(m)m")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(minutes == Double(m) ? FocusColors.breakBlue.opacity(0.2) : Color(.tertiarySystemFill))
                                    )
                                    .foregroundStyle(minutes == Double(m) ? FocusColors.breakBlue : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Stepper(value: $minutes, in: 5...480, step: 5) {
                        Text("Custom: \(Int(minutes)) min")
                    }
                }
                Section("Type") {
                    HStack(spacing: 10) {
                        ForEach(BreakKind.allCases) { k in
                            Button {
                                if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: k.icon).font(.system(size: 18))
                                    Text(k.displayName).font(.caption)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(kinds.contains(k) ? FocusColors.breakBlue.opacity(0.2) : Color(.tertiarySystemFill))
                                )
                                .foregroundStyle(kinds.contains(k) ? FocusColors.breakBlue : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Take a Break")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        engine.startManualBreak(minutes: minutes, kinds: Array(kinds))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Custom-label picker

private struct LabelPickerSheet: View {
    @ObservedObject var engine: FocusTimerEngine
    @ObservedObject var settings: PadSettings
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Active Tag") {
                    if engine.currentLabel.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(engine.currentLabel).bold()
                            Spacer()
                            Button("Clear", role: .destructive) { engine.currentLabel = "" }
                        }
                    }
                }
                Section("Pick a Tag") {
                    ForEach(settings.tags, id: \.self) { t in
                        Button {
                            if engine.isActive && !engine.isOnBreak {
                                engine.switchTo(t)
                            } else {
                                engine.currentLabel = t
                            }
                            dismiss()
                        } label: {
                            HStack {
                                Text(t)
                                Spacer()
                                if engine.currentLabel == t {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                Section("New Tag") {
                    HStack {
                        TextField("e.g. ML", text: $newTag)
                        Button("Add") {
                            let t = newTag.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty, !settings.tags.contains(t) else { return }
                            settings.tags.append(t)
                            engine.currentLabel = t
                            newTag = ""
                            dismiss()
                        }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Commitment sheet

struct CommitmentSheet: View {
    @ObservedObject var settings: PadSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PadTheme.pad) {
                Text("What will you accomplish today?")
                    .font(.title3).fontWeight(.semibold)
                Text("Write a clear, specific commitment. You can change it later.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                Spacer()
            }
            .padding(PadTheme.largePad)
            .navigationTitle("Daily Commitment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") {
                        settings.markCommitmentDone(text.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { text = settings.todayCommitment }
        }
    }
}
