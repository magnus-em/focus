import SwiftUI
import FocusCore

/// The popover's "Now" page (DESIGN.md, direction A+B). Shows only what
/// matters at this moment: what's running and for how long beside a small
/// goal ring, at most one line that needs you, and the controls. The day
/// strip, what the screen sees and today's log sit behind a Details button.
/// Category chips appear only when nothing is running, because then picking
/// one is the next thing to do.
struct TimerView: View {
    enum Detent: Int, CaseIterable { case small, large }

    struct MoreItem: Identifiable {
        let title: String
        let icon: String
        var badge: String? = nil
        var divider = false
        let action: () -> Void
        var id: String { title }
    }

    @ObservedObject var timer: TimerManager
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var dayStore: DayStore
    @ObservedObject var health: HealthStore
    @Binding var showDayReview: Bool
    @Binding var detent: Detent
    var onOpenDose: () -> Void = {}
    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared
    @ObservedObject private var watcher = ScreenWatcher.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedCategoryTotals: [String: Double] = [:]
    @State private var whereWasI: WhereWasI.Line?
    /// Minutes today the screen showed a life category during focus blocks.
    @State private var possibleDrift: Double = 0
    @StateObject private var story = DayStoryModel()
    @State private var selectedSegment: Date?
    @State private var hoveredSegment: Date?
    @State private var stripUndo: SessionStore.ReviewUndo?

    static let breakBlue = Color(red: 0.27, green: 0.62, blue: 0.83)

    private var onBreak: Bool { timer.isActive && timer.isOnBreak }

    /// The running category's color: ring, primary button, wash.
    /// Neutral with nothing picked: the system blue reads as Math.
    var accent: Color {
        if onBreak { return Self.breakBlue }
        return timer.currentLabel.isEmpty ? .primary : categoryColor(timer.currentLabel)
    }

    private var isCountingUp: Bool {
        timer.isActive && FocusCategories.isOpenEnded(total: timer.totalTime)
            && FocusCategories.countdown(total: timer.totalTime) == 0
    }

    private var todayFocusMinutes: Double {
        todayFocusByCategory.values.reduce(0, +)
    }

    private var todayFocusByCategory: [String: Double] {
        todayCategoryTotals.filter { !settings.lifeTags.contains($0.key) }
    }

    private var todayCategoryTotals: [String: Double] {
        var totals = savedCategoryTotals
        let live = FocusStats.focusCategoryMinutes([], live: timer.currentInProgressSession,
                                                  on: Date(), through: Date(), lifeTags: [])
        for (label, minutes) in live { totals[label, default: 0] += minutes }
        return totals
    }

    private var running: String? { timer.isActive ? (onBreak ? "Break" : timer.currentLabel) : nil }

