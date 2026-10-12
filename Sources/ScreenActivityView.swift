import SwiftUI
import FocusCore

/// Dashboard card: what the screen watcher thinks you worked on, next to what
/// was tracked, so its accuracy can be judged on real days.
struct ScreenActivitySection: View {
    @ObservedObject var watcher: ScreenWatcher
    let day: Date
    let sessions: [WorkSession]

    @State private var expanded: Set<Date> = []
    @State private var showAll = false

    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }

    private var activities: [ScreenActivity] {
        watcher.activities(from: day, to: dayEnd).filter { $0.minutes >= 1 }.reversed()
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

    /// Share of labeled screen time whose tracked category matched, by span.
    private var agreement: (pct: Double, minutes: Double)? {
        var matched = 0.0, total = 0.0
        for a in activities {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT THE SCREEN SAW")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if let ag = agreement {
                    Text("Matches what you tracked \(Int(ag.pct * 100))% of \(fmt(ag.minutes))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(ag.pct >= 0.8 ? .green : ag.pct >= 0.6 ? .orange : .red)
                }
            }
            if list.isEmpty {
                Text(watcher.status == "Watching" || watcher.status.hasPrefix("Watching")
                     ? "Nothing recorded for this day yet."
                     : "Screen watching: \(watcher.status). Settings → Screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(showAll ? list : Array(list.prefix(12))) { a in row(a) }
            if list.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(list.count)") { showAll.toggle() }
                    .font(.system(size: 10.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text("Blocks are grouped from a snapshot every 15s; names come from the on-device model. Click a block to see each snapshot. Hand-correct mistakes with \"Still X\" on the suggestion card.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    private func row(_ a: ScreenActivity) -> some View {
        let trackedLabel = tracked(a.start, a.end)
        let match = trackedLabel != nil && trackedLabel == a.category
        let open = expanded.contains(a.start)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(a.start.formatted(date: .omitted, time: .shortened))
                    Text(fmt(a.minutes)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)

                RoundedRectangle(cornerRadius: 2)
                    .fill(a.category.map(categoryColor) ?? Color.secondary.opacity(0.4))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(watcher.name(for: a))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(2)
                    Text(a.apps.prefix(3).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(a.category ?? "Unlabeled")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(a.category.map(categoryColor) ?? .secondary)
                    HStack(spacing: 3) {
                        if a.category != nil {
                            Image(systemName: match ? "checkmark" : "arrow.left.arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(match ? .green : .orange)
                        }
                        Text(trackedLabel.map { "tracked \($0)" } ?? "untracked")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if open { expanded.remove(a.start) } else { expanded.insert(a.start) }
            }
            if open {
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
        }
        .padding(.vertical, 2)
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(max(mn, 1))m"
    }
}
