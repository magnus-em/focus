import SwiftUI
import FocusCore

struct TimeGap: Identifiable, Equatable {
    let start: Date
    let end: Date
    /// Nobody was at the Mac for this whole stretch.
    var away = false
    var id: Date { start }
    var minutes: Double { end.timeIntervalSince(start) / 60 }

    /// Cut at the edges of away spans (≥ 30 min) so "at the Mac" and
    /// "away" parts get filled separately.
    func splitByPresence(_ monitor: PresenceMonitor = .shared) -> [TimeGap] {
        let spans = monitor.spans(from: start, to: end, minMinutes: 30)
        guard !spans.isEmpty else { return [self] }
        var out: [TimeGap] = []
        var cursor = start
        for s in spans {
            if s.start.timeIntervalSince(cursor) >= 300 { out.append(TimeGap(start: cursor, end: s.start)) }
            out.append(TimeGap(start: max(cursor, s.start), end: s.end, away: true))
            cursor = s.end
        }
        if end.timeIntervalSince(cursor) >= 300 { out.append(TimeGap(start: cursor, end: end)) }
        return out
    }
}

extension SessionStore {
    /// Untracked stretches of `minMinutes`+ in [from, to), counting every
    /// session (focus, life, break) plus any live ones as tracked.
    func untrackedGaps(from: Date, to: Date, live: [WorkSession] = [], minMinutes: Double = 5) -> [TimeGap] {
        let intervals = (sessions + live)
            .map { ($0.startTime, $0.startTime.addingTimeInterval($0.durationMinutes * 60)) }
            .filter { $0.1 > from && $0.0 < to }
            .sorted { $0.0 < $1.0 }
        var out: [TimeGap] = []
        var cursor = from
        for (s, e) in intervals {
            if s.timeIntervalSince(cursor) >= minMinutes * 60 { out.append(TimeGap(start: cursor, end: min(s, to))) }
            cursor = max(cursor, e)
        }
        if to.timeIntervalSince(cursor) >= minMinutes * 60 { out.append(TimeGap(start: cursor, end: to)) }
        return out
    }

    /// The window the morning review covers: all of yesterday through now.
    func reviewWindow(now: Date = Date()) -> (from: Date, to: Date) {
        let cal = Calendar.current
        return (cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!, now)
    }

    /// Labels most often tracked at this gap's time of day over the last
    /// three weeks, best first. Break is returned as nil.
    func suggestions(for gap: TimeGap, tags: [String], limit: Int = 3) -> [String?] {
        let cal = Calendar.current
        let mid = gap.start.addingTimeInterval(gap.end.timeIntervalSince(gap.start) / 2)
        let midSec = mid.timeIntervalSince(cal.startOfDay(for: mid))
        let since = cal.date(byAdding: .day, value: -21, to: gap.start)!
        var counts: [String: Int] = [:]
        for s in sessions where s.startTime >= since && s.startTime < gap.start {
            let a = s.startTime.timeIntervalSince(cal.startOfDay(for: s.startTime))
            let b = a + s.durationMinutes * 60
            if (a...b).contains(midSec) || (a...b).contains(midSec + 86400) {
                counts[(s.type != .work) ? "" : (s.label ?? ""), default: 0] += 1
            }
        }
        var ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key).filter { $0.isEmpty || tags.contains($0) }
        let hour = cal.component(.hour, from: mid)
        if (hour < 6 || gap.minutes >= 300), tags.contains("Sleep") {
            ranked.removeAll { $0 == "Sleep" }
            ranked.insert("Sleep", at: 0)
        }
        return ranked.prefix(limit).map { $0.isEmpty ? nil : $0 }
    }

    /// Untracked minutes of one calendar day (up to now for today).
    func untrackedMinutes(on day: Date, live: [WorkSession] = [], now: Date = Date()) -> Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = min(cal.date(byAdding: .day, value: 1, to: start)!, now)
        return untrackedGaps(from: start, to: end, live: live).reduce(0) { $0 + $1.minutes }
    }

    /// Logs [start, end) as `label` (nil = break), split at midnight so
    /// each day owns its own part.
    func fill(start: Date, end: Date, label: String?) {
        let cal = Calendar.current
        var s = start
        while s < end {
            let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: s))!
            let e = min(end, midnight)
            if e.timeIntervalSince(s) >= 60 {
                addSession(WorkSession(startTime: s, durationMinutes: e.timeIntervalSince(s) / 60,
                                       type: label == nil ? .shortBreak : .work, label: label))
            }
            s = e
        }
    }
}

