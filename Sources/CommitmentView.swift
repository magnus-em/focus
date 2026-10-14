import SwiftUI

struct CommitmentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var dayStore: DayStore
    @Binding var isShowing: Bool

    @State private var text = ""
    @FocusState private var focused: Bool

    private let red = Color.accentColor

    /// Last night's "start with", exams this week, the LeetCode goal and the
    /// hours goal, as one editable line.
    private var suggestion: String? {
        let cal = Calendar.current
        var parts: [String] = []
        if let y = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())),
           let first = EveningLog.entry(for: y)?.firstTask.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            parts.append("Start with \(first)")
        }
        for exam in ClassCalendar.shared.exams.prefix(2) {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: exam.date)).day ?? 99
            guard days <= 7 else { continue }
            let hours = days <= 2 ? 3 : days <= 5 ? 2 : 1
            let when = days == 0 ? "today" : days == 1 ? "tomorrow" : exam.date.formatted(.dateTime.weekday(.wide))
            parts.append("\(hours)h \(exam.category ?? "studying") for \(exam.title) (\(when))")
        }
        if settings.sweGoal > 0 { parts.append("\(settings.sweGoal) LeetCode problems") }
        if settings.dailyGoal > 0 { parts.append("\(settings.dailyGoal)h of focus") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 5) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    Text("Good \(greeting)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(todayString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Written commitment
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Today's commitment")
                                .font(.system(size: 15, weight: .semibold))
                            ZStack(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text("What will you accomplish today?")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 9)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $text)
                                    .font(.system(size: 13))
                                    .frame(minHeight: 70)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .focused($focused)
                            }
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(9)
                            if let plan = suggestion, text.isEmpty {
                                Button { text = plan } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "sparkles").foregroundStyle(Color.secondaryText)
                                        Text(plan).font(.system(size: 13)).multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 4)
                                        Text("Use").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("A starting point from last night's plan, upcoming exams and your goals")
                            }
                        }

                    }
                    .padding(18)
                }

                Divider()

                VStack(spacing: 6) {
                    Button {
                        let cleaned = text.trimmingCharacters(in: .whitespaces)
                        settings.markCommitmentDone(text: cleaned)
                        dayStore.setCommitment(text: cleaned)
                        isShowing = false
                    } label: {
                        Text("Start My Day")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.1) : red)
                            .cornerRadius(9)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        settings.markCommitmentDone(text: "")
                        dayStore.setCommitment(text: "")
                        isShowing = false
                    } label: {
                        Text("Skip for today")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .onAppear { focused = true }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "morning" : h < 17 ? "afternoon" : "evening"
    }

    private var todayString: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }
}
