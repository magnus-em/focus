import SwiftUI

struct StatsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @State private var newTagText = ""

    // Brand colors
    private let red = Color(red: 0.96, green: 0.36, blue: 0.36)
    private let quantColor = Color(red: 0.27, green: 0.62, blue: 0.83)   // blue
    private let sweColor   = Color(red: 0.96, green: 0.36, blue: 0.36)   // red
    private let otherColor = Color(red: 0.30, green: 0.78, blue: 0.74)   // teal

    private func color(for tag: String) -> Color { categoryColor(tag) }

    // MARK: - Derived metrics

    private var weekDelta: Double {
        store.last7DaysMinutes - store.prior7DaysMinutes
    }

    private var avgSession: Double { store.averageSessionMinutes(last: 20) }

    private var todayAtRisk: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return store.currentStreak > 0 && store.todayWorkMinutes == 0 && hour >= 16
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                todayCard

                weekCard

                focusSplitCard

                heatmapCard

                categoriesCard

                lifetimeRow
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
    }

    // MARK: - Today

    @ViewBuilder
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TODAY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                streakBadge
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(formatMinutes(store.todayWorkMinutes))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("focused")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if store.todayBreakMinutes >= 1 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(formatMinutes(store.todayBreakMinutes))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("on break")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            if settings.dailyGoal > 0 {
                let hoursToday = store.todayWorkMinutes / 60.0
                let pct = min(1.0, hoursToday / Double(settings.dailyGoal))
                let goalMet = pct >= 1.0
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Daily goal")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1fh / %dh", hoursToday, settings.dailyGoal))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(goalMet ? Color.green : Color.secondary)
                    }
                    ProgressBar(progress: pct, color: goalMet ? .green : red)
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    private var streakBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: store.currentStreak > 0
                  ? (todayAtRisk ? "exclamationmark.triangle.fill" : "flame.fill")
                  : "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(store.currentStreak > 0
                                 ? (todayAtRisk ? .orange : .orange)
                                 : .secondary)
            Text("\(store.currentStreak) day streak")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(todayAtRisk ? .orange : .primary)
        }
    }

    // MARK: - This week

    @ViewBuilder
    private var weekCard: some View {
        let last = store.last7DaysMinutes
        let prior = store.prior7DaysMinutes
        let delta = weekDelta
        let isUp = delta >= 0

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LAST 7 DAYS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatMinutes(last))
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                if prior > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(formatMinutes(abs(delta)))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isUp ? .green : .red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isUp ? Color.green : Color.red).opacity(0.1))
                    .clipShape(Capsule())
                    Text("vs prior 7d")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                MiniMetric(label: "Avg/day", value: formatMinutes(last / 7))
                MiniMetric(label: "Avg session", value: formatMinutes(avgSession))
                let consistency = store.consistencyScore(days: 14)
                MiniMetric(
                    label: "Consistency",
                    value: "\(Int(consistency * 100))%",
                    valueColor: consistency >= 0.8 ? .green : consistency >= 0.5 ? .orange : .red
                )
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Focus split (7d)

    @ViewBuilder
    private var focusSplitCard: some View {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        let split = store.minutesByTag(since: start)
        let total = split.reduce(0.0) { $0 + $1.minutes }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FOCUS SPLIT — LAST 7 DAYS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if total == 0 {
                Text("No tagged sessions yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                // Stacked horizontal bar
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.08))
                        HStack(spacing: 0) {
                            ForEach(split, id: \.tag) { entry in
                                Rectangle()
                                    .fill(color(for: entry.tag))
                                    .frame(width: w * CGFloat(entry.minutes / total))
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 10)

                VStack(spacing: 4) {
                    ForEach(split, id: \.tag) { entry in
                        HStack(spacing: 6) {
                            Circle().fill(color(for: entry.tag)).frame(width: 6, height: 6)
                            Text(entry.tag)
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(formatMinutes(entry.minutes))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("\(Int((entry.minutes / total) * 100))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Heatmap

    @ViewBuilder
    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST 18 WEEKS")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            HeatmapView(data: store.heatmapData(weeks: 18))
        }
    }

    // MARK: - Categories (lifetime)

    @ViewBuilder
    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CATEGORIES — LIFETIME")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            let byTag = store.minutesByTag(includeLife: true)
            let maxMins = byTag.first?.minutes ?? 1

            VStack(spacing: 6) {
                ForEach(settings.tags, id: \.self) { tag in
                    let minutes = byTag.first(where: { $0.tag == tag })?.minutes ?? 0
                    HStack(spacing: 8) {
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 60, alignment: .leading)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.08))
                            Capsule()
                                .fill(color(for: tag).opacity(0.75))
                                .frame(width: 80 * CGFloat(minutes / max(maxMins, 1)))
                        }
                        .frame(width: 80, height: 5)
                        Text(formatMinutes(minutes))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Spacer()
                        let isLife = settings.lifeTags.contains(tag)
                        Button(isLife ? "Life" : "Focus") {
                            if isLife { settings.lifeTags.removeAll { $0 == tag } }
                            else { settings.lifeTags.append(tag) }
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isLife ? Color.secondary : red)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((isLife ? Color.secondary : red).opacity(0.12)))
                        .buttonStyle(.plain)
                        .help(isLife ? "Life: tracked, not counted toward the daily goal. Click to make it Focus."
                                     : "Focus: counts toward the daily goal. Click to make it Life.")
                        Button {
                            settings.tags.removeAll { $0 == tag }
                            settings.lifeTags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Add new category
            HStack(spacing: 6) {
                TextField("New category…", text: $newTagText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .onSubmit { addTag() }
                if !newTagText.isEmpty {
                    Button("Add") { addTag() }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(red)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    // MARK: - Lifetime mini-stats

    @ViewBuilder
    private var lifetimeRow: some View {
        HStack(spacing: 0) {
            MiniStat(value: formatHours(store.totalWorkHours), label: "Total Hours")
            MiniStat(value: formatHours(store.bestWeekMinutes / 60.0), label: "Best Week",
                     icon: "crown.fill", iconColor: Color(red: 1.0, green: 0.75, blue: 0.2))
            MiniStat(value: "\(store.bestStreak)d",
                     label: "Best Streak",
                     icon: "flame.fill",
                     iconColor: .orange)
            MiniStat(value: formatMinutes(store.bestDayMinutes), label: "Best Day")
        }
    }

    // MARK: - Helpers

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.tags.contains(trimmed) else { newTagText = ""; return }
        settings.tags.append(trimmed)
        newTagText = ""
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatHours(_ hours: Double) -> String {
        hours >= 1 ? String(format: "%.1fh", hours) : "\(Int(hours * 60))m"
    }
}

// MARK: - Small UI helpers

private struct MiniMetric: View {
    let label: String
    let value: String
    var valueColor: Color = Color(NSColor.secondaryLabelColor)

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(progress))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Heatmap (unchanged)

struct HeatmapView: View {
    let data: [(date: Date, minutes: Double)]
    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 2
    private let weeks = 18

    private func heatColor(for minutes: Double) -> Color {
        guard minutes >= 0 else { return .clear }
        guard minutes > 0   else { return Color.secondary.opacity(0.12) }
        let t = min(1.0, minutes / 120.0)
        return Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.2 + t * 0.8)
    }

    private func monthLabel(weekIndex: Int) -> String? {
        let idx = weekIndex * 7
        guard idx < data.count else { return nil }
        let date = data[idx].date
        let day = Calendar.current.component(.day, from: date)
        guard weekIndex == 0 || day <= 7 else { return nil }
        let f = DateFormatter(); f.dateFormat = "MMM"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { wi in
                    Text(monthLabel(weekIndex: wi) ?? "")
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: cellSize)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { wi in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { di in
                            let idx = wi * 7 + di
                            if idx < data.count {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(heatColor(for: data[idx].minutes))
                                    .frame(width: cellSize, height: cellSize)
                            } else {
                                Color.clear.frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Lifetime mini-stat

struct MiniStat: View {
    let value: String; let label: String
    var icon: String? = nil; var iconColor: Color = .primary
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundStyle(iconColor) }
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// Keep StatCard used elsewhere (in case)
struct StatCard: View {
    let value: String; let label: String
    var icon: String? = nil; var iconColor: Color = .primary
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(iconColor) }
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
            }
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