    var body: some View {
        VStack(spacing: 14) {
            hero
            focusTotals
            wellbeingTotals
            if !timer.isActive {
                if !FocusCategories.isLife(timer.currentLabel) { presets }
                startChips
            }
            attention
            if let whereWasI { WhereWasIRow(line: whereWasI) }
            controlBar
            detailsButton
            if detent == .large {
                dayStrip
                if #available(macOS 26.0, *), LogCorrection.available {
                    LogFixView(timer: timer, store: store, categories: settings.tags)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .onReceive(store.$sessions) { refreshFocusTotals($0) }
        .task {
            while !Task.isCancelled {
                refreshDrift()
                refreshStory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: running) {
            guard let running, running != "Break", !FocusCategories.isLife(running) else { whereWasI = nil; return }
            whereWasI = await CoachDayWorker.whereWasI(running: running)
        }
        .onChange(of: settings.lifeTags) { _, _ in refreshFocusTotals(store.sessions) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshFocusTotals(store.sessions) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: detent)
    }

    /// Shown next to focus, never subtracted: the screen can mislabel, and
    /// paper or iPad study looks like nothing on the Mac.
    private func refreshDrift() {
        guard settings.screenWatch else { return possibleDrift = 0 }
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let live = [timer.currentInProgressSession].compactMap { $0 }
            .map { WorkSession(startTime: $0.startTime, durationMinutes: now.timeIntervalSince($0.startTime) / 60,
                               type: $0.type, label: $0.label) }
        let today = store.sessions.filter { TimeIntegrity.end(of: $0) > day } + live
        possibleDrift = watcher.drifts(sessions: today, from: day, to: now).reduce(0) { $0 + $1.minutes }
    }

    private func refreshStory() {
        let day = Calendar.current.startOfDay(for: Date())
        let live = [timer.currentInProgressSession, timer.currentInProgressBreak].compactMap { $0 }
            .map { WorkSession(startTime: $0.startTime, durationMinutes: Date().timeIntervalSince($0.startTime) / 60,
                               type: $0.type, label: $0.label) }
        story.refresh(day: day, sessions: store.sessions.filter { TimeIntegrity.end(of: $0) > day }, live: live,
                      focus: Set(settings.tags.filter { !settings.lifeTags.contains($0) }))
    }

    private func refreshFocusTotals(_ sessions: [WorkSession]) {
        savedCategoryTotals = FocusStats.focusCategoryMinutes(sessions, on: Date(), through: Date(), lifeTags: [])
    }

    @ViewBuilder
    private var focusTotals: some View {
        let totals = todayFocusByCategory.filter { $0.value > 2 }
        let labels = settings.tags.filter { totals[$0] != nil }
            + totals.keys.filter { !settings.tags.contains($0) }.sorted()
        if labels.count > 1 || possibleDrift >= 1 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(labels.count > 1 ? "Focus today" : labels.first.map { "Today's focus: \($0)" } ?? "Focus today")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                    Spacer()
                    if possibleDrift >= 1 {
                        Text("\(hm(possibleDrift)) off-task, per the screen")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .help("The screen showed a non-focus category during focus blocks. Not taken off your focus time: the screen can be wrong, and work on paper or the iPad doesn't show here.")
                    }
                }
                if labels.count > 1 { FlowLayout(spacing: 8) {
                    ForEach(labels, id: \.self) { label in
                        HStack(spacing: 6) {
                            Circle().fill(categoryColor(label)).frame(width: 7, height: 7)
                            Text(label).font(.system(size: 13, weight: .medium))
                            Text(hm(totals[label] ?? 0)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.secondaryText)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .accessibilityElement(children: .combine)
                    }
                } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var wellbeingTotals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wellbeing today · separate from your focus goal")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            FlowLayout(spacing: 8) {
                ForEach(FocusCategories.wellbeingTags.filter { settings.tags.contains($0) }, id: \.self) { label in
                    HStack(spacing: 6) {
                        Circle().fill(categoryColor(label)).frame(width: 7, height: 7)
                        Text(label).font(.system(size: 13, weight: .medium))
                        Text(hm(todayCategoryTotals[label] ?? 0))
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.secondaryText)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            goalRing
            VStack(alignment: .leading, spacing: 2) {
                categoryMenu
                Text(timer.timeString)
                    .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: timer.timeString)
                subline
                doseLine
            }
            Spacer(minLength: 0)
        }
    }

    /// The ring measures focus, so it takes the running category's color only
    /// when that's a focus category; otherwise the day's main focus color, so a
    /// green Exercise ring never reads as "3h 57m of Exercise".
    private var ringColor: Color {
        let label = timer.currentLabel
        if timer.isActive, !timer.isOnBreak, !label.isEmpty, !FocusCategories.isLife(label) { return categoryColor(label) }
        if let top = todayFocusByCategory.max(by: { $0.value < $1.value })?.key { return categoryColor(top) }
        return Color.primary.opacity(0.5)
    }

    /// Secondary to the timer: small, in the category's color, with a
    /// check once the day's goal is met.
    private var goalRing: some View {
        let goal = Double(max(settings.dailyGoal, 1))
        let hours = todayFocusMinutes / 60
        let met = settings.dailyGoal > 0 && hours >= goal
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
            Circle()
                .trim(from: 0, to: min(1, hours / goal))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: hours)
            // Past the goal, a second, lighter lap keeps the ring meaningful.
            if met {
                Circle()
                    .trim(from: 0, to: min(1, hours / goal - 1))
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(hm(todayFocusMinutes))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                if met {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.good)
                } else if settings.dailyGoal > 0 {
                    Text("of \(settings.dailyGoal)h goal").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 72, height: 72)
        .help(met ? "Today's \(settings.dailyGoal)h goal is met" : "Focus today toward your \(settings.dailyGoal)h goal")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hm(todayFocusMinutes)) focus today\(met ? ", goal met" : ", goal \(settings.dailyGoal) hours")")
    }

    private var categoryMenu: some View {
        Menu {
            let focus = settings.tags.filter { !settings.lifeTags.contains($0) }
            let life = settings.tags.filter { settings.lifeTags.contains($0) }
            Section("Focus · counts toward your goal") {
                ForEach(focus, id: \.self) { t in Button(t) { pick(t) } }
            }
            Section("Wellbeing · counts up") {
                ForEach(FocusCategories.wellbeingTags.filter { settings.tags.contains($0) }, id: \.self) { t in
                    Button(t) { pick(t) }
                }
            }
            if !life.isEmpty {
                Section("Life · counts up") {
                    ForEach(life.filter { !FocusCategories.isWellbeing($0) }, id: \.self) { t in Button(t) { pick(t) } }
                }
            }
            Divider()
            Button("Break") { if !onBreak { timer.startManualBreak(minutes: 0) } }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 10, height: 10)
                Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch category (⌃⌥⌘J)")
    }

    private var title: String {
        if onBreak { return "Break" }
        return timer.currentLabel.isEmpty ? "Ready" : timer.currentLabel
    }

    /// One plain-words line: how long, against what, and whether sites are blocked.
    private var subline: some View {
        Group {
            if timer.pauseRemainingSeconds > 0 {
                let s = Int(timer.pauseRemainingSeconds.rounded(.up))
                Text("Paused · ends in \(s / 60):\(String(format: "%02d", s % 60))")
                    .foregroundStyle(.orange)
                    .help("Resume before this runs out, or the session is saved and ended")
            } else {
                Text(sublineText).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var doseLine: some View {
        TimelineView(.everyMinute) { ctx in
            Button(action: onOpenDose) {
                if let dose = health.firstDoseToday(now: ctx.date) {
                    Label("Adderall · \(durationText(minutes: (ctx.date.timeIntervalSince(dose.date) / 60).rounded(.down))) since \(dose.date.formatted(date: .omitted, time: .shortened))",
                          systemImage: "pills")
                        .help("Since your first dose today, \(dose.kind.displayName). Click to log or edit a dose.")
                } else {
                    Label("Log morning dose", systemImage: "pills")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sublineText: String {
        guard timer.isActive else { return timer.currentLabel.isEmpty ? "Pick what's next" : "Press Start when you're ready" }
        var parts: [String] = []
        if isCountingUp, let start = timer.sessionStartTime {
            parts.append("Since \(clock(start))")
        } else if let over = FocusCategories.overtime(total: timer.totalTime, remaining: timer.timeRemaining) {
            let target = Int(FocusCategories.countdown(total: timer.totalTime) / 60)
            parts.append("\(Int(over) / 60) min past your \(target == 60 ? "hour" : "\(target) min")")
        } else {
            parts.append("Until \(clock(Date().addingTimeInterval(timer.timeRemaining)))")
        }
        if timer.isBlockingActive { parts.append("Sites blocked") }
        return parts.joined(separator: " · ")
    }

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach([15, 25, 45, 60], id: \.self) { mins in
                let selected = Int(timer.totalTime / 60) == mins
                Button { timer.setSessionDuration(Double(mins)) } label: {
                    Text("\(mins) min")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(Capsule().fill(selected ? accent.opacity(0.2) : Color.primary.opacity(0.06)))
                        .foregroundStyle(selected ? accent : .primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var startChips: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Focus · counts toward your goal").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                FlowLayout(spacing: 6) {
                    ForEach(settings.tags.filter { !settings.lifeTags.contains($0) }, id: \.self) { tag in
                        chip(tag, color: categoryColor(tag), selected: timer.currentLabel == tag) { pick(tag) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Wellbeing · counts up").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                FlowLayout(spacing: 6) {
                    ForEach(FocusCategories.wellbeingTags.filter { settings.tags.contains($0) }, id: \.self) { tag in
                        chip(tag, color: categoryColor(tag), selected: timer.currentLabel == tag) { pick(tag) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ name: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(selected ? color.opacity(0.22) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ tag: String) {
        if timer.isActive || FocusCategories.isLife(tag) {
            if !(timer.isActive && !timer.isOnBreak && timer.currentLabel == tag) { timer.switchTo(tag) }
        } else {
            timer.currentLabel = timer.currentLabel == tag ? "" : tag
        }
    }

    // MARK: - The one line that needs you

    private enum Attention {
        case screen(category: String, since: Date)
        case storage(String)
        case sync(String)
        case fix(DayStory.Fix)
        case yesterday(Double)
    }

    /// Today's most important fix from the day story: a class tracked as
    /// something else, or a gap of 20 minutes or more. The running block's
    /// screen disagreement already has its own line.
    private var todayFix: DayStory.Fix? {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: DayStoryPage.dismissedKey) ?? [])
        return story.story?.fixes.first { f in
            guard !dismissed.contains(f.id), !f.running else { return false }
            switch f.kind {
            case .calendar: return true
            case .untracked: return f.minutes >= 20
            case .screenDiffers: return false
            }
        }
    }

    /// At most one, most urgent first. Yesterday's holes only in the morning:
    /// after noon they're in the End of Day review instead of nagging.
    private var currentAttention: Attention? {
        let now = Date()
        if store.saveError != nil { return .storage("Couldn't save your log. Is the disk full?") }
        if let gb = store.lowDiskGB { return .storage(String(format: "Disk almost full: %.1f GB left", gb)) }
        if let running, running != "Break", settings.screenWatch,
           let block = watcher.activities(from: Calendar.current.startOfDay(for: now), to: now)
               .last(where: { $0.device == nil && now.timeIntervalSince($0.end) < 90 }),
           let c = block.category, c != running, now.timeIntervalSince(block.start) >= 60 {
            return .screen(category: c, since: block.start)
        }
        if syncMonitor.health == .failing { return .sync("iCloud sync is failing. See Settings.") }
        if syncMonitor.health == .stale { return .sync("iCloud hasn't synced in 3 days.") }
        if let f = todayFix { return .fix(f) }
        let holes = store.untrackedMinutes(on: store.reviewWindow().from)
        if holes >= 15, Calendar.current.component(.hour, from: now) < 12 { return .yesterday(holes) }
        return nil
    }

    @ViewBuilder
    private var attention: some View {
        switch currentAttention {
        case .screen(let c, let since):
            attentionRow(color: categoryColor(c), icon: "eye", text: "Screen shows \(c) since \(clock(since))",
                         action: "Switch") { timer.switchTo(c, at: since) }
        case .storage(let text):
            attentionRow(color: .red, icon: "externaldrive.badge.exclamationmark", text: text, action: nil) {}
        case .sync(let text):
            attentionRow(color: .orange, icon: "exclamationmark.icloud", text: text, action: nil) {}
        case .fix(let f):
            attentionRow(color: .orange, icon: "exclamationmark.circle", text: fixText(f), action: "Review") {
                if let url = URL(string: "focus://dashboard") { NSWorkspace.shared.open(url) }
            }
        case .yesterday(let m):
            attentionRow(color: .orange, icon: "clock.badge.questionmark", text: "Fill in \(hm(m)) from yesterday",
                         action: "Review") { showDayReview = true }
        case nil:
            EmptyView()
        }
    }

    private func fixText(_ f: DayStory.Fix) -> String {
        switch f.kind {
        case .calendar(let event): return "You tracked \(f.tracked ?? "something else") during \(event)"
        case .untracked: return "\(hm(f.minutes)) not logged at \(clock(f.start))"
        case .screenDiffers(let seen): return "Screen showed \(seen) at \(clock(f.start))"
        }
    }

    private func attentionRow(color: Color, icon: String, text: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            Text(text).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(color.opacity(0.2)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.1)))
    }

    // MARK: - Behind the grabber

    private struct Block { let start: Date, end: Date, label: String }

    private var todayBlocks: [Block] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let live = [timer.currentInProgressSession, timer.currentInProgressBreak].compactMap { $0 }
            .map { WorkSession(startTime: $0.startTime, durationMinutes: Date().timeIntervalSince($0.startTime) / 60,
                               type: $0.type, label: $0.label) }
        return (store.sessions + live).compactMap { s in
            let end = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            guard end > day, s.durationMinutes >= 1 else { return nil }
            return Block(start: max(s.startTime, day), end: end, label: s.type != .work ? "Break" : (s.label ?? "Focus"))
        }
        .sorted { $0.start < $1.start }
    }

    /// Back-to-back blocks of one category (a switch away and back, a
    /// relaunch) read as one row.
    private func merged(_ list: [Block]) -> [Block] {
        var out: [Block] = []
        for b in list {
            if let l = out.last, l.label == b.label, b.start.timeIntervalSince(l.end) < 120 {
                out[out.count - 1] = Block(start: l.start, end: max(l.end, b.end), label: l.label)
            } else { out.append(b) }
        }
        return out
    }

    /// Today's tracked blocks plus the untracked gaps (≥ 5 min) up to now,
    /// so every part of the bar can be clicked.
    private var stripSegments: [Block] {
        let day = Calendar.current.startOfDay(for: Date())
        let now = Date()
        var out: [Block] = []
        var cursor = day
        for b in merged(todayBlocks) {
            if b.start.timeIntervalSince(cursor) >= 300 { out.append(Block(start: cursor, end: b.start, label: "")) }
            out.append(b)
            cursor = max(cursor, b.end)
        }
        if now.timeIntervalSince(cursor) >= 300 { out.append(Block(start: cursor, end: now, label: "")) }
        return out
    }

    private func segmentColor(_ label: String) -> Color {
        label.isEmpty ? .clear : label == "Break" ? Self.breakBlue : categoryColor(label)
    }

    private func segmentFill(_ b: Block, isSelected: Bool, dim: Bool) -> Color {
        let hovered = hoveredSegment == b.start
        if b.label.isEmpty { return isSelected || hovered ? Color.primary.opacity(0.14) : .clear }
        return segmentColor(b.label).opacity(dim ? 0.4 : hovered ? 0.85 : 1)
    }

    private func segmentBar(_ b: Block, selected: Date?, width: CGFloat, day: Date) -> some View {
        let isSelected = b.start == selected
        let x = CGFloat(b.start.timeIntervalSince(day) / 86400) * width
        let w = max(2, CGFloat(b.end.timeIntervalSince(b.start) / 86400) * width)
        let tip = (b.label.isEmpty ? "Not tracked" : b.label) + " · \(clock(b.start))–\(clock(b.end))"
        return Rectangle()
            .fill(segmentFill(b, isSelected: isSelected, dim: selected != nil && !isSelected))
            .frame(width: w)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedSegment = isSelected ? nil : b.start
                stripUndo = nil
            }
            .onHover { inside in
                if inside { hoveredSegment = b.start } else if hoveredSegment == b.start { hoveredSegment = nil }
            }
            .help(tip)
            .offset(x: x)
    }

    private var dayStrip: some View {
        let day = Calendar.current.startOfDay(for: Date())
        let frac = { (d: Date) in CGFloat(d.timeIntervalSince(day) / 86400) }
        let streak = store.currentStreak + (store.todayWorkMinutes < 1 && todayFocusMinutes >= 1 ? 1 : 0)
        let segments = stripSegments
        let selected = segments.first { $0.start == selectedSegment }
            ?? selectedSegment.flatMap { t in segments.first { $0.start <= t && t < $0.end } }
        return VStack(spacing: 6) {
            HStack {
                Text("Your day")
                Spacer()
                if streak > 0 { Text("\(streak) days in a row with focus") }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06))
                    ForEach([6, 12, 18], id: \.self) { h in
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                            .offset(x: CGFloat(h) / 24 * g.size.width)
                    }
                    ForEach(segments, id: \.start) { b in
                        segmentBar(b, selected: selected?.start, width: g.size.width, day: day)
                    }
                    if let s = selected {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary, lineWidth: 2)
                            .frame(width: max(6, (frac(s.end) - frac(s.start)) * g.size.width + 4), height: g.size.height + 4)
                            .offset(x: frac(s.start) * g.size.width - 2)
                            .allowsHitTesting(false)
                    }
                    Capsule().fill(Color.primary).frame(width: 2, height: g.size.height + 6)
                        .offset(x: frac(Date()) * g.size.width - 1).allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .frame(height: 26)
            GeometryReader { g in
                ForEach([(0, "12 AM"), (6, "6 AM"), (12, "Noon"), (18, "6 PM"), (24, "12 AM")], id: \.0) { h, label in
                    Text(label)
                        .fixedSize()
                        .frame(width: 60, alignment: h == 0 ? .leading : h == 24 ? .trailing : .center)
                        .offset(x: CGFloat(h) / 24 * g.size.width - (h == 0 ? 0 : h == 24 ? 60 : 30))
                }
            }
            .frame(height: 14)
            .font(.system(size: 11))
            .foregroundStyle(Color.secondaryText)
            if let selected {
                segmentDetail(selected)
            } else {
                Text("Click any part of the bar to see what it was")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private func segmentDetail(_ b: Block) -> some View {
        let isRunning = timer.isActive && !b.label.isEmpty && Date().timeIntervalSince(b.end) < 90
        let storyBlocks = (story.story?.blocks ?? []).filter { $0.end > b.start && $0.start < b.end }
        let moments = storyBlocks.flatMap(\.moments)
            .filter { $0.end > b.start && $0.start < b.end && !$0.text.isEmpty }
            .reduce(into: [DayStory.Moment]()) { out, m in
                if !out.contains(where: { $0.text == m.text }) { out.append(m) }
            }
        let courses = Array(Set(storyBlocks.compactMap(\.course))).sorted()
        let events = Array(Set(storyBlocks.compactMap(\.event))).sorted()
        let fixes = storyBlocks.flatMap(\.fixes).filter { $0.end > b.start && $0.start < b.end }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if b.label.isEmpty {
                    Circle().strokeBorder(Color.secondaryText, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 10, height: 10)
                } else {
                    Circle().fill(segmentColor(b.label)).frame(width: 10, height: 10)
                }
                Text(b.label.isEmpty ? "Not tracked" : b.label).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                Text(hm(b.end.timeIntervalSince(b.start) / 60))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
            }
            Text(isRunning ? "Since \(clock(b.start)), still running" : "\(clock(b.start)) – \(clock(b.end))")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
            if !courses.isEmpty || !events.isEmpty {
                Text((events + courses.filter { !events.contains($0) }).joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium))
            }
            if moments.isEmpty {
                Text(b.label.isEmpty ? "Nothing was logged here." : "No notes on what was on screen for this stretch.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(moments.suffix(5))) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(clock(max(m.start, b.start))).font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color.secondaryText).frame(width: 58, alignment: .leading)
                            Text(DayStory.twelveHour(m.text)).font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if moments.count > 5 {
                        Text("\(moments.count - 5) earlier moments on the Day page")
                            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            ForEach(fixes) { f in
                Label(fixText(f), systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(settings.tags.filter { $0 != b.label }, id: \.self) { tag in
                        Button(tag) { relabel(b, as: tag, running: isRunning) }
                    }
                    if b.label != "Break" && !isRunning { Button("Break") { relabel(b, as: nil, running: false) } }
                } label: {
                    Text(b.label.isEmpty ? "Fill in…" : "Change to…").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
                if let undo = stripUndo {
                    Button("Undo") { _ = store.undoReview(undo); stripUndo = nil; refreshStory() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button("Open day") {
                    if let url = URL(string: "focus://dashboard") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(b.label.isEmpty ? Color.primary.opacity(0.05) : segmentColor(b.label).opacity(0.1)))
        .padding(.top, 4)
    }

    /// Past time is repainted (with Undo); the part inside the running
    /// block renames the timer from its start.
    private func relabel(_ b: Block, as label: String?, running: Bool) {
        if running, let label, let start = timer.sessionStartTime {
            if start.timeIntervalSince(b.start) >= 60 { _ = store.paintForReview(start: b.start, end: start, label: label) }
            timer.switchTo(label, at: start)
            stripUndo = nil
        } else {
            stripUndo = store.paintForReview(start: b.start, end: b.end, label: label)
        }
        selectedSegment = b.start
        refreshStory()
    }

    // MARK: - Controls

    private var controlBar: some View {
        FocusTransportControls(timer: timer, returnsFromBreak: true)
    }

    private var detailsButton: some View {
        Button { detent = detent == .small ? .large : .small } label: {
            Label(detent == .large ? "Hide details" : "Details", systemImage: detent == .large ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .medium)).frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondaryText)
        .help("Show or hide today's timeline and screen activity")
    }

    private func hm(_ minutes: Double) -> String {
        durationText(minutes: minutes)
    }

    private func clock(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }
}

/// Soft wash of the running category's color behind the popover's glass
/// (DESIGN.md idea 3); cross-fades when you switch.
struct CategoryWash: View {
    let color: Color
    var intensity: Double = 0.22

    var body: some View {
        ZStack {
            RadialGradient(colors: [color.opacity(intensity), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
            RadialGradient(colors: [color.opacity(intensity * 0.6), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 260)
        }
        .animation(.easeInOut(duration: 0.6), value: color)
        .allowsHitTesting(false)
    }
}

struct NativeGlassControl: ViewModifier {
    var prominent: Bool
    var tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                if prominent { content.buttonStyle(.glassProminent).tint(tint) }
                else { content.buttonStyle(.glass) }
            } else {
                if prominent { content.buttonStyle(.borderedProminent).tint(tint) }
                else { content.buttonStyle(.bordered) }
            }
        }
        .environment(\.controlActiveState, .active)
    }
}

struct FocusTransportControls: View {
    @ObservedObject var timer: TimerManager
    var returnsFromBreak = false
    var labeledBreak = true
    @Namespace private var glassNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var returning: Bool { returnsFromBreak && timer.isActive && timer.isOnBreak && !timer.currentLabel.isEmpty }
    private var tint: Color { timer.isActive && timer.isOnBreak && !returning ? TimerView.breakBlue : categoryColor(timer.currentLabel) }
    private var title: String {
        if returning { return "Back to \(timer.currentLabel)" }
        if timer.isRunning { return "Pause" }
        return timer.isActive ? "Resume" : "Start"
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 8) { buttons } }
            else { buttons }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: timer.isActive)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: timer.isOnBreak)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if timer.isActive {
                control(id: "stop", prominent: false) {
                    Button { timer.reset() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13)).frame(width: 36, height: 36)
                    }
                    .buttonBorderShape(.circle)
                    .help("Stop and save this session").accessibilityLabel("Stop")
                }
            }
            control(id: "playback", prominent: true) {
                Button {
                    if returning { timer.switchTo(timer.currentLabel) }
                    else if timer.isRunning { timer.pause() }
                    else { timer.start() }
                } label: {
                    Label {
                        Text(title).lineLimit(1).minimumScaleFactor(0.8)
                    } icon: {
                        Image(systemName: returning ? "arrow.uturn.backward" : timer.isRunning ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonBorderShape(.capsule).help(title)
            }
            if timer.isActive && !timer.isOnBreak {
                control(id: "break", prominent: false) {
                    Button { timer.startManualBreak(minutes: 0) } label: {
                        if labeledBreak {
                            Label("Break", systemImage: "cup.and.saucer").font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 4).frame(height: 36)
                        } else {
                            Image(systemName: "cup.and.saucer").font(.system(size: 14)).frame(width: 36, height: 36)
                        }
                    }
                    .buttonBorderShape(labeledBreak ? .capsule : .circle)
                    .help("Take a break").accessibilityLabel("Take a break")
                }
            }
        }
    }

    @ViewBuilder
    private func control<V: View>(id: String, prominent: Bool, @ViewBuilder content: () -> V) -> some View {
        if #available(macOS 26.0, *) {
            content().modifier(NativeGlassControl(prominent: prominent, tint: tint))
                .glassEffectID(id, in: glassNamespace)
        } else { content().modifier(NativeGlassControl(prominent: prominent, tint: tint)) }
    }
}

/// Floating glass capsule at the bottom of big windows, like Podcasts' Now
/// Playing bar: what's running, for how long, and the three controls.
struct NowPlayingBar: View {
    @ObservedObject var timer: TimerManager

    private var accent: Color {
        if timer.isActive && timer.isOnBreak { return TimerView.breakBlue }
        return timer.currentLabel.isEmpty ? .accentColor : categoryColor(timer.currentLabel)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(accent).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.isActive ? (timer.isOnBreak ? "Break" : timer.currentLabel) : "Nothing running")
                    .font(.system(size: 14, weight: .semibold))
                if let start = timer.sessionStartTime, timer.isActive {
                    Text("Since \(start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(timer.timeString)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .fixedSize()
            FocusTransportControls(timer: timer).frame(minWidth: 250, maxWidth: 270)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 60)
        .frame(maxWidth: 580)
        .modifier(FloatingGlass())
        .padding(.bottom, 14)
    }
}

struct FloatingGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        } else {
            content.background(Capsule().fill(.regularMaterial)).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}


/// "class 1–1:40, then leisure" → a preview of the blocks → Apply. Past
/// stretches are repainted (Undo restores them); a part reaching into what's
/// running now switches or carves the running block, which Undo can't revert,
/// so the preview says so.
@available(macOS 26.0, *)
struct LogFixView: View {
    @ObservedObject var timer: TimerManager
    @ObservedObject var store: SessionStore
    let categories: [String]

    /// What the preview was computed against; Apply refuses if it moved.
    private struct Basis: Equatable {
        let rows: [String]
        let running: String
    }

    private enum Step {
        case typing(String?)
        case reading
        case preview([LogCorrection.Block], Basis)
        case done([SessionStore.ReviewUndo], changedRunning: Bool, failed: Bool)
    }
    @State private var text = ""
    @State private var step: Step = .typing(nil)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch step {
            case .typing(let note):
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble").foregroundStyle(Color.secondaryText)
                    TextField("Correct the log: “class 1–1:40, then leisure”", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit(read)
                }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Color.secondaryText) }
            case .reading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading “\(text)”…").font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            case .preview(let blocks, let basis):
                Text("“\(text)”").font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(2)
                ForEach(blocks, id: \.start) { b in
                    HStack(spacing: 8) {
                        Text("\(clock(b.start))–\(clock(b.end))").font(.system(size: 12).monospacedDigit())
                            .frame(width: 128, alignment: .leading)
                        Circle().fill(b.category.map(categoryColor) ?? TimerView.breakBlue).frame(width: 8, height: 8)
                        Text(b.category ?? "Break").font(.system(size: 13, weight: .medium))
                        if touchesRunning(b) {
                            Text("now").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
                if blocks.contains(where: touchesRunning) {
                    Text("This changes what's running now too; Undo won't revert that part.")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Apply") { apply(blocks, basis: basis) }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { step = .typing(nil) }
                }
            case .done(let undos, let changedRunning, let failed):
                HStack {
                    Label(failed ? "Partly fixed" : "Fixed", systemImage: failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? .orange : .green)
                    Spacer()
                    if !undos.isEmpty && !changedRunning {
                        Button("Undo") {
                            let ok = undos.reversed().allSatisfy { store.undoReview($0) }
                            step = .typing(ok ? nil : "Couldn't undo all of it: the log changed since.")
                        }
                    }
                    Button("New") { text = ""; step = .typing(nil) }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(scheme == .dark ? .white.opacity(0.07) : .white.opacity(0.5)))
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private func touchesRunning(_ b: LogCorrection.Block) -> Bool {
        guard timer.isActive, let start = timer.sessionStartTime else { return false }
        return b.end.timeIntervalSince(max(b.start, start)) >= 60
    }

    private func read() {
        let said = text.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        step = .reading
        let now = Date()
        let live = [timer.currentInProgressSession, timer.currentInProgressBreak].compactMap { $0 }
            .map { WorkSession(startTime: $0.startTime, durationMinutes: now.timeIntervalSince($0.startTime) / 60,
                               type: $0.type, label: $0.label) }
        let log = (store.sessions + live)
            .filter { TimeIntegrity.end(of: $0) > now.addingTimeInterval(-24 * 3600) }
            .sorted { $0.startTime < $1.startTime }
            .map { (start: $0.startTime, end: TimeIntegrity.end(of: $0), label: $0.type.isBreak ? "Break" : ($0.label ?? "Focus")) }
        Task { @MainActor in
            let blocks = await LogCorrection.propose(said, log: log, now: now, categories: categories)
            guard let blocks else { return step = .typing("Couldn't read that. Try times like 1:00–1:40.") }
            step = blocks.isEmpty ? .typing("Didn't find any times in that. Try “Class 1–1:40, then Leisure”.")
                : .preview(blocks, basis(for: blocks))
        }
    }

    /// Saved rows the blocks touch, plus what's running and how.
    private func basis(for blocks: [LogCorrection.Block]) -> Basis {
        let lo = blocks.map(\.start).min() ?? Date(), hi = blocks.map(\.end).max() ?? Date()
        let rows = store.sessions.filter { TimeIntegrity.end(of: $0) > lo && $0.startTime < hi }
            .map { "\($0.id)|\($0.startTime.timeIntervalSince1970)|\($0.durationMinutes)|\($0.label ?? "")|\($0.type)" }
        let running = "\(timer.isActive)|\(timer.isRunning)|\(timer.isOnBreak)|\(timer.currentLabel)|\(timer.sessionStartTime?.timeIntervalSince1970 ?? 0)"
        return Basis(rows: rows.sorted(), running: running)
    }

    private func apply(_ blocks: [LogCorrection.Block], basis: Basis) {
        guard self.basis(for: blocks) == basis else {
            return step = .typing("The log changed while this was open. Press Return to read it again.")
        }
        var undos: [SessionStore.ReviewUndo] = []
        var changedRunning = false
        var failed = false
        let now = Date()
        for b in blocks.sorted(by: { $0.start < $1.start }) {
            let runStart = timer.isActive ? timer.sessionStartTime : nil
            let savedEnd = min(b.end, runStart ?? b.end)
            if savedEnd.timeIntervalSince(b.start) >= 60 {
                guard let u = store.paintForReview(start: b.start, end: savedEnd, label: b.category) else {
                    failed = true
                    break
                }
                undos.append(u)
            }
            guard let rs = runStart, b.end.timeIntervalSince(max(b.start, rs)) >= 60 else { continue }
            let from = max(b.start, rs)
            let running: String? = timer.isOnBreak ? nil : timer.currentLabel
            if b.end >= now.addingTimeInterval(-90) {
                guard b.category != running || from.timeIntervalSince(rs) > 60 else { continue }
                if let c = b.category { timer.switchTo(c, at: from) } else { timer.startManualBreak(minutes: 0, at: from) }
                changedRunning = true
            } else if timer.isRunning {
                timer.carveOut(from: from, to: b.end, as: b.category)
                changedRunning = true
            } else {
                failed = true
            }
        }
        step = .done(undos, changedRunning: changedRunning, failed: failed)
    }
}

/// Where the running subject was left last time; a tap reopens the page or app.
struct WhereWasIRow: View {
    let line: WhereWasI.Line

    var body: some View {
        Button {
            if let url = line.url {
                NSWorkspace.shared.open(url)
            } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: line.bundle) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).padding(.top, 1)
                Text(line.text).font(.system(size: 11.5)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open where you left off")
    }
}
