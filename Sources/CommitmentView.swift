import SwiftUI
import FocusCore

struct CommitmentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var dayStore: DayStore
    @ObservedObject var store: SessionStore
    let timer: TimerManager
    @Binding var isShowing: Bool
    var previewMorningReview = false

    @State private var text = ""
    @State private var firstAction = ""
    @State private var firstCategory = ""
    @State private var firstTarget = ""
    @ObservedObject private var calendar = ClassCalendar.shared
    @FocusState private var focused: Bool

    private let red = Color.accentColor

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
                        MorningCorrectionView(store: store, settings: settings, timer: timer,
                                              preview: previewMorningReview)
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

                        }

                        NextBlockEditor(action: $firstAction, category: $firstCategory, target: $firstTarget,
                                        tags: settings.tags, suggestion: nextSuggestion)
                    }
                    .padding(18)
                }

                Divider()

                VStack(spacing: 6) {
                    Button {
                        guard !previewMorningReview else { return }
                        let cleaned = text.trimmingCharacters(in: .whitespaces)
                        settings.markCommitmentDone(text: cleaned)
                        dayStore.setCommitment(text: cleaned)
                        if !firstAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            NextBlockStore.shared.save(.init(action: firstAction,
                                category: firstCategory.isEmpty ? nil : firstCategory, target: firstTarget, source: "Your choice"), for: Date())
                        }
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
                        guard !previewMorningReview else { return }
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
        .onAppear {
            focused = true
            guard !previewMorningReview, let plan = NextBlockStore.shared.plan(for: Date()) else { return }
            firstAction = plan.action
            firstCategory = plan.category.flatMap { settings.tags.contains($0) ? $0 : nil } ?? ""
            firstTarget = plan.target
        }
    }

    private var nextSuggestion: NextBlockPlanner.Plan? {
        if previewMorningReview {
            return .init(action: "Work through one example of a partial order", category: "Math", source: "Your start-with note")
        }
        let previous = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        return NextBlockPlanner.suggest(on: Date(), startWith: EveningLog.entry(for: previous)?.firstTask,
            commitment: text.isEmpty ? dayStore.todayRecord?.commitmentText : text,
            exams: calendar.exams.map { .init(title: $0.title, date: $0.date, category: $0.category) })
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
