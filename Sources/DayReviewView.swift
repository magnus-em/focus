import SwiftUI
import FocusCore

struct TimeGap: Identifiable, Equatable {
    let start: Date
    let end: Date
    var id: Date { start }
    var minutes: Double { end.timeIntervalSince(start) / 60 }
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
        if (hour < 6 || gap.minutes >= 300), tags.contains("Sleep"), !ranked.contains("Sleep") {
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
        store.untrackedGaps(from: window.from, to: window.to, live: live)
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
