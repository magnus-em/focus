import SwiftUI
import FocusCore

final class NextBlockStore: ObservableObject {
    static let shared = NextBlockStore()
    private static let key = "nextBlockPlans"
    @Published private(set) var plans: [String: NextBlockPlanner.Plan] = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: NextBlockPlanner.Plan].self, from: data)) ?? [:]
    }()

    func plan(for day: Date) -> NextBlockPlanner.Plan? { plans[EveningLog.key(day)] }

    func save(_ plan: NextBlockPlanner.Plan, for day: Date) {
        let action = plan.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return }
        var copy = plan
        copy.action = String(action.prefix(240))
        copy.target = String(plan.target.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        plans[EveningLog.key(day)] = copy
        let keys = plans.keys.sorted().suffix(60)
        plans = plans.filter { keys.contains($0.key) }
        if let data = try? JSONEncoder().encode(plans) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    @MainActor
    static func suggestion(for day: Date, commitment: String?) -> NextBlockPlanner.Plan? {
        let previous = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        return NextBlockPlanner.suggest(on: day, startWith: EveningLog.entry(for: previous)?.firstTask,
            commitment: commitment, exams: ClassCalendar.shared.exams.map {
                .init(title: $0.title, date: $0.date, category: $0.category)
            })
    }
}

struct NextBlockEditor: View {
    @Binding var action: String
    @Binding var category: String
    @Binding var target: String
    let tags: [String]
    let suggestion: NextBlockPlanner.Plan?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your first block").font(.system(size: 15, weight: .semibold))
            Text("Pick one assignment or concept and the first thing you'll do.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            TextField("For example: prove the chain decomposition lemma", text: $action, axis: .vertical)
                .font(.system(size: 13)).textFieldStyle(.roundedBorder).lineLimit(2...3)
                .accessibilityLabel("First action")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Category", selection: $category) {
                    Text("Choose").tag("")
                    ForEach(tags, id: \.self) { Text($0).tag($0) }
                }
                .font(.system(size: 13))
                TextField("Target (optional)", text: $target)
                    .font(.system(size: 13)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Optional target, such as three problems")
            }
            if let suggestion, action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    action = suggestion.action
                    if let suggestedCategory = suggestion.category, tags.contains(suggestedCategory) { category = suggestedCategory }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(suggestion.source).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        Text(suggestion.action).font(.system(size: 13)).multilineTextAlignment(.leading)
                        Text("Use as a starting point").font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
            }
            Text("Saved with your commitment. Your timer changes when you choose to start.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }
}

struct NextBlockSummary: View {
    @ObservedObject private var plans = NextBlockStore.shared
    let day: Date
    var body: some View {
        if let plan = plans.plan(for: day) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your first block").font(.system(size: 15, weight: .semibold))
                Text(plan.action).font(.system(size: 14))
                if let category = plan.category {
                    Text(category + (plan.target.isEmpty ? "" : " · " + plan.target))
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                } else if !plan.target.isEmpty {
                    Text(plan.target).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        }
    }
}
