import Foundation
import FocusCore

/// The coach's cloud access: the user's xAI key from the Keychain and one
/// daily dollar cap shared by every call.
enum Coach {
    static let capKey = "coachDailyCapUSD"
    /// Off until the user turns it on (Settings → Coach, or the morning recall).
    static let enabledKey = "coachCloudEnabled"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static let consent = "Sends screen text, window titles and some screenshots to xAI (Grok) to write your day summaries, morning questions and answers in Ask Focus. Messages, Mail, Passwords, incognito and unconfirmed browser windows are never sent. xAI keeps API requests 30 days for abuse review and doesn't train on them."

    static let budget = CoachBudget(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/coach/spend.jsonl"),
        dailyCapUSD: UserDefaults.standard.object(forKey: capKey) as? Double ?? 5)

    /// nil unless the user turned the cloud coach on and a key is in the Keychain.
    static var client: XAIClient? {
        guard enabled else { return nil }
        return XAIKey.load().map { XAIClient(key: $0) }
    }
}
