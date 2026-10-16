#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData
import FocusCore

/// Simulator-only sample day for screenshots (`-seedDemo`). The simulator's
/// store has no iCloud account, so nothing here reaches real data.
enum DemoSeed {
    @MainActor
    static func run(container: ModelContainer, engine: FocusTimerEngine) {
        let context = container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<StoredWorkSession>())) ?? 0) == 0 else { return }
        let now = Date()
        func at(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
        let blocks: [(Double, Double, String?)] = [
            (-11, -3, "Sleep"), (-3, -2.6, "Meals"), (-2.6, -1.4, "Math"), (-1.4, -1.3, nil), (-1.3, -0.6, "Math"),
        ]
        for (a, b, label) in blocks {
            context.insert(StoredWorkSession(value: WorkSession(
                startTime: at(a), durationMinutes: (b - a) * 60, type: label == nil ? .shortBreak : .work, label: label)))
        }
        context.insert(StoredHealthEvent(date: at(-2.9), kind: HealthKind.adderallXR20.rawValue))
        let record = StoredDayRecord()
        record.calendarDay = Calendar.current.startOfDay(for: now)
        record.dayStart = at(-3)
        record.commitmentText = "Finish the MATH 244 practice midterm and redo the induction problems I missed."
        context.insert(record)
        try? context.save()
        engine.switchTo("Reading", at: at(-0.4))
    }

    static func briefs() -> [String: DayBrief] {
        let now = Date()
        func at(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
        let clock = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let brief = DayBrief(
            day: DayBrief.dayKey(now), written: at(-0.1),
            headline: "Two Math blocks on the MATH 244 practice midterm: induction went well, relations were slower and mostly asked of ChatGPT. Then a short stretch nothing tracked before Reading.",
            headlineAsOf: at(-0.3),
            fixes: [
                .init(id: "a", start: at(-0.6), end: at(-0.4),
                      text: "Nothing logged \(clock(at(-0.6)))–\(clock(at(-0.4))). The screen showed Math.", suggestion: "Math", running: false),
            ],
            blocks: [
                .init(start: at(-2.6), end: at(-1.4), category: "Math", title: "MATH 244", line: "Strong induction on the review sheet"),
                .init(start: at(-1.3), end: at(-0.6), category: "Math", title: "MATH 244", line: "Relations: composition and partial orders"),
            ],
            courses: [
                .init(code: "MATH 244", minutes: 114, topics: ["Strong induction", "Relations", "Partial orders"],
                      shaky: ["Checking antisymmetry from a matrix"]),
            ],
            noticed: ["You asked ChatGPT for the answer before trying on 3 of 5 relations problems."])
        return [brief.day: brief]
    }
}
#endif
