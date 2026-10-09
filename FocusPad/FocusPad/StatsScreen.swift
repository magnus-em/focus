import SwiftUI
import SwiftData
import FocusCore

struct StatsScreen: View {
    @EnvironmentObject var settings: PadSettings
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    @Query(sort: \StoredProblem.date, order: .reverse) private var problems: [StoredProblem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                topMetricsRow
                heatmapCard
                consistencyCard
                problemBreakdownCard
                lifetimeCard
            }
            .padding(PadTheme.pad)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.large)
    }

    private var totalMinutes: Double {
        sessions.filter { $0.isFocus }.reduce(0) { $0 + $1.durationMinutes }
    }
    private var totalSessions: Int {
        sessions.filter { $0.isFocus }.count
    }

    private var topMetricsRow: some View {
        let streak = PadStats.currentStreak(sessions)
        let best = PadStats.bestStreak(sessions)
        let consistency = PadStats.consistencyScore(sessions, days: 30)
        return HStack(spacing: 10) {
            PadMetric(value: PadStats.fmtHoursOnly(totalMinutes),
                      label: "TOTAL", icon: "hourglass",
                      tint: FocusColors.focusRed)
            PadMetric(value: "\(streak)d",
                      label: "STREAK", icon: "flame.fill",
                      tint: .orange,
                      trailing: best > 0 ? "best \(best)" : nil)
            PadMetric(value: "\(Int(consistency * 100))%",
                      label: "30-DAY CONSISTENCY", icon: "circle.dotted",
                      tint: PadTheme.consistencyRing)
        }
    }

    private var heatmapCard: some View {
        let by = PadStats.minutesByDay(sessions, days: 18 * 7)
        return PadCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    PadSectionHeader(title: "ACTIVITY · 18 WEEKS")
                    Spacer()
                    Text(PadStats.fmtHoursOnly(by.values.reduce(0, +)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HeatmapView(minutesByDay: by, weeks: 18, tint: FocusColors.focusRed)
                }
            }
        }
    }

    private var consistencyCard: some View {
        let last14 = PadStats.lastNDaysMinutes(sessions, days: 14)
        let goalMin = max(1, Double(settings.dailyGoalHours) * 60)
        let avg = last14.map(\.1).reduce(0, +) / Double(max(1, last14.count))
        return PadCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PadSectionHeader(title: "DAILY GOAL HIT RATE")
                    Spacer()
                    Text("avg \(PadStats.fmtMinutes(avg))/d")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(last14, id: \.0) { (day, mins) in
                        let pct = min(mins / goalMin, 1.5)
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(height: 100)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(pct >= 1 ? FocusColors.goalGreen : FocusColors.focusRed.opacity(pct > 0 ? 0.7 : 0.0))
                                    .frame(height: CGFloat(min(pct, 1.0)) * 100)
                            }
                            Text(dayLetter(day)).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func dayLetter(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"
        return f.string(from: d)
    }

    private var problemBreakdownCard: some View {
        let weekProblems = PadStats.problemsThisWeek(problems)
        let weeklyGoal = max(1, settings.quantWeeklyGoal + settings.sweWeeklyGoal)
        let pctWeek = min(1.0, Double(weekProblems) / Double(weeklyGoal))
        return PadCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PadSectionHeader(title: "PROBLEMS · 7 DAYS")
                    Spacer()
                    Text("\(weekProblems) / \(weeklyGoal)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(PadTheme.problemsRing)
                            .frame(width: max(6, geo.size.width * pctWeek))
                    }
                }
                .frame(height: 8)

                let byDomain = Dictionary(grouping: problems) { $0.domain }
                HStack(spacing: 14) {
                    ForEach(ProblemDomain.allCases, id: \.self) { d in
                        let count = byDomain[d]?.count ?? 0
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(count)").font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(d.color)
                            Text(d.rawValue.uppercased())
                                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                .foregroundStyle(d.color)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10).fill(d.color.opacity(0.1))
                        )
                    }
                }
            }
        }
    }

    private var lifetimeCard: some View {
        let bestDay = sessions.filter { $0.isFocus }
            .reduce(into: [Date: Double]()) {
                $0[Calendar.current.startOfDay(for: $1.startTime), default: 0] += $1.durationMinutes
            }
            .max { $0.value < $1.value }
        return PadCard {
            VStack(alignment: .leading, spacing: 10) {
                PadSectionHeader(title: "LIFETIME")
                HStack(spacing: 14) {
                    lifetimeStat(value: PadStats.fmtHoursOnly(totalMinutes), label: "Total Hours")
                    lifetimeStat(value: "\(totalSessions)", label: "Sessions")
                    if let best = bestDay {
                        lifetimeStat(value: PadStats.fmtMinutes(best.value), label: "Best Day")
                    }
                }
            }
        }
    }

    private func lifetimeStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
