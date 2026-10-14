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
                Text("Activity log")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                let score = watcher.checkScore()
                if score.total > 0 {
                    Text("Your checks: \(score.right)/\(score.total) right this week")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Double(score.right) / Double(score.total) >= 0.85 ? Color.good : .orange)
                        .help("✓ or ✗ a block below to grade the labels. Your answers also teach it those windows.")
                }
                if let ag = agreement(list) {
                    Text("Screen matches your tracking \(Int(ag.pct * 100))% of \(fmt(ag.minutes))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(ag.pct >= 0.8 ? Color.good : ag.pct >= 0.6 ? .orange : .red)
                }
            }

            if let live { nowPanel(live) }
            inspector

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
            Text("Read on-device. Click an activity for its screen evidence; review images stay on this Mac for up to seven days when enabled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - What it sees

    @State private var showInspector = false

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showInspector.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showInspector ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text("What it sees right now")
                    Spacer()
                    if !watcher.coachStatus.isEmpty { Text(watcher.coachStatus).lineLimit(1).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showInspector {
                if let x = watcher.lastSnapshot {
                    VStack(alignment: .leading, spacing: 4) {
                        row("When", "\(x.date.formatted(date: .omitted, time: .standard)) · took \(String(format: "%.1f", x.seconds))s · \(x.active ? "you were active" : "idle, doesn't count")")
                        row("Window", x.title.isEmpty ? x.app : "\(x.app): \(x.title)")
                        row("Label", "\(x.category ?? "none") · from \(x.source)")
                        row("Summary", x.summary)
                        row("Card", watcher.coachStatus)
                        HStack {
                            Text("Text read (\(x.text.count) chars)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Ignore \(x.app)") { watcher.setIgnored(x.bundle, name: x.app, true) }
                                .font(.system(size: 9.5)).buttonStyle(.plain).foregroundStyle(.orange)
                        }
                        ScrollView {
                            Text(x.text.isEmpty ? "(no text)" : x.text)
                                .font(.system(size: 9.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 140)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        ForEach(Array(x.others.enumerated()), id: \.offset) { _, o in
                            row("Other screen", "\(o.window) · \(o.text.count) chars")
                        }
                    }
                } else {
                    Text("No snapshot yet: \(watcher.status)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(k).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(v).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Now

    private func nowPanel(_ a: ScreenActivity) -> some View {
        let notes = watcher.notes(for: a)
        let color = a.category.map(categoryColor) ?? .secondary
        return TimelineView(.periodic(from: .now, by: 5)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color.good).frame(width: 6, height: 6)
                    Text("NOW · \(fmt(ctx.date.timeIntervalSince(a.start) / 60))")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .tracking(0.8)
                        .foregroundStyle(Color.good)
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
                        checkButtons(a)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(a.start.formatted(date: .omitted, time: .shortened))
                    .frame(width: 58, alignment: .trailing)
                Circle().fill(a.category.map(categoryColor) ?? .secondary).frame(width: 4, height: 4)
                Text("\(fmt(a.minutes)) · \(a.topTitle)").lineLimit(1)
                Spacer()
                Text(a.category ?? "")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded.contains(a.start) { expanded.remove(a.start) } else { expanded.insert(a.start) }
            }
            if expanded.contains(a.start) { snapshots(a) }
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

    /// Grade the label: ✓ keeps it, ✗ asks what it really was.
    @ViewBuilder
    private func checkButtons(_ a: ScreenActivity) -> some View {
        let c = watcher.check(for: a)
        HStack(spacing: 4) {
                if let disposition = c?.disposition {
                    Text(disposition == "mixed" ? "Mixed" : "Unsure")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            if a.category != nil {
                Button { watcher.setCheck(a, right: true) } label: {
                    Image(systemName: c?.right == true && c?.disposition == nil ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(c?.right == true && c?.disposition == nil ? Color.good : .secondary)
                }
                .buttonStyle(.plain)
                .help("Label is right")
                .accessibilityLabel("The suggested category is correct")
            }
                Menu {
                    ForEach(watcher.reviewChoices + ["Break"], id: \.self) { t in
                        Button(t) { watcher.setCheck(a, right: false, actual: t) }
                    }
                    Divider()
                    Button("Mixed activity — don't learn") { watcher.setReviewDisposition(a, disposition: "mixed") }
                    Button("Unsure — don't learn") { watcher.setReviewDisposition(a, disposition: "unsure") }
                } label: {
                    if a.category == nil {
                        Text("Choose category").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: c?.right == false && c?.disposition == nil ? "xmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(c?.right == false && c?.disposition == nil ? .orange : .secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(c?.actual.map { "You said: \($0)" } ?? "Label is wrong: pick what it was")
                .accessibilityLabel("Correct or mark the suggested category")
        }
        .font(.system(size: 11))
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
                    .foregroundStyle(match ? Color.good : .orange)
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
        VStack(alignment: .leading, spacing: 8) {
            if a.device == nil {
                ScreenEvidenceGallery(from: a.start, to: a.end, bundles: Set(a.spans.map(\.bundleID)))
            } else {
                Text("Screenshots from \(a.device ?? "this device") aren't stored on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(a.spans.suffix(12))) { s in
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
            if a.spans.count > 12 {
                Text("Showing the latest 12 text snapshots; use the timeline to inspect earlier ones.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 69)
    }

    private func ago(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        return s < 60 ? "\(max(s, 0))s ago" : "\(s / 60)m ago"
    }

    private func fmt(_ m: Double) -> String {
        durationText(minutes: m)
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
    var bundle: String
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
                pieces.append(Drift(start: lo, end: hi, category: c, source: s.title.isEmpty ? s.app : "\(s.app): \(s.title)",
                                    bundle: s.bundleID))
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
                Text("Off-task during focus")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if focus >= 10 {
                    Text("\(drifts.count) drift\(drifts.count == 1 ? "" : "s") · \(fmt(total)) · \(String(format: "%.1f", total / (focus / 60)))m per focus hour")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(total / (focus / 60) <= 3 ? Color.good : total / (focus / 60) <= 8 ? .orange : .red)
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
                            if let b = drifts.first(where: { $0.source == src })?.bundle {
                                Button("Ignore app") { watcher.setIgnored(b, name: src.components(separatedBy: ":").first ?? src, true) }
                                    .buttonStyle(.plain).foregroundStyle(.orange).font(.system(size: 9.5))
                                    .help("Not a distraction: stop watching this app and drop it from the log")
                            }
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
        durationText(minutes: m)
    }
}

/// Every snapshot the watcher labeled, at its real length, above the smoothed
/// blocks and what you tracked. Zoom to 15 min to see each 15s snapshot.
struct ScreenTimelineSection: View {
    @ObservedObject var watcher: ScreenWatcher
    let day: Date
    let sessions: [WorkSession]

    enum Zoom: Double, CaseIterable, Identifiable {
        case day = 86400, fourHours = 14400, hour = 3600, quarter = 900
        var id: Double { rawValue }
        var label: String {
            switch self { case .day: "Day"; case .fourHours: "4h"; case .hour: "1h"; case .quarter: "15m" }
        }
        var tick: TimeInterval {
            switch self { case .day: 3600 * 3; case .fourHours: 1800; case .hour: 600; case .quarter: 60 }
        }
    }

    @State private var zoom: Zoom = .hour
    @State private var hovered: ScreenSpan?
    @State private var pinned: ScreenSpan?
    @State private var pinch: CGFloat = 1
    @State private var jump: Date?
    @State private var follow = 0
    @State private var agreementTrend: [Double?] = []
    @State private var showAllSwitches = false

    private let cal = Calendar.current
    private var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: day)! }

    private struct Tracked { let start: Date, end: Date, label: String }

    private var tracked: [Tracked] {
        sessions.map {
            Tracked(start: $0.startTime, end: $0.startTime.addingTimeInterval($0.durationMinutes * 60),
                    label: $0.type != .work ? "Break" : ($0.label ?? "Focus"))
        }
        .filter { $0.end > day && $0.start < dayEnd }
    }

    private func trackedLabel(at t: Date, in list: [Tracked]) -> String? {
        list.last { $0.start <= t && $0.end > t }?.label
    }

    var body: some View {
        let spans = watcher.spans(from: day, to: dayEnd).sorted { $0.start < $1.start }
        let blocks = watcher.activities(from: day, to: dayEnd).filter { $0.device == nil }
        let track = tracked
        let hours = hourRange(spans)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshots").font(.system(size: 15, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in liveLine(ctx.date) }
                }
                Spacer()
                Picker("Zoom", selection: $zoom) {
                    ForEach(Zoom.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Or pinch on the timeline")
            }
            if spans.isEmpty {
                Text("No snapshots on this day.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                let sw = switches(spans, track)
                summary(spans, track, sw)
                timeline(hours: hours, spans: spans, blocks: blocks, track: track)
                detail(pinned ?? hovered, track)
                if !sw.isEmpty { Divider(); switchList(sw) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    /// What the watcher is doing this second, then the last snapshot and why
    /// a card did or didn't fire, so testing a switch shows each stage.
    private func liveLine(_ now: Date) -> some View {
        let stage = watcher.stage
        let next = watcher.nextSnapshotAt.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
        let paused = !watcher.status.hasPrefix("Watching")
        let head: String = !stage.isEmpty ? "\(stage)…"
            : paused ? watcher.status
            : next.map { "Watching · next snapshot in \($0)s" } ?? "Watching"
        var detail: [String] = []
        if let last = watcher.lastSnapshot {
            detail.append("Last snapshot \(last.date.formatted(date: .omitted, time: .standard)): \(last.app)\(last.title.isEmpty ? "" : ", \(last.title)")")
            detail.append("Label \(last.category ?? "none"), from \(last.source), in \(String(format: "%.1f", last.seconds))s")
        }
        if !watcher.coachStatus.isEmpty { detail.append(watcher.coachStatus) }
        return HStack(spacing: 6) {
            Circle().fill(stage.isEmpty ? Color.secondaryText.opacity(paused ? 0.4 : 0.8) : Color.good).frame(width: 7, height: 7)
                .opacity(stage.isEmpty || Int(now.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0.35)
            Text(head).foregroundStyle(stage.isEmpty ? .secondary : .primary).lineLimit(1)
            if !watcher.coachStatus.isEmpty {
                Text("· \(watcher.coachStatus)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .help(detail.joined(separator: "\n"))
    }

    private func hourRange(_ spans: [ScreenSpan]) -> [Date] {
        guard let first = spans.first?.start, let last = spans.map(\.end).max() else { return [] }
        let a = cal.dateInterval(of: .hour, for: first)!.start
        let b = min(dayEnd, cal.dateInterval(of: .hour, for: max(last, min(Date(), dayEnd)))!.end)
        return stride(from: a.timeIntervalSince1970, to: b.timeIntervalSince1970, by: 3600)
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// The screen's own story: active snapshots merged into runs, runs under
    /// 30s folded into their neighbour so a glance at Slack isn't a "switch".
    private struct Switch: Identifiable {
        let at: Date, from: String, to: String, title: String
        /// Seconds from the screen's switch to yours (negative = you were first); nil = you never switched.
        let lag: TimeInterval?
        var id: Date { at }
    }

    private func runs(_ spans: [ScreenSpan]) -> [(c: String, start: Date, end: Date, title: String)] {
        var out: [(c: String, start: Date, end: Date, title: String)] = []
        for s in spans where s.active != false {
            guard let c = s.category else { continue }
            if let l = out.last, l.c == c, s.start.timeIntervalSince(l.end) < 90 {
                out[out.count - 1].end = s.end
            } else {
                out.append((c, s.start, s.end, s.title))
            }
        }
        var merged: [(c: String, start: Date, end: Date, title: String)] = []
        for r in out {
            if let l = merged.last, r.end.timeIntervalSince(r.start) < 30, r.start.timeIntervalSince(l.end) < 90 {
                merged[merged.count - 1].end = r.end
            } else if let l = merged.last, l.c == r.c, r.start.timeIntervalSince(l.end) < 90 {
                merged[merged.count - 1].end = r.end
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private func switches(_ spans: [ScreenSpan], _ track: [Tracked]) -> [Switch] {
        let r = runs(spans)
        guard r.count > 1 else { return [] }
        return (1..<r.count).compactMap { i in
            guard r[i].start.timeIntervalSince(r[i - 1].end) < 90 else { return nil }
            let at = r[i].start, to = r[i].c
            let yours = track.filter { $0.label == to && abs($0.start.timeIntervalSince(at)) < 15 * 60 }
                .min { abs($0.start.timeIntervalSince(at)) < abs($1.start.timeIntervalSince(at)) }
            let covered = trackedLabel(at: at.addingTimeInterval(20), in: track) == to
            let lag = yours.map { $0.start.timeIntervalSince(at) } ?? (covered ? 0 : nil)
            return Switch(at: at, from: r[i - 1].c, to: to, title: r[i].title, lag: lag)
        }
    }

    private func summary(_ spans: [ScreenSpan], _ track: [Tracked], _ sw: [Switch]) -> some View {
        var minutes: [String: Double] = [:]
        var disagree = 0.0, labeled = 0.0
        for s in spans where s.active != false {
            guard let c = s.category else { continue }
            let d = s.end.timeIntervalSince(s.start)
            minutes[c, default: 0] += d / 60
            if let t = trackedLabel(at: s.start.addingTimeInterval(d / 2), in: track) {
                labeled += d
                if t != c { disagree += d }
            }
        }
        let total = max(minutes.values.reduce(0, +), 1)
        let cats = minutes.sorted { $0.value > $1.value }
        let missed = sw.filter { $0.lag == nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                if labeled >= 300 {
                    VStack(alignment: .leading, spacing: 4) {
                        metric("\(Int(((labeled - disagree) / labeled * 100).rounded()))%", "agrees with you",
                               (labeled - disagree) / labeled >= 0.85 ? Color.good : .orange)
                        Sparkline(values: agreementTrend)
                            .frame(width: 84, height: 18)
                            .task(id: "\(day.timeIntervalSince1970)-\(watcher.spans.count / 20)") { agreementTrend = dailyAgreement() }
                            .help("Agreement with your tracking, each of the last 14 days")
                    }
                    metric(fmt(disagree / 60), "disagrees", .primary)
                }
                metric("\(sw.count)", sw.count == 1 ? "switch it saw" : "switches it saw", .primary)
                if missed > 0 { metric("\(missed)", "you kept going", .primary) }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Text("Screen saw").foregroundStyle(Color.secondaryText)
                    ForEach(cats.prefix(4), id: \.key) { c, m in
                        HStack(spacing: 5) {
                            Circle().fill(categoryColor(c)).frame(width: 7, height: 7)
                            Text(c).foregroundStyle(.primary)
                            Text(fmt(m))
                        }
                        .fixedSize()
                    }
                    if cats.count > 4 {
                        Text("+\(cats.count - 4) more").foregroundStyle(Color.secondaryText)
                            .help(cats.dropFirst(4).map { "\($0.key) \(fmt($0.value))" }.joined(separator: ", "))
                    }
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Share of labeled, active screen time matching your tracking, per day,
    /// oldest first; nil where there's too little to say.
    private func dailyAgreement() -> [Double?] {
        (0..<14).reversed().map { back -> Double? in
            let a = cal.date(byAdding: .day, value: -back, to: day)!, b = cal.date(byAdding: .day, value: 1, to: a)!
            let track = sessions.map {
                Tracked(start: $0.startTime, end: $0.startTime.addingTimeInterval($0.durationMinutes * 60),
                        label: $0.type != .work ? "Break" : ($0.label ?? "Focus"))
            }.filter { $0.end > a && $0.start < b }
            var same = 0.0, total = 0.0
            for s in watcher.spans(from: a, to: b) where s.active != false && s.source != "focus" {
                guard let c = s.category else { continue }
                let d = s.end.timeIntervalSince(s.start)
                guard let t = trackedLabel(at: s.start.addingTimeInterval(d / 2), in: track) else { continue }
                total += d
                if t == c { same += d }
            }
            return total >= 600 ? same / total : nil
        }
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func switchList(_ sw: [Switch]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Switches it saw").font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
            ForEach(collapsed(sw).suffix(showAllSwitches ? 200 : 6).reversed()) { s in
                HStack(spacing: 8) {
                    Text(s.at.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle().fill(categoryColor(s.from)).frame(width: 7, height: 7)
                        Text(s.from).font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        Circle().fill(categoryColor(s.to)).frame(width: 7, height: 7)
                        Text(s.to).font(.system(size: 13, weight: .medium))
                    }
                    .frame(width: 150, alignment: .leading)
                    Text(s.title.isEmpty ? "untitled" : s.title)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(lagText(s.lag, trackedFrom: s.from))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .frame(height: 26)
                .contentShape(Rectangle())
                .onTapGesture { zoom = .quarter; pinned = nil; jump = s.at }
            }
            if sw.count > 6 {
                Button(showAllSwitches ? "Show fewer" : "Show all \(sw.count)") { showAllSwitches.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    /// The same window flipping back and forth reads as one line.
    private func collapsed(_ sw: [Switch]) -> [Switch] {
        var out: [Switch] = []
        for s in sw {
            if let l = out.last, l.title == s.title, s.at.timeIntervalSince(l.at) < 300 { out[out.count - 1] = s } else { out.append(s) }
        }
        return out
    }

    private func lagText(_ lag: TimeInterval?, trackedFrom: String? = nil) -> String {
        guard let lag else { return "you stayed on \(trackedFrom ?? "it")" }
        if abs(lag) < 30 { return "you switched too" }
        let m = Int((abs(lag) / 60).rounded(.up))
        return lag > 0 ? "you switched \(m)m later" : "it noticed \(m)m after you"
    }

    private let laneH: CGFloat = 26, blockH: CGFloat = 0, trackH: CGFloat = 26, axisH: CGFloat = 16

    private func timeline(hours: [Date], spans: [ScreenSpan], blocks: [ScreenActivity], track: [Tracked]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Screen").frame(height: laneH).help("Every 15s snapshot and its label. Faded: no keyboard or mouse.")
                Text("You").frame(height: trackH).help("What you tracked. Orange hatching: the screen said something else.")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(width: 44, alignment: .leading)
            lanes(hours: hours, spans: spans, blocks: blocks, track: track)
        }
        .frame(height: laneH + trackH + axisH + 30)
        .onChange(of: watcher.spans.count) { _, _ in
            if pinned == nil, hovered == nil, zoom != .day { jump = nil; follow &+= 1 }
        }
        .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }.onEnded { _ in
            let all = Zoom.allCases
            if let i = all.firstIndex(of: zoom) {
                if pinch > 1.25, i + 1 < all.count { zoom = all[i + 1] }
                if pinch < 0.8, i > 0 { zoom = all[i - 1] }
            }
            pinch = 1
        })
    }

    private func lanes(hours: [Date], spans: [ScreenSpan], blocks: [ScreenActivity], track: [Tracked]) -> some View {
        GeometryReader { geo in
            let hourW = max(geo.size.width * 3600 / zoom.rawValue, 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 0) {
                        ForEach(hours, id: \.self) { h in
                            let live = Date().timeIntervalSince(h)
                            let w = live > 0 && live < 3600 && zoom != .day ? min(hourW, CGFloat(live / 3600) * hourW + 48) : hourW
                            hourChunk(h, width: hourW, spans: spans, blocks: blocks, track: track)
                                .frame(width: w, alignment: .leading).clipped().id(h)
                        }
                    }
                }
                .onAppear { scrollToNow(proxy, hours) }
                .onChange(of: zoom) { _, _ in scrollToNow(proxy, hours) }
                .onChange(of: jump) { _, _ in scrollToNow(proxy, hours) }
                .onChange(of: follow) { _, _ in scrollToNow(proxy, hours) }
            }
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy, _ hours: [Date]) {
        let target = jump ?? pinned?.start ?? min(Date(), hours.last ?? Date())
        guard let h = hours.last(where: { $0 <= target }) else { return }
        let atNow = jump == nil && pinned == nil
        DispatchQueue.main.async { proxy.scrollTo(h, anchor: zoom == .day ? .leading : atNow ? .trailing : .center) }
    }

    private func hourChunk(_ h: Date, width: CGFloat, spans: [ScreenSpan], blocks: [ScreenActivity], track: [Tracked]) -> some View {
        let end = h.addingTimeInterval(3600)
        let mine = spans.filter { $0.end > h && $0.start < end }
        let x = { (t: Date) -> CGFloat in CGFloat(t.timeIntervalSince(h) / 3600) * width }
        let focusID = (pinned ?? hovered)?.id
        return Canvas { ctx, size in
            let youY = laneH + 8
            // Same-category snapshots draw as one block, so the lane reads
            // as stretches of work rather than a barcode; thin seams mark
            // each 15s snapshot once there's room to see them.
            var runs: [(c: String?, a: Date, b: Date)] = []
            for s in mine {
                if let l = runs.last, l.c == s.category || s.end.timeIntervalSince(s.start) < 10,
                   s.start.timeIntervalSince(l.b) < 20 { runs[runs.count - 1].b = s.end }
                else { runs.append((s.category, s.start, s.end)) }
            }
            let seams = width / 3600 * 15 >= 4
            var disagreements: [CGRect] = []
            for r in runs {
                let rect = CGRect(x: x(r.a), y: 0, width: max(x(r.b) - x(r.a), 1.5), height: laneH)
                let c = r.c.map(categoryColor) ?? .gray
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(5, rect.width / 2), style: .continuous), with: .color(c))
                label(ctx, r.c ?? "?", in: rect, bold: true)
            }
            for s in mine {
                let r = CGRect(x: x(s.start), y: 0, width: max(x(s.end) - x(s.start), 1), height: laneH)
                if s.active == false {
                    ctx.fill(Path(r), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.55)))
                }
                if seams, r.minX > 0 {
                    ctx.fill(Path(CGRect(x: r.minX, y: 3, width: 1, height: laneH - 6)), with: .color(.black.opacity(0.18)))
                }
                if s.id == focusID {
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 4, style: .continuous),
                               with: .color(.primary), lineWidth: 2)
                }
                if let t = trackedLabel(at: s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2), in: track),
                   let c = s.category, t != c, s.active != false, s.end.timeIntervalSince(s.start) >= 10 {
                    disagreements.append(CGRect(x: r.minX, y: youY, width: r.width, height: trackH))
                }
            }
            for t in track where t.end > h && t.start < end {
                let r = CGRect(x: x(t.start), y: youY, width: max(x(t.end) - x(t.start), 1), height: trackH)
                ctx.fill(Path(roundedRect: r, cornerRadius: min(5, r.width / 2), style: .continuous),
                         with: .color(t.label == "Break" ? TimerView.breakBlue.opacity(0.6) : categoryColor(t.label)))
                label(ctx, t.label, in: r, bold: false)
            }
            // Orange hatch over your lane wherever the screen said otherwise.
            for r in disagreements {
                var hatch = Path()
                var hx = r.minX - r.height
                while hx < r.maxX {
                    hatch.move(to: CGPoint(x: hx, y: r.maxY)); hatch.addLine(to: CGPoint(x: hx + r.height, y: r.minY))
                    hx += 5
                }
                ctx.drawLayer { l in
                    l.clip(to: Path(r))
                    l.stroke(hatch, with: .color(.orange), lineWidth: 1.5)
                }
            }
            let now = Date()
            if now > h, now < end {
                ctx.fill(Path(roundedRect: CGRect(x: x(now) - 1, y: -3, width: 2, height: laneH + trackH + 14), cornerRadius: 1),
                         with: .color(.primary.opacity(0.7)))
            }
            var tick = h
            let axisY = laneH + trackH + 18
            while tick < end {
                let tx = x(tick)
                ctx.fill(Path(CGRect(x: tx, y: axisY - 2, width: 1, height: 3)), with: .color(.secondary.opacity(0.5)))
                if zoom != .day || (tick == h && cal.component(.hour, from: h) % 3 == 0) {
                    ctx.draw(Text(tickLabel(tick)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: tx + 2, y: axisY + 7), anchor: .leading)
                }
                tick = tick.addingTimeInterval(zoom == .day ? 3600 : zoom.tick)
            }
            _ = size
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let t = h.addingTimeInterval(Double(p.x / width) * 3600)
                hovered = mine.first { $0.start <= t && $0.end > t } ?? nearest(mine, t, slack: 4 * 3600 / width)
            case .ended: hovered = nil
            }
        }
        .onTapGesture { pinned = (pinned?.id == hovered?.id) ? nil : hovered }
    }

    /// The category name inside a block, only when it fits.
    private func label(_ ctx: GraphicsContext, _ text: String, in r: CGRect, bold: Bool) {
        guard r.width >= 30, !text.isEmpty else { return }
        let t = ctx.resolve(Text(text).font(.system(size: 11, weight: bold ? .semibold : .medium)).foregroundStyle(.white))
        let size = t.measure(in: CGSize(width: 400, height: 40))
        guard size.width + 12 <= r.width else { return }
        let visible = r.intersection(CGRect(x: 0, y: r.minY, width: 100_000, height: r.height))
        ctx.draw(t, at: CGPoint(x: max(visible.minX, 0) + 6, y: r.midY), anchor: .leading)
    }

    private func nearest(_ list: [ScreenSpan], _ t: Date, slack: TimeInterval) -> ScreenSpan? {
        list.min { abs($0.start.timeIntervalSince(t)) < abs($1.start.timeIntervalSince(t)) }
            .flatMap { abs($0.start.timeIntervalSince(t)) < slack || abs($0.end.timeIntervalSince(t)) < slack ? $0 : nil }
    }

    private func tickLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = cal.component(.minute, from: d) == 0 ? "h a" : "h:mm"
        return f.string(from: d)
    }

    @ViewBuilder
    private func detail(_ s: ScreenSpan?, _ track: [Tracked]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let s {
                    let t = trackedLabel(at: s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2), in: track)
                    HStack(spacing: 6) {
                        Circle().fill(s.category.map(categoryColor) ?? .gray).frame(width: 7, height: 7)
                        Text(s.category ?? "No label").fontWeight(.semibold)
                        Text("\(clock(s.start))–\(clock(s.end)) · \(Int(s.end.timeIntervalSince(s.start)))s")
                            .monospacedDigit().foregroundStyle(.secondary)
                        if let t {
                            Text(t == s.category ? "tracked \(t) ✓" : "tracked \(t)")
                                .foregroundStyle(t == s.category ? Color.good : .orange)
                        }
                        if s.active == false { Text("idle screen").foregroundStyle(.tertiary) }
                        Spacer()
                        if pinned != nil { Button("Unpin") { pinned = nil }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 13))
                    Text("\(s.app) · \(s.title.isEmpty ? "untitled" : s.title)")
                        .font(.system(size: 12)).lineLimit(1)
                    if !s.summary.isEmpty {
                        Text(s.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let reason = s.reason, !reason.isEmpty {
                        Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if s.uncertain == true {
                        Label("Uncertain — needs your judgment", systemImage: "questionmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    if pinned != nil {
                        ScreenEvidenceGallery(from: s.start, to: s.end, bundles: [s.bundleID])
                    }
                } else {
                    Text("Hover a snapshot to see what it read. Click to pin it.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: s == nil ? 16 : 52, alignment: .top)
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss"
        return f.string(from: d)
    }

    private func fmt(_ m: Double) -> String {
        durationText(minutes: m)
    }
}

/// Screen Review (CLAUDE.md roadmap #2): fix where the auto-log and your
/// tracking disagree, see which categories it confuses, the windows it gets
/// wrong most, and every card it showed.
struct ScreenReviewSection: View {
    @ObservedObject var watcher: ScreenWatcher
    let day: Date
    let sessions: [WorkSession]
    /// Start of whatever is running now: stretches after it can't be repainted.
    let runningStart: Date?
    let paint: (Date, Date, String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case triage = "Triage", confusion = "Confusions", windows = "Worst windows", cards = "Cards"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .triage
    @State private var done: Set<Date> = []
    @State private var index = 0
    @FocusState private var focused: Bool

    private let cal = Calendar.current
    private var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: day)! }

    private struct Tracked { let start: Date, end: Date, label: String }

    private func tracked(from a: Date, to b: Date) -> [Tracked] {
        sessions.map {
            Tracked(start: $0.startTime, end: $0.startTime.addingTimeInterval($0.durationMinutes * 60),
                    label: $0.type != .work ? "Break" : ($0.label ?? "Focus"))
        }
        .filter { $0.end > a && $0.start < b }
    }

    private func label(at t: Date, in list: [Tracked]) -> String? {
        list.last { $0.start <= t && $0.end > t }?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review").font(.system(size: 15, weight: .semibold))
                    Text("Check the screen evidence, then choose what you were doing.")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            switch tab {
            case .triage: triage
            case .confusion: confusion
            case .windows: worstWindows
            case .cards: cardLedger
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - Triage

    private struct Stretch: Identifiable {
        var start: Date, end: Date
        let screen: String, yours: String
        let category: String?
        var spans: [ScreenSpan]
        var id: Date { start }
        var minutes: Double { end.timeIntervalSince(start) / 60 }
        var titles: [String] {
            var seen: [String] = []
            for s in spans where !s.title.isEmpty && !seen.contains(s.title) { seen.append(s.title) }
            return seen
        }
    }

    /// Runs where the screen and your tracking disagree, a minute or longer.
    private func stretches(from a: Date, to b: Date) -> [Stretch] {
        let track = tracked(from: a, to: b)
        var out: [Stretch] = []
        for s in watcher.spans(from: a, to: b).sorted(by: { $0.start < $1.start })
        where s.active != false && s.source != "focus" && s.end.timeIntervalSince(s.start) >= 10 {
            guard let t = label(at: s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2), in: track),
                  s.category == nil || t != s.category || s.uncertain == true else { continue }
            let c = s.category ?? "Unlabeled"
            if let l = out.last, l.category == s.category, l.yours == t, s.start.timeIntervalSince(l.end) < 60 {
                out[out.count - 1].end = s.end
                out[out.count - 1].spans.append(s)
            } else {
                out.append(Stretch(start: s.start, end: s.end, screen: c, yours: t, category: s.category, spans: [s]))
            }
        }
        return out.filter { $0.minutes >= 1 }
    }

    private var openStretches: [Stretch] {
        stretches(from: day, to: dayEnd).filter { st in
            !done.contains(st.start) && watcher.check(for: activity(st)) == nil
        }
    }

    private func activity(_ st: Stretch) -> ScreenActivity {
        ScreenActivity(start: st.start, end: st.end, category: st.category, spans: st.spans)
    }

    @ViewBuilder
    private var triage: some View {
        let list = openStretches
        if list.isEmpty {
            Label("Nothing left to review for this day.", systemImage: "checkmark.circle")
                .font(.system(size: 13)).foregroundStyle(Color.good)
        } else {
            let st = list[min(index, list.count - 1)]
            let canPaint = runningStart.map { st.end <= $0 } ?? true
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(min(index, list.count - 1) + 1) of \(list.count)\(focused ? " · Y, N or S" : " · click for Y/N/S keys")")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
                    Spacer()
                    Text("\(st.start.formatted(date: .omitted, time: .shortened))–\(st.end.formatted(date: .omitted, time: .shortened)) · \(durationText(minutes: st.minutes))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
                }
                HStack(spacing: 16) {
                    side("Screen said", st.screen)
                    side("You tracked", st.yours)
                }
                ScreenEvidenceGallery(from: st.start, to: st.end, bundles: Set(st.spans.map(\.bundleID)))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(st.titles.prefix(3), id: \.self) { t in
                        Text(t).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    if let s = st.spans.last?.summary, !s.isEmpty {
                        Text(s).font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(2)
                    }
                    if let reason = st.spans.last?.reason, !reason.isEmpty {
                        Text(reason).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                    if st.spans.contains(where: { $0.uncertain == true }) {
                        Label("The model wasn't certain", systemImage: "questionmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    let sources = Set(st.spans.compactMap(\.source))
                    if !sources.isEmpty {
                        Text("Labeled by " + sources.sorted().map { $0 == "you" ? "your earlier answer" : $0 == "held" ? "window stickiness" : "the on-device model" }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                }
                HStack(spacing: 8) {
                    triageButton("Screen was right", key: "Y", color: st.category.map(categoryColor) ?? .secondary,
                                 enabled: canPaint && st.category != nil) {
                        guard let category = st.category else { return }
                        paint(st.start, st.end, category)
                        watcher.setCheck(activity(st), right: true)
                        resolve(st)
                    }
                    .help(st.category == nil ? "Choose a category below; an unlabeled screen cannot be confirmed"
                          : canPaint ? "Relabels \(durationText(minutes: st.minutes)) as \(st.screen) and teaches these windows"
                                   : "This overlaps what's running; switch from the popover instead")
                    triageButton("I was right", key: "N", color: st.yours == "Break" ? TimerView.breakBlue : categoryColor(st.yours), enabled: true) {
                        watcher.setCheck(activity(st), right: false, actual: st.yours)
                        resolve(st)
                    }
                    .help("Keeps your tracking and teaches these windows \(st.yours)")
                    triageButton("Skip", key: "S", color: .gray, enabled: true) {
                        index = (index + 1) % max(list.count, 1)
                    }
                }
                HStack(spacing: 12) {
                    Menu("Choose category") {
                        ForEach(watcher.reviewChoices + ["Break"], id: \.self) { category in
                            Button(category) {
                                paint(st.start, st.end, category)
                                watcher.setCheck(activity(st), right: category == st.category, actual: category)
                                resolve(st)
                            }
                        }
                    }
                    .disabled(!canPaint)
                    .help(canPaint ? "Relabel this stretch and teach its windows the selected category"
                          : "This overlaps the running timer; finish or switch it first")
                    Button("Mixed activity") {
                        watcher.setReviewDisposition(activity(st), disposition: "mixed")
                        resolve(st)
                    }
                    .help("Mark as reviewed without teaching a category or changing your tracking")
                    Button("Unsure") {
                        watcher.setReviewDisposition(activity(st), disposition: "unsure")
                        resolve(st)
                    }
                    .help("Mark as reviewed without teaching a category or changing your tracking")
                }
                .font(.system(size: 13)).controlSize(.regular)
                if !canPaint {
                    Text("This overlaps the running timer. You can check the label, but time changes wait until the block ends.")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            // Keys only after you click the card: a stray "y" elsewhere on
            // the Dashboard shouldn't relabel time.
            .onTapGesture { focused = true }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(characters: .init(charactersIn: "ynsYNS")) { press in
                switch press.characters.lowercased() {
                case "y" where canPaint && st.category != nil:
                    guard let category = st.category else { return .ignored }
                    paint(st.start, st.end, category); watcher.setCheck(activity(st), right: true); resolve(st)
                case "n":
                    watcher.setCheck(activity(st), right: false, actual: st.yours); resolve(st)
                case "s":
                    index = (index + 1) % max(list.count, 1)
                default: return .ignored
                }
                return .handled
            }
        }
    }

    private func resolve(_ st: Stretch) {
        done.insert(st.start)
    }

    private func side(_ caption: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            HStack(spacing: 6) {
                Circle().fill(label == "Break" ? TimerView.breakBlue : categoryColor(label)).frame(width: 9, height: 9)
                Text(label).font(.system(size: 15, weight: .semibold))
            }
        }
    }

    private func triageButton(_ title: String, key: String, color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(key).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(color.opacity(enabled ? 0.2 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: - Confusions

    /// Minutes the screen said X while you tracked Y, over the 7 days ending
    /// on this day. Your ✓/✗ answers aren't mixed in: tracking is the truth here.
    private var confusion: some View {
        let from = cal.date(byAdding: .day, value: -6, to: day)!
        let track = tracked(from: from, to: dayEnd)
        var grid: [String: [String: Double]] = [:]
        for s in watcher.spans(from: from, to: dayEnd) where s.active != false && s.source != "focus" {
            guard let c = s.category, let t = label(at: s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2), in: track) else { continue }
            grid[c, default: [:]][t, default: 0] += s.end.timeIntervalSince(s.start) / 60
        }
        let rows = grid.map { ($0.key, $0.value.values.reduce(0, +)) }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
        var colTotals: [String: Double] = [:]
        for (_, r) in grid { for (k, v) in r { colTotals[k, default: 0] += v } }
        let cols = colTotals.sorted { $0.value > $1.value }.prefix(6).map(\.key)
        return VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("Not enough overlap between snapshots and tracking yet.").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            } else {
                Text("Rows: what the screen said. Columns: what you tracked. Last 7 days, minutes.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        ForEach(cols, id: \.self) { c in
                            Text(c).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryText).lineLimit(1)
                        }
                    }
                    ForEach(rows, id: \.self) { r in
                        let total = max(grid[r]?.values.reduce(0, +) ?? 1, 1)
                        GridRow {
                            HStack(spacing: 5) {
                                Circle().fill(categoryColor(r)).frame(width: 7, height: 7)
                                Text(r).font(.system(size: 12, weight: .medium))
                            }
                            .gridColumnAlignment(.leading)
                            ForEach(cols, id: \.self) { c in
                                let m = grid[r]?[c] ?? 0
                                Text(m >= 1 ? "\(Int(m.rounded()))" : "·")
                                    .font(.system(size: 12).monospacedDigit())
                                    .frame(minWidth: 44, minHeight: 26)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill((r == c ? Color.good : Color.orange).opacity(m >= 1 ? 0.12 + 0.5 * m / total : 0.03)))
                                    .help("Screen said \(r), you tracked \(c): \(durationText(minutes: m))")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Worst windows

    private struct WindowMiss: Identifiable {
        let key: String, app: String, bundle: String, title: String
        var minutes: Double
        var yours: [String: Double]
        var id: String { key }
        var mostlyYours: String { yours.max { $0.value < $1.value }?.key ?? "" }
    }

    private var worstWindows: some View {
        let from = cal.date(byAdding: .day, value: -6, to: day)!
        let track = tracked(from: from, to: dayEnd)
        var misses: [String: WindowMiss] = [:]
        for s in watcher.spans(from: from, to: dayEnd) where s.active != false && s.source != "focus" {
            guard let c = s.category, let t = label(at: s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2), in: track),
                  t != c, t != "Break" else { continue }
            let key = ScreenWatcher.memoryKey(bundle: s.bundleID, title: s.title)
            var w = misses[key] ?? WindowMiss(key: key, app: s.app, bundle: s.bundleID, title: s.title, minutes: 0, yours: [:])
            let m = s.end.timeIntervalSince(s.start) / 60
            w.minutes += m
            w.yours[t, default: 0] += m
            misses[key] = w
        }
        let list = misses.values.filter { $0.minutes >= 2 }.sorted { $0.minutes > $1.minutes }.prefix(8)
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                Text("No window was mislabeled for 2 minutes or more this week.").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            ForEach(Array(list)) { w in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.title.isEmpty ? w.app : w.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("\(w.app) · \(durationText(minutes: w.minutes)) disagreed, you had \(w.mostlyYours)")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !ScreenWatcher.isGeneric(title: w.title, app: w.app), !FocusCategories.notFromScreen.contains(w.mostlyYours) {
                        Button("Always \(w.mostlyYours)") { ScreenWatcher.learn([w.key], as: w.mostlyYours) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(categoryColor(w.mostlyYours).opacity(0.2)))
                            .help("From now on this window is \(w.mostlyYours)")
                    }
                    Button("Ignore app") { watcher.setIgnored(w.bundle, name: w.app, true) }
                        .buttonStyle(.plain).font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .help("Never watch \(w.app)")
                }
                .frame(minHeight: 40)
                Divider()
            }
        }
    }

    // MARK: - Cards

    private var cardLedger: some View {
        let cards = PromptLog.cards(since: cal.date(byAdding: .day, value: -6, to: day)!).filter { $0.at < dayEnd }
        let answered = cards.filter { $0.answer != nil }
        let right = answered.filter { $0.answer?.hasPrefix("switched") == true }.count
        return VStack(alignment: .leading, spacing: 0) {
            if cards.isEmpty {
                Text("No cards in the last 7 days.").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            } else {
                Text("\(right) of \(answered.count) answered cards were right (you switched). \(cards.count - answered.count) ignored.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText).padding(.bottom, 6)
            }
            ForEach(Array(cards.prefix(12).enumerated()), id: \.offset) { _, c in
                HStack(spacing: 10) {
                    Text(c.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
                        .frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.card).font(.system(size: 13, weight: .medium))
                        Text(c.subtitle).font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(c.answer ?? "ignored")
                        .font(.system(size: 12))
                        .foregroundStyle(c.answer?.hasPrefix("switched") == true ? Color.good : Color.secondaryText)
                }
                .frame(minHeight: 38)
            }
        }
    }
}

struct ScreenEvidenceGallery: View {
    let from: Date
    let to: Date
    var bundles: Set<String>? = nil

    @ObservedObject private var store = ScreenEvidenceStore.shared
    @State private var entries: [ScreenEvidenceStore.Entry] = []
    @State private var selectedID: UUID?
    @State private var image: CGImage?
    @State private var imageID: UUID?
    @State private var loading = true
    @State private var loadingImage = false
    @State private var enlarged = false

    private var selected: ScreenEvidenceStore.Entry? {
        guard !store.deleting else { return nil }
        let entry = entries.first { $0.id == selectedID } ?? entries.first
        guard let entry, ScreenWatcher.userIgnored[entry.bundle] == nil,
              !ScreenWatcher.privateApps.contains(entry.bundle) else { return nil }
        return entry
    }

    private var queryID: String {
        "\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)-\((bundles ?? []).sorted().joined(separator: ","))-\(store.revision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry = selected {
                let position = entries.firstIndex { $0.id == entry.id } ?? 0
                HStack(spacing: 8) {
                    Label("Screen evidence", systemImage: "photo")
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.at.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                        .disabled(position == 0).help("Previous screenshot").accessibilityLabel("Previous screenshot")
                    Text("\(position + 1) of \(entries.count)")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                        .disabled(position + 1 >= entries.count).help("Next screenshot").accessibilityLabel("Next screenshot")
                    Button { enlarged.toggle() } label: {
                        Image(systemName: enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 36, height: 36)
                    }
                    .help(enlarged ? "Reduce screenshot" : "Enlarge screenshot")
                    .accessibilityLabel(enlarged ? "Reduce screenshot" : "Enlarge screenshot")
                }
                .buttonStyle(.borderless)
                Group {
                    if let image, imageID == entry.id {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit()
                            .accessibilityLabel("Screen captured at \(entry.at.formatted(date: .omitted, time: .standard))")
                    } else if loadingImage {
                        ProgressView().frame(height: 160)
                    } else {
                        Label("This screenshot is no longer available.", systemImage: "photo")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 100)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: enlarged ? 640 : 300)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(entry.title.isEmpty ? "Local screenshot" : entry.title)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading screen evidence…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Label("No screenshot was retained for this stretch. Older activity has text evidence only.", systemImage: "photo")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: queryID) {
            loading = true
            let result = await store.entries(from: from, to: to, bundles: bundles)
            guard !Task.isCancelled else { return }
            entries = result
            loading = false
        }
        .task(id: selected?.id) {
            image = nil
            imageID = nil
            guard let entry = selected else { loadingImage = false; return }
            loadingImage = true
            let result = await store.thumbnail(for: entry, maxPixelSize: 1600)
            guard !Task.isCancelled else { return }
            image = result
            imageID = entry.id
            loadingImage = false
        }
    }

    private func move(_ direction: Int) {
        guard let entry = selected, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let next = index + direction
        if entries.indices.contains(next) { selectedID = entries[next].id }
    }
}


/// A tiny trend line; gaps where a value is nil.
struct Sparkline: View {
    let values: [Double?]

    var body: some View {
        Canvas { ctx, size in
            let pts = values.enumerated().compactMap { i, v in
                v.map { CGPoint(x: size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: size.height * (1 - CGFloat($0))) }
            }
            guard pts.count >= 2 else { return }
            var p = Path()
            p.move(to: pts[0])
            for q in pts.dropFirst() { p.addLine(to: q) }
            ctx.stroke(p, with: .color(Color.secondaryText), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if let last = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(.primary))
            }
        }
    }
}
