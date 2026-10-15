import Foundation
import FocusCore

/// The coach's cloud access: the user's xAI key from the Keychain and one
/// daily dollar cap shared by every call.
enum Coach {
    static let capKey = "coachDailyCapUSD"

    static let budget = CoachBudget(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/coach/spend.jsonl"),
        dailyCapUSD: UserDefaults.standard.object(forKey: capKey) as? Double ?? 5)

    static var client: XAIClient? { XAIKey.load().map { XAIClient(key: $0) } }
}
