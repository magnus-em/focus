import FocusCore
import SwiftUI
import Charts

struct StatsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @AppStorage("statsSplitAllTime") private var splitAllTime = false

    private let red = Color(red: 0.96, green: 0.36, blue: 0.36)

    private struct DayBar: Identifiable {
        let date: Date
        let hours: Double
        var id: Date { date }
    }

    private var last7: [DayBar] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: d) else { return nil }
            return DayBar(date: d, hours: store.workMinutes(since: d, until: next) / 60)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                weekCard
                splitCard
                heatmapCard
                recordsRow
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
    }

    // MARK: - Week

    private var weekCard: some View {
        let last = store.last7DaysMinutes
        let prior = store.prior7DaysMinutes
        let delta = last - prior
        let goal = Double(settings.dailyGoal)
        let days = last7
        let consistency = store.consistencyScore(days: 14)

        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Last 7 days")

            VStack(alignment: .leading, spacing: 2) {
                Text(formatMinutes(last))
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                if prior > 0 {
                    Label("\(formatMinutes(abs(delta))) \(delta >= 0 ? "more" : "less") than the week before",
                          systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(delta >= 0 ? Color.good : Color.secondaryText)
                }
            }

            Chart {
                ForEach(days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", d.hours))
                        .foregroundStyle(goal > 0 && d.hours >= goal ? Color.good : Color.primary.opacity(0.28))
                        .cornerRadius(4)
                }
                if goal > 0 {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(Int(goal))h goal").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: 0...max(goal, days.map(\.hours).max() ?? 0, 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: [0]) { _ in AxisGridLine() }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }
            .frame(height: 96)

            HStack(spacing: 0) {
                metric(formatMinutes(last / 7), "a day")
                metric(formatMinutes(store.averageSessionMinutes(last: 20)), "a block")
                let active = days.filter { $0.hours > 0 }.count
                metric("\(active) of 7", "days with focus", color: active == 7 ? Color.good : .primary)
            }
        }
        .padding(14)
        .contentCard()
    }

    // MARK: - Split

    private var splitCard: some View {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        let split = splitAllTime ? store.minutesByTag() : store.minutesByTag(since: start)
        let total = split.reduce(0.0) { $0 + $1.minutes }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Focus split")
                Spacer()
                Picker("", selection: $splitAllTime) {
                    Text("7 days").tag(false)
                    Text("All time").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if total == 0 {
                Text("No focus logged in this range.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(split, id: \.tag) { e in
                            Rectangle()
                                .fill(categoryColor(e.tag))
                                .frame(width: max(0, geo.size.width * CGFloat(e.minutes / total) - 1.5))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)

                VStack(spacing: 5) {
                    ForEach(split, id: \.tag) { e in
                        HStack(spacing: 6) {
                            Circle().fill(categoryColor(e.tag)).frame(width: 6, height: 6)
                            Text(e.tag).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(formatMinutes(e.minutes))
                                .font(.system(size: 13).monospacedDigit())
                            Text("\(Int((e.minutes / total * 100).rounded()))%")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(14)
        .contentCard()
    }

    // MARK: - Heatmap

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Last 18 weeks")
                Spacer()
                HStack(spacing: 2) {
                    Text("less").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach([0.0, 30, 60, 120], id: \.self) { m in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(HeatmapView.color(for: m))
                            .frame(width: 7, height: 7)
                    }
                    Text("more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HeatmapView(data: store.heatmapData(weeks: 18))
        }
        .padding(14)
        .contentCard()
    }

    // MARK: - Records

    private var recordsRow: some View {
        HStack(spacing: 0) {
            MiniStat(value: formatHours(store.totalWorkHours), label: "Total")
            MiniStat(value: formatHours(store.bestWeekMinutes / 60.0), label: "Best week",
                     icon: "crown.fill", iconColor: Color(red: 1.0, green: 0.75, blue: 0.2))
            MiniStat(value: formatMinutes(store.bestDayMinutes), label: "Best day")
            MiniStat(value: "\(store.bestStreak)d", label: "Best streak",
                     icon: "flame.fill", iconColor: .orange)
        }
        .padding(.vertical, 12)
        .contentCard()
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
    }

    private func metric(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        durationText(minutes: minutes)
    }

    private func formatHours(_ hours: Double) -> String {
        hours >= 1 ? String(format: "%.0fh", hours) : "\(Int(hours * 60))m"
    }
}

// MARK: - Small UI helpers

// MARK: - Heatmap (unchanged)

struct HeatmapView: View {
    let data: [(date: Date, minutes: Double)]
    private let gap: CGFloat = 2
    private let weeks = 18

    static func color(for minutes: Double) -> Color {
        guard minutes >= 0 else { return .clear }
        guard minutes > 0 else { return Color.secondary.opacity(0.12) }
        let t = min(1.0, minutes / 120.0)
        return Color.good.opacity(0.2 + t * 0.8)
    }

    private func monthLabel(weekIndex: Int) -> String? {
        let idx = weekIndex * 7
        guard idx < data.count else { return nil }
        let date = data[idx].date
        guard weekIndex == 0 || Calendar.current.component(.day, from: date) <= 7 else { return nil }
        return date.formatted(.dateTime.month(.abbreviated))
    }

    var body: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - gap * CGFloat(weeks - 1)) / CGFloat(weeks)
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<weeks, id: \.self) { wi in
                        if let m = monthLabel(weekIndex: wi) {
                            Text(m)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: CGFloat(wi) * (cell + gap))
                        }
                    }
                }
                .frame(height: 14, alignment: .topLeading)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<weeks, id: \.self) { wi in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { di in
                                let idx = wi * 7 + di
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(idx < data.count ? Self.color(for: data[idx].minutes) : .clear)
                                    .frame(width: cell, height: cell)
                                    .help(idx < data.count && data[idx].minutes >= 0
                                          ? "\(data[idx].date.formatted(.dateTime.month(.abbreviated).day())): \(Int(data[idx].minutes / 60))h \(Int(data[idx].minutes) % 60)m"
                                          : "")
                            }
                        }
                    }
                }
            }
        }
        .aspectRatio(CGFloat(weeks) / 7.6, contentMode: .fit)
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
                Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
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
