import Combine
import Foundation
import FocusCore

/// Keeps today's and yesterday's `DayBrief` in iCloud's key-value store for
/// the phone: the same story the Day page shows, recomputed every 10 minutes
/// and shortly after the log changes. The phone has no screen, calendar or
/// AI notes of its own.
@MainActor
final class DayBriefPublisher {
    static let shared = DayBriefPublisher()

    private let today = DayStoryModel()
    private let yesterday = DayStoryModel()
    private var days: [ObjectIdentifier: Date] = [:]
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var pending: DispatchWorkItem?
    private var yesterdayWritten: Date?

    func start(store: SessionStore, timer: TimerManager, settings: AppSettings) {
        guard ticker == nil else { return }
        for model in [today, yesterday] {
            model.$story.compactMap { $0 }.sink { [weak self, weak model] story in
                guard let self, let model, let day = self.days[ObjectIdentifier(model)] else { return }
                let brief = DayBrief.make(day: day, story: story, written: Date())
                if brief.publish() {
                    SyncLog.event("dayBriefPublished", ["day": brief.day, "fixes": brief.fixes.count, "blocks": brief.blocks.count])
                }
            }
            .store(in: &bag)
        }
        let refresh: () -> Void = { [weak self] in self?.refresh(store: store, timer: timer, settings: settings) }
        store.$sessions.dropFirst().sink { [weak self] _ in self?.soon(refresh) }.store(in: &bag)
        ticker = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Task { @MainActor in refresh() } }
        soon(refresh)
    }

    private func soon(_ refresh: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: refresh)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func refresh(store: SessionStore, timer: TimerManager, settings: AppSettings) {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        let focus = Set(settings.tags.filter { !settings.lifeTags.contains($0) })
        let live = [timer.currentInProgressSession, timer.currentInProgressBreak].compactMap { $0 }
            .map { WorkSession(startTime: $0.startTime, durationMinutes: now.timeIntervalSince($0.startTime) / 60,
                               type: $0.type, label: $0.label) }
        days[ObjectIdentifier(today)] = dayStart
        today.refresh(day: dayStart, sessions: store.sessions.filter { TimeIntegrity.end(of: $0) > dayStart },
                      live: live, focus: focus)

        // Yesterday only changes when its day record is (re)written in the morning.
        guard let before = cal.date(byAdding: .day, value: -1, to: dayStart) else { return }
        let written = CoachDayWorker.shared.record(for: before)?.generatedAt
        guard DayBrief.read(before) == nil || written != yesterdayWritten else { return }
        yesterdayWritten = written
        days[ObjectIdentifier(yesterday)] = before
        yesterday.refresh(day: before, sessions: store.sessions.filter {
            TimeIntegrity.end(of: $0) > before && $0.startTime < dayStart
        }, live: [], focus: focus)
    }
}
