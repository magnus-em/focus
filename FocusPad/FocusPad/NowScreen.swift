import SwiftUI
import SwiftData
import FocusCore

/// What's tracked right now and one tap to change it, with what Focus has to
/// say about today and the dose clock. The phone's main job: switching when
/// you're away from the Mac, including "I started this half an hour ago".
struct NowScreen: View {
    @EnvironmentObject private var engine: FocusTimerEngine
    @EnvironmentObject private var settings: PadSettings
    @Environment(\.modelContext) private var context
    @ObservedObject private var briefs = DayBriefStore.shared
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    @Query(sort: \StoredDayRecord.calendarDay, order: .reverse) private var dayRecords: [StoredDayRecord]
    @Query(sort: \StoredHealthEvent.date, order: .reverse) private var health: [StoredHealthEvent]
    @Binding var tab: PadTab

    @State private var switchAt: SwitchAtRequest?
    @State private var showCommitment = false
    @State private var notice: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            Group {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 14) { main }.frame(maxWidth: .infinity)
                        VStack(spacing: 14) { side }.frame(width: 380)
                    }
                } else {
                    VStack(spacing: 14) {
                        main
                        side
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .readableWidth(1100)
        .navigationTitle("Now")
        .sheet(item: $switchAt) { request in
            SwitchAtSheet(request: request, tags: settings.tags) { label, at in
                let out = LogActions(engine: engine, context: context).start(label, at: at)
                notice = out.problem ?? "\(label) since \(clock(at))."
                Haptics.success()
            }
        }
        .sheet(isPresented: $showCommitment) {
            CommitmentSheet(text: commitment ?? settings.todayCommitment) { saveCommitment($0) }
        }
    }

    @ViewBuilder
    private var main: some View {
        Text("What's tracked right now. Switch here when you're away from your Mac.")
            .font(.subheadline).foregroundStyle(Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        nowCard
        if let notice {
            Text(notice).font(.footnote).foregroundStyle(Color.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        switchGrid
    }

    @ViewBuilder
    private var side: some View {
        if let brief = briefs.brief(for: Date()), brief.headline != nil { briefCard(brief) }
        todayCard
        if health.contains(where: { HealthKind(rawValue: $0.kind)?.tracker == .adderall }) { adderallRow }
        commitmentRow
    }

    // MARK: - Focus's note

    private func briefCard(_ brief: DayBrief) -> some View {
        let fixes = brief.fixes.filter { !$0.running }.count
        return Button { tab = .today } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label("Focus noticed", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondaryText)
                Text(brief.headline ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(sizeClass == .regular ? 8 : 3)
                HStack {
                    Text(brief.headlineAsOf.map { "Written at \(clock($0))" } ?? "From your Mac")
                    Spacer()
                    if fixes > 0 { Text(fixes == 1 ? "1 thing to fix" : "\(fixes) things to fix").foregroundStyle(Color.orange) }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Running

    private var runningName: String {
        engine.isOnBreak ? "Break" : (engine.currentLabel.isEmpty ? "Focus" : engine.currentLabel)
    }
    private var runningColor: Color { engine.isOnBreak ? FocusColors.breakBlue : categoryColor(engine.currentLabel) }
    private var isCountdown: Bool { engine.isActive && !FocusCategories.isOpenEnded(total: engine.totalTime) }

    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.isActive {
                HStack(spacing: 8) {
                    Image(systemName: engine.isOnBreak ? "cup.and.saucer.fill" : categoryIcon(engine.currentLabel))
                        .foregroundStyle(runningColor)
                    Text(runningName).font(.title2.weight(.semibold))
                    Spacer()
                    if !engine.isRunning {
                        Text("Paused").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(engine.timeString)
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let start = engine.sessionStartTime {
                        Text(isCountdown ? "left · since \(clock(start))" : "since \(clock(start))")
                            .font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
                if isCountdown { ProgressView(value: engine.progress).tint(runningColor) }
                HStack(spacing: 10) {
                    Button { Haptics.tap(); engine.toggleRunPause() } label: {
                        Label(engine.isRunning ? "Pause" : "Resume", systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    Button { Haptics.warning(); engine.stop(); notice = nil } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                }
                if !engine.isOnBreak {
                    Button {
                        switchAt = SwitchAtRequest(label: engine.currentLabel)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(runningColor)
                            Text("Started earlier? Change the start").foregroundStyle(.primary)
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("Nothing tracked").font(.title2.weight(.semibold))
                Text("Tap what you're doing below. Focus categories count toward your \(settings.dailyGoalHours)h goal; Wellbeing, Life and Break count up separately.")
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Switching

    private var switchGrid: some View {
        let focusTags = settings.tags.filter { !FocusCategories.isLife($0) }
        let lifeTags = settings.tags.filter { FocusCategories.isLife($0) && !FocusCategories.isWellbeing($0) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: sizeClass == .regular ? 4 : 3)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Switch to").font(.headline)
            Text("Tap to switch now. Touch and hold one to pick an earlier start.")
                .font(.footnote).foregroundStyle(Color.secondaryText)
            Text("Focus · counts toward your goal").font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondaryText).padding(.top, 6)
            LazyVGrid(columns: columns, spacing: 8) { ForEach(focusTags, id: \.self) { tile($0) } }
            Text("Wellbeing · today’s totals").font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondaryText).padding(.top, 4)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(FocusCategories.wellbeingTags.filter { settings.tags.contains($0) }, id: \.self) { tag in
                    VStack(spacing: 4) {
                        tile(tag)
                        Text(durationText(minutes: todayRows.filter { $0.label == tag }.reduce(0) { $0 + $1.minutes }))
                            .font(.footnote.monospacedDigit()).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            Text("Life").font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondaryText).padding(.top, 4)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(lifeTags, id: \.self) { tile($0) }
                breakTile
            }
        }
    }

    private func tile(_ tag: String) -> some View {
        let selected = engine.isActive && !engine.isOnBreak && engine.currentLabel == tag
        let color = categoryColor(tag)
        return Button {
            guard !selected else { return }
            Haptics.medium()
            engine.switchTo(tag)
            notice = nil
        } label: {
            ChipLabel(icon: categoryIcon(tag), text: tag, color: color, selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Switch now") { engine.switchTo(tag) }
            Button("Started earlier…") { switchAt = SwitchAtRequest(label: tag) }
        }
        .accessibilityLabel(selected ? "\(tag), tracking now" : "Switch to \(tag)")
    }

    private var breakTile: some View {
        let selected = engine.isActive && engine.isOnBreak
        return Button {
            guard !selected else { return }
            Haptics.medium()
            engine.startManualBreak(minutes: 0)
        } label: {
            ChipLabel(icon: "cup.and.saucer.fill", text: "Break", color: FocusColors.breakBlue, selected: selected)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Today

    private var todayRows: [LogRow] { LogRow.rows(Array(sessions.prefix(200)), engine: engine, day: Date()) }

    private var todayCard: some View {
        let rows = todayRows
        let focus = rows.filter { $0.label.map { !FocusCategories.isLife($0) } ?? false }.map(\.minutes).reduce(0, +)
        return Button { tab = .today } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.headline)
                    Spacer()
                    Text("\(durationText(minutes: focus)) focus of \(settings.dailyGoalHours)h")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondaryText)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
                DayStrip(rows: rows, day: Date())
                if let gap = LogRow.gaps(rows, day: Date()).last, Date().timeIntervalSince(gap.end) < 120 {
                    Text("Nothing tracked since \(clock(gap.start)).").font(.footnote).foregroundStyle(Color.orange)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Adderall

    private var doses: [StoredHealthEvent] {
        health.filter { HealthKind(rawValue: $0.kind)?.tracker == .adderall && Calendar.current.isDateInToday($0.date) && $0.date <= Date() }
            .sorted { $0.date < $1.date }
    }

    private var adderallRow: some View {
        Button { tab = .adderall } label: {
            HStack(spacing: 10) {
                Image(systemName: "pills.fill").foregroundStyle(Color.secondaryText)
                if let first = doses.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timerInterval: first.date...Date.distantFuture, countsDown: false)
                            .font(.title3.weight(.semibold).monospacedDigit())
                        Text("since first dose at \(clock(first.date))").font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                } else {
                    Text("No Adderall logged today").foregroundStyle(.primary)
                }
                Spacer()
                Text(doses.isEmpty ? "Log a dose" : "Adderall").font(.subheadline).foregroundStyle(Color.secondaryText)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Commitment

    private var todayRecord: StoredDayRecord? { dayRecords.first { Calendar.current.isDateInToday($0.calendarDay) } }
    private var commitment: String? { todayRecord?.commitmentText.flatMap { $0.isEmpty ? nil : $0 } }

    @ViewBuilder
    private var commitmentRow: some View {
        if let commitment {
            Button { showCommitment = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's commitment").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
                    Text(commitment).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        } else if settings.commitmentEnabled {
            Button("Write today's commitment") { showCommitment = true }
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
        }
    }

    private func saveCommitment(_ text: String) {
        let today = Calendar.current.startOfDay(for: Date())
        let record = (try? context.fetch(FetchDescriptor<StoredDayRecord>(predicate: #Predicate { $0.calendarDay == today })))?.first
            ?? {
                let r = StoredDayRecord()
                r.calendarDay = today
                context.insert(r)
                return r
            }()
        if record.dayStart == nil { record.dayStart = Date() }
        record.commitmentText = text
        try? context.save()
        settings.markCommitmentDone(text)
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

/// A category chip: tinted fill, the icon in the category's color, the name in
/// primary text (category colors on their own tint are too faint to read).
struct ChipLabel: View {
    let icon: String
    let text: String
    let color: Color
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 15, weight: selected ? .semibold : .medium))
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(selected ? 0.3 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color, lineWidth: selected ? 2 : 0))
    }
}

// MARK: - Day strip

/// Midnight to midnight, each tracked block in its category's color.
struct DayStrip: View {
    let rows: [LogRow]
    let day: Date

    var body: some View {
        let start = Calendar.current.startOfDay(for: day)
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill))
                    ForEach(rows) { row in
                        let x = row.start.timeIntervalSince(start) / 86400 * geo.size.width
                        let w = max(1.5, row.end.timeIntervalSince(row.start) / 86400 * geo.size.width)
                        Rectangle()
                            .fill(row.label.map(categoryColor) ?? FocusColors.breakBlue)
                            .frame(width: w)
                            .offset(x: x)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 16)
            GeometryReader { geo in
                ForEach(Array(["12a", "6a", "12p", "6p", "12a"].enumerated()), id: \.offset) { i, label in
                    Text(label)
                        .fixedSize()
                        .frame(width: 40, alignment: i == 0 ? .leading : (i == 4 ? .trailing : .center))
                        .position(x: min(max(20, geo.size.width * Double(i) / 4), geo.size.width - 20), y: 6)
                }
            }
            .frame(height: 12)
            .font(.system(size: 10)).foregroundStyle(Color.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's log: " + rows.map { "\($0.name) \(durationText(minutes: $0.minutes))" }.joined(separator: ", "))
    }
}

// MARK: - Switch at a time

struct SwitchAtRequest: Identifiable {
    let id = UUID()
    let label: String
}

struct SwitchAtSheet: View {
    let request: SwitchAtRequest
    let tags: [String]
    let apply: (String, Date) -> Void
    @EnvironmentObject private var engine: FocusTimerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var at = Date().addingTimeInterval(-15 * 60)

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Button { label = tag } label: {
                                ChipLabel(icon: categoryIcon(tag), text: tag, color: categoryColor(tag), selected: label == tag)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Since") {
                    HStack(spacing: 8) {
                        ForEach([5, 15, 30, 60, 90], id: \.self) { m in
                            Button(m < 60 ? "\(m)m ago" : (m == 60 ? "1h ago" : "1½h ago")) {
                                at = Date().addingTimeInterval(Double(-m) * 60)
                            }
                            .buttonStyle(.bordered)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        }
                    }
                    DatePicker("Started at", selection: $at, in: Date().addingTimeInterval(-24 * 3600)...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Text(explanation).font(.footnote).foregroundStyle(Color.secondaryText)
                }
            }
            .navigationTitle("Started earlier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        apply(label, min(at, Date()))
                        dismiss()
                    }
                    .disabled(label.isEmpty)
                }
            }
            .onAppear { label = request.label.isEmpty ? (tags.first ?? "") : request.label }
        }
        .presentationDetents([.large])
    }

    private var explanation: String {
        let when = at.formatted(date: .omitted, time: .shortened)
        let running = engine.isActive ? (engine.isOnBreak ? "Break" : engine.currentLabel) : nil
        guard !label.isEmpty else { return "" }
        if let running, let start = engine.sessionStartTime {
            if at >= start {
                return running == label
                    ? "\(label) is already running since \(start.formatted(date: .omitted, time: .shortened))."
                    : "\(running) is saved up to \(when), and \(label) runs from then."
            }
            return "\(label) from \(when). Everything logged since then, including the running \(running), becomes \(label)."
        }
        return "\(label) runs from \(when). Anything logged since then becomes \(label)."
    }
}

// MARK: - Commitment

struct CommitmentSheet: View {
    @State var text: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("What will you get done today?").font(.title3.weight(.semibold))
                Text("Your Mac shows the same commitment.").font(.callout).foregroundStyle(Color.secondaryText)
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                Spacer()
            }
            .padding(20)
            .navigationTitle("Today's commitment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