/// Morning pass over yesterday + last night: every untracked hole, with
/// likely categories first, so the full 24h gets accounted for.
struct DayReviewView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @Binding var isShowing: Bool

    // Snapshotted on open: re-deriving from the ticking timer every second
    // made rows and suggestions jitter.
    private let live: [WorkSession]
    private let window: (from: Date, to: Date)

    @State private var filledMinutes: Double = 0

    init(store: SessionStore, settings: AppSettings, timer: TimerManager, isShowing: Binding<Bool>) {
        self.store = store
        self.settings = settings
        _isShowing = isShowing
        let live = [timer.currentInProgressSession, timer.currentInProgressBreak].compactMap { $0 }
        self.live = live
        let w = store.reviewWindow()
        self.window = (w.from, live.map(\.startTime).min().map { min($0, w.to) } ?? w.to)
    }

    private var gaps: [TimeGap] {
        store.untrackedGaps(from: window.from, to: window.to, live: live).flatMap { $0.splitByPresence() }
    }

    var body: some View {
        let gaps = gaps
        let untracked = gaps.reduce(0) { $0 + $1.minutes }

        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fill in yesterday")
                        .font(.system(size: 15, weight: .bold))
                    Text(untracked >= 1 ? subtitle : "Every minute is accounted for.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { isShowing = false }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            DayStrip(from: window.from, to: window.to, sessions: store.sessions + live, gaps: gaps)
                .frame(height: 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()

            if gaps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text(filledMinutes > 0 ? "Filled \(fmt(filledMinutes)). All 24 hours tracked."
                                           : "No holes. Nice.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(gaps) { gap in
                            GapRow(gap: gap,
                                   suggestions: store.suggestions(for: gap, tags: settings.tags),
                                   tags: settings.tags) { start, end, label in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    store.fill(start: start, end: end, label: label)
                                    filledMinutes += end.timeIntervalSince(start) / 60
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var subtitle: String {
        let yesterday = store.untrackedMinutes(on: window.from, live: live, now: window.to)
        let today = store.untrackedMinutes(on: window.to, live: live, now: window.to)
        let name = window.from.formatted(.dateTime.weekday(.wide))
        return "\(name): \(fmt(yesterday)) of 24h untracked · today so far: \(fmt(today))"
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(mn)m"
    }
}

private struct GapRow: View {
    let gap: TimeGap
    let suggestions: [String?]
    let tags: [String]
    let onFill: (Date, Date, String?) -> Void

    @State private var until: Date
    @State private var showAll = false

    init(gap: TimeGap, suggestions: [String?], tags: [String], onFill: @escaping (Date, Date, String?) -> Void) {
        self.gap = gap
        self.suggestions = suggestions
        self.tags = tags
        self.onFill = onFill
        _until = State(initialValue: gap.end)
    }

    private let breakColor = Color(red: 0.27, green: 0.62, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(clock(gap.start))
                Text("–").foregroundStyle(.tertiary)
                DatePicker("", selection: $until, in: gap.start.addingTimeInterval(60)...gap.end,
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Fill only part of this gap; the rest stays open")
                Spacer()
                if gap.away {
                    Label("Away from Mac", systemImage: "moon.zzz")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("The Mac was locked, asleep or untouched for this whole stretch")
                }
                Text(fmt(until.timeIntervalSince(gap.start) / 60))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())

            FlowLayout(spacing: 5) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                    chip(s ?? "Break", color: s.map(categoryColor) ?? breakColor, primary: i == 0) {
                        onFill(gap.start, until, s)
                    }
                }
                if showAll {
                    ForEach(tags.filter { t in !suggestions.contains(where: { $0 == t }) }, id: \.self) { t in
                        chip(t, color: categoryColor(t), primary: false) { onFill(gap.start, until, t) }
                    }
                    if !suggestions.contains(where: { $0 == nil }) {
                        chip("Break", color: breakColor, primary: false) { onFill(gap.start, until, nil) }
                    }
                } else {
                    Button("More…") { withAnimation(.easeOut(duration: 0.15)) { showAll = true } }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .onAppear { if suggestions.isEmpty { showAll = true } }
    }

    private func chip(_ title: String, color: Color, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if primary { Image(systemName: "sparkles").font(.system(size: 8)) }
                Text(title)
            }
        }
        .font(.system(size: 11, weight: primary ? .semibold : .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(primary ? 0.28 : 0.15)))
        .foregroundStyle(color)
        .buttonStyle(.plain)
    }

    private func clock(_ d: Date) -> String {
        let cal = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        return cal.isDateInToday(d) || cal.isDateInYesterday(d) ? t : d.formatted(.dateTime.weekday(.abbreviated)) + " " + t
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(mn)m"
    }
}

/// Compact horizontal timeline: tracked blocks in their category colours,
/// holes as hatched grey, midnight marked.
private struct DayStrip: View {
    let from: Date
    let to: Date
    let sessions: [WorkSession]
    let gaps: [TimeGap]

    var body: some View {
        GeometryReader { geo in
            let total = to.timeIntervalSince(from)
            let x: (Date) -> CGFloat = { CGFloat(max(0, min(total, $0.timeIntervalSince(from))) / total) * geo.size.width }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                ForEach(sessions.filter { $0.startTime < to && $0.startTime.addingTimeInterval($0.durationMinutes * 60) > from }) { s in
                    let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
                    Rectangle()
                        .fill((s.type != .work) ? Color(red: 0.27, green: 0.62, blue: 0.83) : categoryColor(s.label ?? ""))
                        .frame(width: max(1, x(e) - x(s.startTime)), height: 14)
                        .offset(x: x(s.startTime))
                }
                ForEach(gaps) { g in
                    Rectangle()
                        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                        .frame(width: max(1, x(g.end) - x(g.start)), height: 14)
                        .offset(x: x(g.start))
                }
                if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: from)),
                   midnight < to {
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5, height: 14).offset(x: x(midnight))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// Morning free recall: write yesterday from memory first, then see what
/// was actually tracked (and what you wrote after each block) side by side.
struct YesterdayRecallView: View {
    @ObservedObject var recall: RecallStore
    @ObservedObject var store: SessionStore
    let journalShortcut: String
    let onFillGaps: () -> Void
    let onDone: () -> Void

    @State private var text = ""
    @State private var revealed = false
    @State private var journalStatus: String?
    @StateObject private var dictation = Dictation()
    @ObservedObject private var screen = ScreenWatcher.shared
    @State private var showFullRecollection = false
    @FocusState private var focused: Bool

    private let day: Date = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }
    private var weekday: String { day.formatted(.dateTime.weekday(.wide)) }

    /// Yesterday's activity-log blocks that got notes, in order.
    private var loggedBlocks: [(activity: ScreenActivity, notes: ScreenWatcher.ActivityNotes)] {
        screen.activities(from: day, to: dayEnd).compactMap { a in screen.notes(for: a).map { (a, $0) } }
    }

    /// Titles only, as cues: the bullets would give the answers away.
    private var cueList: some View {
        let cues = loggedBlocks.sorted { $0.activity.minutes > $1.activity.minutes }.prefix(8)
            .sorted { $0.activity.start < $1.activity.start }
        return VStack(alignment: .leading, spacing: 3) {
            Text("FROM YOUR SCREEN LOG")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            ForEach(Array(cues.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 6) {
                    Circle().fill(c.activity.category.map(categoryColor) ?? .secondary).frame(width: 5, height: 5)
                    Text(c.notes.title).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Text(minutesLabel(c.activity.minutes))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func minutesLabel(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(mn)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if revealed { revealStage } else { writeStage }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var writeStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sunrise")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.orange)
                .padding(.top, 18)
            Text("What did you learn \(weekday)?")
                .font(.system(size: 17, weight: .semibold, design: .serif))
            Text(loggedBlocks.isEmpty
                 ? "From memory, before you look: what you worked on, what clicked, what's still fuzzy, what stood out. Talk it through or type."
                 : "For each of these, say what you learned: the ideas, what clicked, what's still fuzzy. The notes come after.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plan = EveningLog.entry(for: day)?.firstTask, !plan.isEmpty {
                Label("Last night you planned to start with: \(plan)", systemImage: "moon.stars")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.indigo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !loggedBlocks.isEmpty { cueList }
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .focused($focused)
                .overlay(alignment: .bottomTrailing) { micButton.padding(8) }
            if let err = dictation.error {
                Text(err)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(journalShortcut.isEmpty ? "Free recall first; the timeline comes after."
                 : "Free recall first; the timeline comes after. Also saved to Journal via “\(journalShortcut)”.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            HStack {
                Button("Skip today") {
                    recall.skipYesterdayRecall()
                    onDone()
                }
                .controlSize(.small)
                Spacer()
                Button("Reveal \(weekday)") {
                    dictation.stop()
                    recall.addNote(kind: .yesterday, text: text)
                    sendToJournal()
                    withAnimation(.easeOut(duration: 0.2)) { revealed = true }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 16)
        .onAppear { focused = true }
        .onDisappear { dictation.stop() }
    }

    private var micButton: some View {
        Button {
            if dictation.isListening { dictation.stop(); return }
            let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dictation.start { spoken in text = base.isEmpty ? spoken : base + " " + spoken }
        } label: {
            Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(dictation.isListening ? Color.red : Color.orange)
                .symbolEffect(.pulse, isActive: dictation.isListening)
        }
        .buttonStyle(.plain)
        .help(dictation.isListening ? "Stop dictating" : "Talk it through")
    }

    private func sendToJournal() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !journalShortcut.isEmpty, !body.isEmpty else { return }
        let entry = "What I learned, \(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))\n\n\(body)"
        journalStatus = "Sending to Journal…"
        Task {
            let err = await JournalShortcut.send(entry, shortcut: journalShortcut)
            journalStatus = err.map { "Not sent to Journal: \($0)" } ?? "Saved to Journal"
        }
    }

    private var blocks: [WorkSession] {
        store.sessions
            .filter { $0.startTime < dayEnd && $0.startTime.addingTimeInterval($0.durationMinutes * 60) > day }
            .sorted { $0.startTime < $1.startTime }
    }

    private var revealStage: some View {
        let gaps = store.untrackedGaps(from: day, to: dayEnd)
        let untracked = gaps.reduce(0) { $0 + $1.minutes }
        let sessionNotes = recall.notes(on: day, kind: .session)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(weekday), as tracked")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { onDone() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 14)

            DayStrip(from: day, to: dayEnd, sessions: blocks, gaps: gaps)
                .frame(height: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text("YOU REMEMBERED")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(showFullRecollection ? nil : 3)
                    .onTapGesture { showFullRecollection.toggle() }
                if let journalStatus {
                    Label(journalStatus, systemImage: journalStatus.hasPrefix("Not") ? "exclamationmark.triangle" : "book.closed")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !loggedBlocks.isEmpty {
                        Text("WHAT THE SCREEN LOG NOTED")
                            .font(.system(size: 8.5, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        ForEach(Array(loggedBlocks.enumerated()), id: \.offset) { _, b in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(b.activity.start.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Circle().fill(b.activity.category.map(categoryColor) ?? .secondary).frame(width: 6, height: 6)
                                    Text(b.notes.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(minutesLabel(b.activity.minutes))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(Array(b.notes.bullets.enumerated()), id: \.offset) { _, line in
                                    Text("• \(line)")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.primary.opacity(0.8))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Text("AS TRACKED")
                            .font(.system(size: 8.5, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    ForEach(blocks) { s in
                        let note = sessionNotes.first { n in
                            n.sessionStart.map { abs($0.timeIntervalSince(s.startTime)) < 90 } ?? false
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(s.startTime.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Circle()
                                    .fill(s.type != .work ? Color(red: 0.27, green: 0.62, blue: 0.83) : categoryColor(s.label ?? ""))
                                    .frame(width: 6, height: 6)
                                Text(s.type != .work ? "Break" : (s.label ?? "Focus"))
                                    .font(.system(size: 11.5, weight: s.isFocus ? .semibold : .regular))
                                Spacer()
                                Text("\(Int(s.durationMinutes) / 60 > 0 ? "\(Int(s.durationMinutes) / 60)h " : "")\(Int(s.durationMinutes) % 60)m")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let note {
                                Text("“\(note.text)”")
                                    .font(.system(size: 10.5))
                                    .italic()
                                    .foregroundStyle(recallPurple)
                                    .padding(.leading, 58)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Text("Anything missing from your version? No need to score it — noticing is the practice.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if untracked >= 15 {
                    Button("Fill \(Int(untracked) / 60)h \(Int(untracked) % 60)m untracked") { onFillGaps() }
                        .controlSize(.small)
                }
                Spacer()
                Button("Continue") { onDone() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Evening review

struct EveningEntry: Codable {
    var wentWell = ""
    var inTheWay = ""
    var firstTask = ""
    var savedAt = Date()
}

/// Evening reflections by day, `Focus/evening.json`, this Mac only. The
/// morning recall shows last night's "start with".
enum EveningLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("evening.json")
    }()

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func all() -> [String: EveningEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: EveningEntry].self, from: data)) ?? [:]
    }

    static func entry(for day: Date) -> EveningEntry? { all()[key(day)] }

    static func save(_ e: EveningEntry, for day: Date) {
        var m = all()
        m[key(day)] = e
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(m) { try? data.write(to: url, options: .atomic) }
    }
}

@MainActor
final class EveningReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = EveningReviewWindowController()
    private var window: NSWindow?

    func open(store: SessionStore, days: DayStore, settings: AppSettings, timer: TimerManager) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = EveningReviewView(store: store, days: days, settings: settings, timer: timer) { [weak self] in
            self?.window?.close()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "End of Day"
        w.setContentSize(NSSize(width: 620, height: 760))
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct EveningReviewView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var days: DayStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var timer: TimerManager
    let onClose: () -> Void

    @ObservedObject private var screen = ScreenWatcher.shared
    @State private var entry = EveningEntry()
    @State private var saved = false

    private let day = Calendar.current.startOfDay(for: Date())
    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }

    private var sessions: [WorkSession] {
        (store.sessions + [timer.currentInProgressSession, timer.currentInProgressBreak].compactMap { $0 }
            .map { WorkSession(startTime: $0.startTime, durationMinutes: Date().timeIntervalSince($0.startTime) / 60,
                               type: $0.type, label: $0.label) })
            .filter { $0.startTime < dayEnd && $0.startTime.addingTimeInterval($0.durationMinutes * 60) > day }
    }

    private func minutes(_ s: WorkSession) -> Double {
        max(0, min(s.startTime.addingTimeInterval(s.durationMinutes * 60), dayEnd).timeIntervalSince(max(s.startTime, day))) / 60
    }

    private func byLabel(focus: Bool) -> [(String, Double)] {
        var m: [String: Double] = [:]
        for s in sessions where s.isFocus == focus {
            m[s.type != .work ? "Break" : (s.label ?? "Focus"), default: 0] += minutes(s)
        }
        return m.filter { $0.value >= 1 }.sorted { $0.value > $1.value }
    }

    var body: some View {
        let focus = byLabel(focus: true)
        let life = byLabel(focus: false)
        let focusTotal = focus.reduce(0) { $0 + $1.1 }
        let goal = Double(max(settings.dailyGoal, 1)) * 60
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.system(size: 26, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fmt(focusTotal))
                            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("focus").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Label(focusTotal >= goal ? "\(settings.dailyGoal)h goal met" : "\(fmt(goal - focusTotal)) short of \(settings.dailyGoal)h",
                              systemImage: focusTotal >= goal ? "checkmark.circle.fill" : "target")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(focusTotal >= goal ? Color.green : .secondary)
                    }
                    split(focus, total: max(focusTotal, goal))
                    chips(focus)
                }

                if let rec = days.todayRecord, let text = rec.commitmentText, !text.isEmpty {
                    section("This morning you committed to") {
                        Text("\u{201C}\(text)\u{201D}").font(.system(size: 14).italic())
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            choice("Kept it", on: rec.commitmentFulfilled == true, color: .green) {
                                days.setFulfillment(true, forDayID: rec.id)
                            }
                            choice("Didn't", on: rec.commitmentFulfilled == false, color: .orange) {
                                days.setFulfillment(false, forDayID: rec.id)
                            }
                        }
                    }
                }

                workedOn

                offTask

                if !life.isEmpty {
                    section("The rest of the day") { chips(life) }
                }

                section("Looking back") {
                    field("What went well?", text: $entry.wentWell)
                    field("What got in the way?", text: $entry.inTheWay)
                    field("Tomorrow, start with…", text: $entry.firstTask)
                    Text("Tomorrow morning's review shows this before anything else.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if saved { Label("Saved", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(.green) }
                    Spacer()
                    if days.isDayStarted {
                        Button("Save") { save() }
                            .buttonStyle(.plain).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Button {
                        save()
                        if days.isDayStarted { days.endDay() }
                        onClose()
                    } label: {
                        Text(days.isDayStarted ? "Save & End Day" : "Done")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(Capsule().fill(Color.indigo))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(.regularMaterial)
        .onAppear { if let e = EveningLog.entry(for: day) { entry = e } }
    }

    private struct Topic: Identifiable {
        var name: String
        var category: String?
        var minutes: Double
        var first: Date
        var bullets: [String]
        var id: String { name }
    }

    /// Focus blocks grouped by name, so three stretches of the same chat
    /// read as one topic, with the bullets from their notes.
    private var topics: [Topic] {
        var byName: [String: Topic] = [:]
        for a in screen.activities(from: day, to: dayEnd) {
            guard let c = a.category, !FocusCategories.isLife(c), a.minutes >= 2 else { continue }
            // "Chrome: Compiler Explorer" and "Compiler Explorer" are one topic;
            // a bare app name or a leaked prompt label isn't a topic at all.
            let full = screen.name(for: a)
            // OCR tails like "Terminal C×" (a tab's close button) split one topic in two.
            let name = (full.components(separatedBy: ": ").last ?? full)
                .replacingOccurrences(of: #"\s+(\S?[^\p{L}\p{N}\s]\S?|\p{Lu})$"#, with: "", options: .regularExpression)
            let generic: Set<String> = ["claude", "chatgpt", "codex", "private", "focus", "google chrome", "safari", "terminal", "finder"]
            guard !generic.contains(name.lowercased()), !name.lowercased().contains("notes so far"), name.count >= 4 else { continue }
            var t = byName[name] ?? Topic(name: name, category: c, minutes: 0, first: a.start, bullets: [])
            t.minutes += a.minutes
            t.first = min(t.first, a.start)
            for raw in screen.notes(for: a)?.bullets ?? [] {
                let b = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-•*· ").union(.whitespaces))
                if !b.isEmpty, !t.bullets.contains(b) { t.bullets.append(b) }
            }
            byName[name] = t
        }
        return byName.values.filter { $0.minutes >= 5 }.sorted { $0.minutes > $1.minutes }
    }

    private var workedOn: some View {
        let list = Array(topics.prefix(8))
        return Group {
            if !list.isEmpty {
                section("What the screen saw you work on") {
                    ForEach(list) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Circle().fill(t.category.map(categoryColor) ?? .secondary).frame(width: 6, height: 6)
                                Text(t.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Spacer()
                                Text("\(fmt(t.minutes)) · from \(t.first.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ForEach(Array(t.bullets.prefix(3).enumerated()), id: \.offset) { _, b in
                                Text("• \(b)").font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private var offTask: some View {
        let drifts = screen.drifts(sessions: sessions, from: day, to: dayEnd)
        let total = drifts.reduce(0) { $0 + $1.minutes }
        let top = Dictionary(grouping: drifts, by: \.source).mapValues { $0.reduce(0) { $0 + $1.minutes } }
            .max { $0.value < $1.value }
        return Group {
            if !drifts.isEmpty {
                section("Off-task during focus") {
                    Text("\(drifts.count) drift\(drifts.count == 1 ? "" : "s"), \(fmt(total)) in all"
                         + (top.map { ". Most of it: \(Self.dedupe($0.key)) (\(fmt($0.value)))" } ?? ""))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "ChatGPT: ChatGPT" → "ChatGPT".
    private static func dedupe(_ s: String) -> String {
        let parts = s.components(separatedBy: ": ")
        return parts.count == 2 && parts[0] == parts[1] ? parts[0] : s
    }

    private func save() {
        entry.savedAt = Date()
        EveningLog.save(entry, for: day)
        saved = true
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .contentCard()
    }

    /// The goal bar split by category, so the colors double as the legend.
    private func split(_ items: [(String, Double)], total: Double) -> some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(items, id: \.0) { name, m in
                    Rectangle().fill(categoryColor(name)).frame(width: max(2, g.size.width * m / max(total, 1) - 2))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func chips(_ items: [(String, Double)]) -> some View {
        FlowRows(items.map { "\($0.0) \(fmt($0.1))" }, colors: items.map { categoryColor($0.0) })
    }

    private func choice(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? color : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prompt).font(.system(size: 11.5, weight: .medium))
            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.system(size: 12))
        }
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m.rounded()) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(max(mn, 1))m"
    }
}

/// Wrapping row of small colored labels.
private struct FlowRows: View {
    let texts: [String]
    let colors: [Color]
    init(_ texts: [String], colors: [Color]) { self.texts = texts; self.colors = colors }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
    }

    private var items: some View {
        ForEach(Array(texts.enumerated()), id: \.offset) { i, t in
            HStack(spacing: 4) {
                Circle().fill(colors[i]).frame(width: 6, height: 6)
                Text(t).font(.system(size: 11).monospacedDigit())
            }
        }
    }
}
