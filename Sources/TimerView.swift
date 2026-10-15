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
    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared
    @ObservedObject private var watcher = ScreenWatcher.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedFocusTotals: [String: Double] = [:]
    @State private var fixingOverlap: SessionOverlap?
    /// Minutes today the screen showed a life category during focus blocks.
    @State private var possibleDrift: Double = 0

    static let breakBlue = Color(red: 0.27, green: 0.62, blue: 0.83)

    private var onBreak: Bool { timer.isActive && timer.isOnBreak }

    /// The running category's color: ring, primary button, wash.
    var accent: Color {
        if onBreak { return Self.breakBlue }
        return timer.currentLabel.isEmpty ? .accentColor : categoryColor(timer.currentLabel)
    }

    private var isCountingUp: Bool {
        timer.isActive && FocusCategories.isOpenEnded(total: timer.totalTime)
            && FocusCategories.countdown(total: timer.totalTime) == 0
    }

    private var todayFocusMinutes: Double {
        todayFocusByCategory.values.reduce(0, +)
    }

    private var todayFocusByCategory: [String: Double] {
        var totals = savedFocusTotals
        let live = FocusStats.focusCategoryMinutes([], live: timer.currentInProgressSession,
                                                  on: Date(), through: Date(), lifeTags: Set(settings.lifeTags))
        for (label, minutes) in live { totals[label, default: 0] += minutes }
        return totals
    }

    private var running: String? { timer.isActive ? (onBreak ? "Break" : timer.currentLabel) : nil }

    var body: some View {
        VStack(spacing: 14) {
            hero
            focusTotals
            if !timer.isActive {
                if !FocusCategories.isLife(timer.currentLabel) { presets }
                startChips
            }
            attention
            if detent == .large {
                dayStrip
                onScreenNow
                todayLog
                if #available(macOS 26.0, *), LogCorrection.available {
                    LogFixView(timer: timer, store: store, categories: settings.tags)
                }
            }
            controlBar
            detailsButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .onReceive(store.$sessions) { refreshFocusTotals($0) }
        .task {
            while !Task.isCancelled {
                refreshDrift()
                try? await Task.sleep(for: .seconds(60))
            }
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

    private func refreshFocusTotals(_ sessions: [WorkSession]) {
        savedFocusTotals = FocusStats.focusCategoryMinutes(sessions, on: Date(), through: Date(), lifeTags: Set(settings.lifeTags))
    }

    @ViewBuilder
    private var focusTotals: some View {
        let totals = todayFocusByCategory.filter { $0.value > 2 }
        let labels = settings.tags.filter { totals[$0] != nil }
            + totals.keys.filter { !settings.tags.contains($0) }.sorted()
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Focus today").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                    Spacer()
                    if possibleDrift >= 1 {
                        Text("\(hm(possibleDrift)) possibly off-task")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .help("The screen showed Leisure, Reading or Admin during focus blocks. Not taken off your focus time: the screen can be wrong, and work on paper or the iPad doesn't show here.")
                    }
                }
                FlowLayout(spacing: 8) {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
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
                    Text("of \(settings.dailyGoal)h").font(.system(size: 11)).foregroundStyle(.secondary)
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
            ForEach(focus, id: \.self) { t in Button(t) { pick(t) } }
            if !life.isEmpty {
                Divider()
                ForEach(life, id: \.self) { t in Button(t) { pick(t) } }
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

    /// Time since today's Adderall, once it's logged (Health tab), for 16 hours.
    private var doseLine: some View {
        TimelineView(.everyMinute) { ctx in
            if let dose = health.latestToday(.adderall, now: ctx.date),
               ctx.date.timeIntervalSince(dose.date) < 16 * 3600 {
                Label("Adderall \(durationText(minutes: (ctx.date.timeIntervalSince(dose.date) / 60).rounded(.down))) ago",
                      systemImage: "pills")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(dose.kind.displayName) at \(dose.date.formatted(date: .omitted, time: .shortened))")
            }
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

    /// Nothing running: the focus categories, since picking one is next.
    /// Life categories are in the title menu.
    private var startChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(settings.tags.filter { !settings.lifeTags.contains($0) }, id: \.self) { tag in
                chip(tag, color: categoryColor(tag), selected: timer.currentLabel == tag) { pick(tag) }
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
            .frame(height: 30)
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
        case overlap(SessionOverlap)
        case yesterday(Double)
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
        if let o = store.overlaps.first { return .overlap(o) }
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
        case .overlap(let o):
            attentionRow(color: .orange, icon: "square.on.square", text: overlapText(o), action: "Fix") {
                fixingOverlap = o
            }
            .popover(isPresented: Binding(get: { fixingOverlap != nil }, set: { if !$0 { fixingOverlap = nil } }),
                     arrowEdge: .bottom) {
                if let o = fixingOverlap { OverlapFixView(overlap: o, store: store) }
            }
        case .yesterday(let m):
            attentionRow(color: .orange, icon: "clock.badge.questionmark", text: "Fill in \(hm(m)) from yesterday",
                         action: "Review") { showDayReview = true }
        case nil:
            EmptyView()
        }
    }

    private func overlapText(_ o: SessionOverlap) -> String {
        let name = { (s: WorkSession) in s.type.isBreak ? "Break" : (s.label ?? "Focus") }
        let when = "\(OverlapFixView.day(o.start))\(clock(o.start))–\(clock(o.end))"
        return o.sameLabel ? "\(name(o.first)) counted twice, \(when)" : "\(name(o.first)) and \(name(o.second)) overlap, \(when)"
    }

    private func attentionRow(color: Color, icon: String, text: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            Text(text).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.85)
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

    private var dayStrip: some View {
        let day = Calendar.current.startOfDay(for: Date())
        let frac = { (d: Date) in CGFloat(d.timeIntervalSince(day) / 86400) }
        return VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    ForEach(todayBlocks, id: \.start) { b in
                        Rectangle()
                            .fill(b.label == "Break" ? Self.breakBlue.opacity(0.5) : categoryColor(b.label))
                            .frame(width: max(1, (frac(b.end) - frac(b.start)) * g.size.width))
                            .help("\(b.label) · \(clock(b.start))–\(clock(b.end))")
                            .offset(x: frac(b.start) * g.size.width)
                    }
                    Capsule().fill(Color.primary).frame(width: 2, height: 14).offset(x: frac(Date()) * g.size.width - 1)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            ZStack {
                HStack {
                    Text("12 AM")
                    Spacer()
                    let streak = store.currentStreak + (store.todayWorkMinutes < 1 && todayFocusMinutes >= 1 ? 1 : 0)
                    if streak > 0 { Text("\(streak)-day streak") } else { Text("12 AM") }
                }
                Text("Noon")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var onScreenNow: some View {
        let now = Date()
        if settings.screenWatch,
           let block = watcher.activities(from: Calendar.current.startOfDay(for: now), to: now)
               .last(where: { $0.device == nil && now.timeIntervalSince($0.end) < 120 }) {
            let notes = watcher.notes(for: block)
            let heading = notes?.title ?? block.spans.last?.title ?? block.category ?? ""
            let differs = block.category != nil && running != nil && running != "Break" && block.category != running
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(block.category.map(categoryColor) ?? .gray).frame(width: 7, height: 7)
                    Text(differs ? "Screen looks like \(block.category!)" : "On screen")
                    Spacer(minLength: 4)
                    if differs, let c = block.category {
                        Button("Switch") { timer.switchTo(c, at: block.start) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(categoryColor(c).opacity(0.2)))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Text(EveningReviewView.sentenceCase(heading)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let line = notes?.bullets.last ?? block.spans.last?.summary, !line.isEmpty,
                   !line.localizedCaseInsensitiveContains(heading) {
                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardFill))
        }
    }

    @Environment(\.colorScheme) private var scheme
    /// Content cards are lighter than the control well, so the two don't read as one.
    private var cardFill: Color { scheme == .dark ? .white.opacity(0.07) : .white.opacity(0.5) }

    private var todayLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            let blocks = Array(merged(todayBlocks).reversed().prefix(4))
            ForEach(blocks, id: \.start) { b in
                HStack(spacing: 10) {
                    Text(clock(b.start)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    Circle().fill(b.label == "Break" ? Self.breakBlue : categoryColor(b.label)).frame(width: 8, height: 8)
                    Text(b.label).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(hm(b.end.timeIntervalSince(b.start) / 60)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(height: 28)
            }
        }
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
                        Image(systemName: "cup.and.saucer").font(.system(size: 14)).frame(width: 36, height: 36)
                    }
                    .buttonBorderShape(.circle)
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
            FocusTransportControls(timer: timer).frame(maxWidth: 200)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 60)
        .frame(maxWidth: 540)
        .modifier(FloatingGlass())
        .padding(.bottom, 14)
    }
}

struct FloatingGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule()).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        } else {
            content.background(Capsule().fill(.regularMaterial)).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}


/// Two saved blocks covering the same time. Same category: merge into one.
/// Different: the user says which it was. Undo restores both as they were.
struct OverlapFixView: View {
    let overlap: SessionOverlap
    @ObservedObject var store: SessionStore
    @State private var undo: SessionStore.ReviewUndo?
    @State private var failed = false

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "" }
        if cal.isDateInYesterday(d) { return "yesterday " }
        return d.formatted(.dateTime.weekday(.abbreviated)) + " "
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    private func name(_ s: WorkSession) -> String? { s.type.isBreak ? nil : s.label }
    private func title(_ s: WorkSession) -> String { name(s) ?? "Break" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overlap.sameLabel ? "Saved twice" : "Two blocks at once").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                ForEach([overlap.first, overlap.second], id: \.id) { s in
                    HStack(spacing: 6) {
                        Circle().fill(s.type.isBreak ? TimerView.breakBlue : categoryColor(s.label ?? "")).frame(width: 7, height: 7)
                        Text("\(title(s))  \(Self.day(s.startTime))\(clock(s.startTime))–\(clock(TimeIntegrity.end(of: s)))")
                            .font(.system(size: 12).monospacedDigit())
                    }
                }
            }
            if undo != nil {
                HStack {
                    Label("Fixed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Undo") {
                        if let u = undo, store.undoReview(u) { undo = nil } else { failed = true }
                    }
                }
                .font(.system(size: 12, weight: .medium))
            } else if overlap.sameLabel {
                Text("Merge into one \(title(overlap.first)) block, \(clock(overlap.union.start))–\(clock(overlap.union.end))?")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Merge") { apply(keep: nil) }.keyboardShortcut(.defaultAction)
                    Button("Leave as is") { store.leaveOverlap(overlap) }
                }
            } else {
                Text("Which was it, \(clock(overlap.start))–\(clock(overlap.end))?")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button(title(overlap.first)) { apply(keep: overlap.first) }
                    Button(title(overlap.second)) { apply(keep: overlap.second) }
                    Button("Leave as is") { store.leaveOverlap(overlap) }
                }
            }
            if undo == nil, let wide = [overlap.first, overlap.second]
                .map({ ($0, TimeIntegrity.overlapCount($0, in: store.overlaps)) })
                .filter({ $0.1 >= 3 }).max(by: { $0.1 < $1.1 }) {
                Divider()
                Text("\(title(wide.0)) \(Self.day(wide.0.startTime))\(clock(wide.0.startTime))–\(clock(TimeIntegrity.end(of: wide.0))) overlaps \(wide.1) blocks.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove that \(title(wide.0)) block") { apply(keep: nil, removing: wide.0) }
            }
            if failed {
                Text("Couldn't change it: the log changed since, or saving failed.")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func apply(keep: WorkSession?, removing: WorkSession? = nil) {
        if let u = store.fixOverlap(overlap, keep: keep, removing: removing) { undo = u } else { failed = true }
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

    private enum Step {
        case typing(String?)
        case reading
        case preview([LogCorrection.Block])
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
                    TextField("Fix the log: “class 1–1:40, then leisure”", text: $text)
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
            case .preview(let blocks):
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
                    Button("Apply") { apply(blocks) }.keyboardShortcut(.defaultAction)
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
            step = blocks.isEmpty ? .typing("Didn't find any times in that. Try “Class 1–1:40, then Leisure”.") : .preview(blocks)
        }
    }

    private func apply(_ blocks: [LogCorrection.Block]) {
        var undos: [SessionStore.ReviewUndo] = []
        var changedRunning = false
        var failed = false
        let now = Date()
        for b in blocks.sorted(by: { $0.start < $1.start }) {
            let runStart = timer.isActive ? timer.sessionStartTime : nil
            let savedEnd = min(b.end, runStart ?? b.end)
            if savedEnd.timeIntervalSince(b.start) >= 60 {
                if let u = store.paintForReview(start: b.start, end: savedEnd, label: b.category) { undos.append(u) } else { failed = true }
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
