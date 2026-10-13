import SwiftUI
import FocusCore

/// Dashboard activity log: what the screen watcher thinks you worked on, with
/// study notes per block, next to what was tracked so accuracy can be judged.
struct ScreenActivitySection: View {
    @ObservedObject var watcher: ScreenWatcher
    let day: Date
    let sessions: [WorkSession]

    @State private var expanded: Set<Date> = []
    @State private var showAll = false

    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }

    /// Newest first.
    private var activities: [ScreenActivity] {
        watcher.activities(from: day, to: dayEnd).filter { $0.minutes >= 0.5 }.reversed()
    }

    /// The tracked label covering most of [a, b): a category, "Break", or nil.
    private func tracked(_ a: Date, _ b: Date) -> String? {
        var overlap: [String: Double] = [:]
        for s in sessions {
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            let o = min(b, e).timeIntervalSince(max(a, s.startTime))
            guard o > 0 else { continue }
            overlap[s.type != .work ? "Break" : (s.label ?? "Focus"), default: 0] += o
        }
        guard let best = overlap.max(by: { $0.value < $1.value }),
              best.value >= b.timeIntervalSince(a) * 0.3 else { return nil }
        return best.key
    }

    /// Share of labeled screen time whose tracked category matched.
    private func agreement(_ list: [ScreenActivity]) -> (pct: Double, minutes: Double)? {
        var matched = 0.0, total = 0.0
        for a in list {
            for s in a.spans where s.category != nil {
                let d = s.end.timeIntervalSince(s.start)
                total += d
                if tracked(s.start, s.end) == s.category { matched += d }
            }
        }
        return total >= 300 ? (matched / total, total / 60) : nil
    }

    var body: some View {
        let list = activities
        let live = list.first.flatMap { Date().timeIntervalSince($0.end) < 60 ? $0 : nil }
        let earlier = live == nil ? list : Array(list.dropFirst())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ACTIVITY LOG")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if let ag = agreement(list) {
                    Text("Screen matches your tracking \(Int(ag.pct * 100))% of \(fmt(ag.minutes))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(ag.pct >= 0.8 ? .green : ag.pct >= 0.6 ? .orange : .red)
                }
            }

            if let live { nowPanel(live) }

            if list.isEmpty {
                Text(watcher.status.hasPrefix("Watching")
                     ? "Nothing recorded for this day yet."
                     : "Screen watching: \(watcher.status). Settings → Screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? earlier : Array(earlier.prefix(15))) { a in
                    if a.minutes < 2 && watcher.notes(for: a) == nil { compactRow(a) } else { row(a) }
                }
            }
            if earlier.count > 15 {
                Button(showAll ? "Show fewer" : "Show all \(earlier.count)") { showAll.toggle() }
                    .font(.system(size: 10.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text("A snapshot every 15s is read on-device; notes are written from the pages you had open and update every couple of minutes. Page text stays in memory and is never saved. Click a block for its snapshots.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Now

    private func nowPanel(_ a: ScreenActivity) -> some View {
        let notes = watcher.notes(for: a)
        let color = a.category.map(categoryColor) ?? .secondary
        return TimelineView(.periodic(from: .now, by: 5)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("NOW · \(fmt(ctx.date.timeIntervalSince(a.start) / 60))")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .tracking(0.8)
                        .foregroundStyle(.green)
                    Spacer()
                    categoryVsTracked(a)
                }
                Text(watcher.name(for: a))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                if let notes, !notes.bullets.isEmpty {
                    bulletList(notes.bullets, size: 11.5)
                } else {
                    Text("Taking notes once there's a couple of minutes of pages…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    if let s = a.spans.last {
                        Text(s.title.isEmpty ? s.app : "\(s.app): \(s.title)")
                            .lineLimit(1)
                    }
                    Spacer()
                    if let notes {
                        Text("notes updated \(ago(notes.updatedAt, now: ctx.date))")
                    }
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Rows

    private func row(_ a: ScreenActivity) -> some View {
        let open = expanded.contains(a.start)
        let notes = watcher.notes(for: a)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                timeColumn(a)
                RoundedRectangle(cornerRadius: 2)
                    .fill(a.category.map(categoryColor) ?? Color.secondary.opacity(0.4))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(watcher.name(for: a))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        categoryVsTracked(a)
                    }
                    if let notes, !notes.bullets.isEmpty {
                        bulletList(notes.bullets, size: 11)
                    }
                    HStack(spacing: 3) {
                        if let d = a.device { Image(systemName: d == "iPad" ? "ipad" : "iphone") }
                        Text(a.apps.prefix(3).joined(separator: " · ")).lineLimit(1)
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if open { expanded.remove(a.start) } else { expanded.insert(a.start) }
            }
            if open { snapshots(a) }
        }
        .padding(.vertical, 6)
    }

    /// Quick switches: one gray line, so they don't drown the real blocks.
    private func compactRow(_ a: ScreenActivity) -> some View {
        HStack(spacing: 8) {
            Text(a.start.formatted(date: .omitted, time: .shortened))
                .frame(width: 58, alignment: .trailing)
            Circle().fill(a.category.map(categoryColor) ?? .secondary).frame(width: 4, height: 4)
            Text("\(fmt(a.minutes)) · \(a.topTitle)").lineLimit(1)
            Spacer()
            Text(a.category ?? "")
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(.vertical, 2)
    }

    private func timeColumn(_ a: ScreenActivity) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(a.start.formatted(date: .omitted, time: .shortened))
            Text(fmt(a.minutes)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 58, alignment: .trailing)
    }

    private func categoryVsTracked(_ a: ScreenActivity) -> some View {
        let t = tracked(a.start, a.end)
        let match = t != nil && t == a.category
        return HStack(spacing: 4) {
            Text(a.category ?? "Unlabeled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(a.category.map(categoryColor) ?? .secondary)
            if a.category != nil {
                Image(systemName: match ? "checkmark" : "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(match ? .green : .orange)
            }
            Text(t.map { "tracked \($0)" } ?? "untracked")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func bulletList(_ bullets: [String], size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(bullets.enumerated()), id: \.offset) { _, b in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(b).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(.primary.opacity(0.85))
    }

    private func snapshots(_ a: ScreenActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(a.spans) { s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.start.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .leading)
                    Text(s.category ?? "–")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(s.category.map(categoryColor) ?? .secondary)
                        .frame(width: 54, alignment: .leading)
                    Text("\(s.summary)  ·  \(s.title.isEmpty ? s.app : "\(s.app): \(s.title)")")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 69)
    }

    private func ago(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        return s < 60 ? "\(max(s, 0))s ago" : "\(s / 60)m ago"
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(max(mn, 1))m"
    }
}

// MARK: - Distractions

/// Time the screen showed a life category (Leisure, Reading, Admin…) while a
/// focus block was running. Computed from saved screen spans; nothing new is stored.
struct Drift: Identifiable {
    var start: Date
    var end: Date
    var category: String
    var source: String
    var id: Date { start }
    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

extension ScreenWatcher {
    static func focusIntervals(_ sessions: [WorkSession]) -> [(Date, Date)] {
        sessions.filter(\.isFocus).map { ($0.startTime, $0.startTime.addingTimeInterval($0.durationMinutes * 60)) }
    }

    func drifts(sessions: [WorkSession], from: Date, to: Date) -> [Drift] {
        let focus = Self.focusIntervals(sessions)
        var pieces: [Drift] = []
        for s in spans(from: from, to: to) where s.active != false {
            guard let c = s.category, FocusCategories.isLife(c) else { continue }
            for (a, b) in focus {
                let lo = max(s.start, a, from), hi = min(s.end, b, to)
                guard hi > lo else { continue }
                pieces.append(Drift(start: lo, end: hi, category: c, source: s.title.isEmpty ? s.app : "\(s.app): \(s.title)"))
            }
        }
        pieces.sort { $0.start < $1.start }
        var merged: [(drift: Drift, bySource: [String: Double])] = []
        for p in pieces {
            if var last = merged.last, last.drift.category == p.category, p.start.timeIntervalSince(last.drift.end) < 30 {
                last.drift.end = max(last.drift.end, p.end)
                last.bySource[p.source, default: 0] += p.end.timeIntervalSince(p.start)
                merged[merged.count - 1] = last
            } else {
                merged.append((p, [p.source: p.end.timeIntervalSince(p.start)]))
            }
        }
        return merged.compactMap { m in
            guard m.drift.end.timeIntervalSince(m.drift.start) >= 30 else { return nil }
            var d = m.drift
            d.source = m.bySource.max { $0.value < $1.value }?.key ?? d.source
            return d
        }
    }

    static func focusMinutes(_ sessions: [WorkSession], from: Date, to: Date) -> Double {
        focusIntervals(sessions).reduce(0) { $0 + max(0, min($1.1, to).timeIntervalSince(max($1.0, from))) } / 60
    }
}

struct DistractionSection: View {
    @ObservedObject var watcher: ScreenWatcher
    let day: Date
    let sessions: [WorkSession]

    private let cal = Calendar.current

    private func range(_ d: Date) -> (Date, Date) {
        let s = cal.startOfDay(for: d)
        return (s, cal.date(byAdding: .day, value: 1, to: s)!)
    }

    var body: some View {
        let (a, b) = range(day)
        let drifts = watcher.drifts(sessions: sessions, from: a, to: b)
        let total = drifts.reduce(0) { $0 + $1.minutes }
        let focus = ScreenWatcher.focusMinutes(sessions, from: a, to: b)
        let week: [(Date, Double, Double)] = (0..<7).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: day)!
            let (x, y) = range(d)
            return (d, watcher.drifts(sessions: sessions, from: x, to: y).reduce(0) { $0 + $1.minutes },
                    ScreenWatcher.focusMinutes(sessions, from: x, to: y))
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("OFF-TASK DURING FOCUS")
                    .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if focus >= 10 {
                    Text("\(drifts.count) drift\(drifts.count == 1 ? "" : "s") · \(fmt(total)) · \(String(format: "%.1f", total / (focus / 60)))m per focus hour")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(total / (focus / 60) <= 3 ? .green : total / (focus / 60) <= 8 ? .orange : .red)
                }
            }
            if drifts.isEmpty {
                Text(focus < 10 ? "No focus time on this day yet." : "The screen stayed on task during focus.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let byCat = Dictionary(grouping: drifts, by: \.category).mapValues { $0.reduce(0) { $0 + $1.minutes } }
                HStack(spacing: 10) {
                    ForEach(byCat.sorted { $0.value > $1.value }, id: \.key) { c, m in
                        HStack(spacing: 4) {
                            Circle().fill(categoryColor(c)).frame(width: 6, height: 6)
                            Text("\(c) \(fmt(m))")
                        }
                    }
                }
                .font(.system(size: 10.5))
                let bySource = Dictionary(grouping: drifts, by: \.source).mapValues { $0.reduce(0) { $0 + $1.minutes } }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bySource.sorted { $0.value > $1.value }.prefix(4), id: \.key) { src, m in
                        HStack {
                            Text(src).lineLimit(1)
                            Spacer()
                            Text(fmt(m)).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Divider()
                ForEach(drifts.suffix(8).reversed()) { d in
                    HStack(spacing: 6) {
                        Text(d.start.formatted(date: .omitted, time: .shortened)).frame(width: 58, alignment: .trailing)
                        Circle().fill(categoryColor(d.category)).frame(width: 4, height: 4)
                        Text("\(fmt(d.minutes)) · \(d.source)").lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                let peak = max(week.map { $0.2 > 10 ? $0.1 / ($0.2 / 60) : 0 }.max() ?? 0, 1)
                ForEach(week, id: \.0) { d, m, f in
                    let rate = f > 10 ? m / (f / 60) : 0
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(f > 10 ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.15))
                            .frame(width: 18, height: max(2, 30 * rate / peak))
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.system(size: 8.5)).foregroundStyle(.tertiary)
                    }
                    .help(f > 10 ? "\(fmt(m)) off-task in \(fmt(f)) focus" : "No focus")
                }
                Text("min off-task per focus hour, last 7 days")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m.rounded()) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(max(mn, 1))m"
    }
}
