import ActivityKit
import Combine
import Foundation
import FocusCore

/// Keeps one Live Activity in step with the timer: shown while anything is
/// tracked, ended when nothing is. Changes made on the Mac reach it when this
/// app next runs (foreground, or a background CloudKit push).
@MainActor
enum FocusLiveActivity {
    private static var current: Activity<FocusActivityAttributes>? {
        Activity<FocusActivityAttributes>.activities.first
    }

    static func show(label: String, isBreak: Bool, since: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = FocusActivityAttributes.ContentState(
            label: label.isEmpty ? "Focus" : label, isBreak: isBreak,
            isFocus: !isBreak && !FocusCategories.isLife(label), since: since
        )
        if let a = current {
            guard a.content.state != state else { return }
            await a.update(ActivityContent(state: state, staleDate: nil))
        } else {
            _ = try? Activity.request(attributes: FocusActivityAttributes(),
                                      content: ActivityContent(state: state, staleDate: nil))
        }
    }

    static func end() async {
        for a in Activity<FocusActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static var observer: AnyCancellable?

    /// Mirror the engine (which also applies peers' state) into the activity.
    static func follow(_ engine: FocusTimerEngine) {
        observer = engine.$sessionStartTime
            .combineLatest(engine.$currentLabel, engine.$phase)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { start, label, phase in
                Task { @MainActor in
                    if let start {
                        await show(label: phase.isBreak ? "Break" : label, isBreak: phase.isBreak, since: start)
                    } else {
                        await end()
                    }
                }
            }
    }
}
