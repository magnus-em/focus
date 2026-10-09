import SwiftUI
import SwiftData
import FocusCore

/// Apple Fitness "Awards"-style milestones. Each award computes its earned/
/// progress state from the current session + problem data.
struct AwardsScreen: View {
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    @Query(sort: \StoredProblem.date, order: .reverse) private var problems: [StoredProblem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryHeader
                LazyVGrid(columns: [.init(.flexible(), spacing: 12), .init(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(allAwards()) { award in
                        AwardTile(award: award)
                    }
                }
            }
            .padding(PadTheme.pad)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Awards")
        .navigationBarTitleDisplayMode(.large)
    }

    private var earnedCount: Int { allAwards().filter(\.earned).count }
    private var totalCount: Int { allAwards().count }

    private var summaryHeader: some View {
        PadCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.yellow.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: Double(earnedCount) / Double(max(1, totalCount)))
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "rosette")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.yellow)
                }
                .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(earnedCount) / \(totalCount) earned")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Keep going — every session counts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Award definitions

    struct Award: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let color: Color
        let earned: Bool
        let progressText: String?
    }

    private func allAwards() -> [Award] {
        let totalMinutes = sessions.filter { $0.isFocus }.reduce(0) { $0 + $1.durationMinutes }
        let totalHours = totalMinutes / 60.0
        let streak = PadStats.currentStreak(sessions)
        let bestStreak = PadStats.bestStreak(sessions)
        let bestDayMin = bestDayMinutes()
        let problemCount = problems.count
        let totalSessions = sessions.filter { $0.isFocus }.count

        return [
            Award(id: "first-session",
                  title: "First Session",
                  subtitle: "Complete one focus session",
                  icon: "flag.fill", color: .green,
                  earned: totalSessions >= 1,
                  progressText: totalSessions >= 1 ? "Earned" : "0 / 1"),

            Award(id: "ten-sessions",
                  title: "Getting Going",
                  subtitle: "10 focus sessions",
                  icon: "10.circle.fill", color: .blue,
                  earned: totalSessions >= 10,
                  progressText: "\(min(totalSessions, 10)) / 10"),

            Award(id: "hundred-sessions",
                  title: "Centurion",
                  subtitle: "100 focus sessions",
                  icon: "100.circle.fill", color: .purple,
                  earned: totalSessions >= 100,
                  progressText: "\(min(totalSessions, 100)) / 100"),

            Award(id: "ten-hours",
                  title: "Deep End",
                  subtitle: "10 hours of focus",
                  icon: "hourglass.bottomhalf.filled", color: .orange,
                  earned: totalHours >= 10,
                  progressText: String(format: "%.1f / 10h", min(totalHours, 10))),

            Award(id: "fifty-hours",
                  title: "Half a Hundred",
                  subtitle: "50 hours of focus",
                  icon: "hourglass", color: .red,
                  earned: totalHours >= 50,
                  progressText: String(format: "%.0f / 50h", min(totalHours, 50))),

            Award(id: "hundred-hours",
                  title: "Triple Digits",
                  subtitle: "100 hours of focus",
                  icon: "trophy.fill", color: .yellow,
                  earned: totalHours >= 100,
                  progressText: String(format: "%.0f / 100h", min(totalHours, 100))),

            Award(id: "streak-3",
                  title: "On a Roll",
                  subtitle: "3-day streak",
                  icon: "flame.fill", color: .orange,
                  earned: bestStreak >= 3,
                  progressText: "\(min(bestStreak, 3)) / 3"),

            Award(id: "streak-7",
                  title: "Full Week",
                  subtitle: "7-day streak",
                  icon: "flame.fill", color: .red,
                  earned: bestStreak >= 7,
                  progressText: "\(min(bestStreak, 7)) / 7"),

            Award(id: "streak-30",
                  title: "Monthly Habit",
                  subtitle: "30-day streak",
                  icon: "flame.circle.fill", color: .pink,
                  earned: bestStreak >= 30,
                  progressText: "\(min(bestStreak, 30)) / 30"),

            Award(id: "best-day-4h",
                  title: "Solid Day",
                  subtitle: "4 hours in one day",
                  icon: "sun.max.fill", color: .orange,
                  earned: bestDayMin >= 240,
                  progressText: String(format: "%.1f / 4h", min(bestDayMin / 60.0, 4))),

            Award(id: "best-day-8h",
                  title: "Marathon",
                  subtitle: "8 hours in one day",
                  icon: "sun.horizon.fill", color: .red,
                  earned: bestDayMin >= 480,
                  progressText: String(format: "%.1f / 8h", min(bestDayMin / 60.0, 8))),

            Award(id: "first-problem",
                  title: "First Solve",
                  subtitle: "Log one problem",
                  icon: "checkmark.circle.fill", color: .green,
                  earned: problemCount >= 1,
                  progressText: problemCount >= 1 ? "Earned" : "0 / 1"),

            Award(id: "fifty-problems",
                  title: "Pattern Recognizer",
                  subtitle: "50 problems logged",
                  icon: "brain.head.profile", color: .blue,
                  earned: problemCount >= 50,
                  progressText: "\(min(problemCount, 50)) / 50"),

            Award(id: "two-hundred-problems",
                  title: "Quant Cohort",
                  subtitle: "200 problems logged",
                  icon: "function", color: .purple,
                  earned: problemCount >= 200,
                  progressText: "\(min(problemCount, 200)) / 200"),

            Award(id: "active-streak",
                  title: "Currently On Fire",
                  subtitle: "Active streak ≥ 7 days",
                  icon: "bolt.fill", color: .yellow,
                  earned: streak >= 7,
                  progressText: "\(min(streak, 7)) / 7 active"),
        ]
    }

    private func bestDayMinutes() -> Double {
        sessions.filter { $0.isFocus }
            .reduce(into: [Date: Double]()) {
                $0[Calendar.current.startOfDay(for: $1.startTime), default: 0] += $1.durationMinutes
            }
            .values.max() ?? 0
    }
}

private struct AwardTile: View {
    let award: AwardsScreen.Award

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(award.earned ? award.color.opacity(0.18) : Color(.tertiarySystemFill))
                    .frame(width: 56, height: 56)
                Image(systemName: award.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(award.earned ? award.color : .secondary)
                    .opacity(award.earned ? 1.0 : 0.45)
            }

            Text(award.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(award.earned ? .primary : .secondary)
                .lineLimit(1)
            Text(award.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)

            if let p = award.progressText {
                Text(p)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(award.earned ? AnyShapeStyle(award.color) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: PadTheme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PadTheme.cardRadius)
                .stroke(award.earned ? award.color.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}
