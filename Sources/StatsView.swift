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
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("LAST 7 DAYS")
                Spacer()
                if prior > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(formatMinutes(abs(delta))) vs prior")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(delta >= 0 ? .green : .red)
                }
            }

            Text(formatMinutes(last))
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Chart {
                ForEach(days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", d.hours))
                        .foregroundStyle(goal > 0 && d.hours >= goal ? Color.green : red)
                        .cornerRadius(3)
                }
                if goal > 0 {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0...max(goal, days.map(\.hours).max() ?? 0, 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
                        .font(.system(size: 8))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.system(size: 9))
                }
            }
            .frame(height: 90)

            HStack(spacing: 0) {
                metric(formatMinutes(last / 7), "avg / day")
                metric(formatMinutes(store.averageSessionMinutes(last: 20)), "avg session")
                metric("\(Int(consistency * 100))%", "days active (14d)",
                       color: consistency >= 0.8 ? .green : consistency >= 0.5 ? .orange : .red)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Split

    private var splitCard: some View {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        let split = splitAllTime ? store.minutesByTag() : store.minutesByTag(since: start)
        let total = split.reduce(0.0) { $0 + $1.minutes }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("FOCUS SPLIT")
                Spacer()
                Picker("", selection: $splitAllTime) {
                    Text("7 days").tag(false)
                    Text("All time").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }

            if total == 0 {
                Text("No focus logged in this range.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
                            Text(e.tag).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(formatMinutes(e.minutes))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                            Text("\(Int((e.minutes / total * 100).rounded()))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Heatmap

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("LAST 18 WEEKS")
                Spacer()
                HStack(spacing: 2) {
                    Text("less").font(.system(size: 8)).foregroundStyle(.tertiary)
                    ForEach([0.0, 30, 60, 120], id: \.self) { m in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(HeatmapView.color(for: m))
                            .frame(width: 7, height: 7)
                    }
                    Text("more").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            HeatmapView(data: store.heatmapData(weeks: 18))
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
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
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    private func metric(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
        return Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.2 + t * 0.8)
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
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: CGFloat(wi) * (cell + gap))
                        }
                    }
                }
                .frame(height: 10, alignment: .topLeading)
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
