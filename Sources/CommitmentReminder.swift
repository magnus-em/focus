import Foundation
import Combine
import UserNotifications
import FocusCore

/// End-of-day "did you keep your commitment?" notification. One pending
/// request at a time, rescheduled whenever today's record or the reminder
/// settings change, so answering early (End Day, dashboard) cancels it.
final class CommitmentReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CommitmentReminder()

    private static let requestID = "commitment-review"
    private static let categoryID = "COMMITMENT_REVIEW"
    private static let yesAction = "COMMITMENT_YES"
    private static let noAction = "COMMITMENT_NO"
    private static let laterAction = "COMMITMENT_LATER"

    private weak var dayStore: DayStore?
    private weak var settings: AppSettings?
    private var onOpen: (() -> Void)?
    private var snoozedUntil: Date?
    /// This class is the app's only notification delegate; taps on other notifications
    /// (e.g. the LeetCode nudge) are forwarded here by request identifier.
    var onOtherTap: ((String) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    func install(dayStore: DayStore, settings: AppSettings, onOpen: @escaping () -> Void) {
        self.dayStore = dayStore
        self.settings = settings
        self.onOpen = onOpen

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [
                    UNNotificationAction(identifier: Self.yesAction, title: "Yes, I did it"),
                    UNNotificationAction(identifier: Self.noAction, title: "No", options: [.destructive]),
                    UNNotificationAction(identifier: Self.laterAction, title: "Ask again in 1 hour"),
                ],
                intentIdentifiers: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Publishers.Merge(
            dayStore.$records.map { _ in () },
            settings.objectWillChange.map { _ in () }
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.reschedule() }
        .store(in: &cancellables)

        reschedule()
    }

    func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])

        guard let settings, settings.commitmentEnabled, settings.commitmentReviewReminder,
              let record = dayStore?.todayRecord,
              let text = record.commitmentText, !text.isEmpty,
              record.commitmentFulfilled == nil else { return }

        let cal = Calendar.current
        if let s = snoozedUntil, !cal.isDateInToday(s) || s <= Date() { snoozedUntil = nil }
        let fire = snoozedUntil ?? cal.date(bySettingHour: settings.commitmentReviewMinutes / 60,
                                        minute: settings.commitmentReviewMinutes % 60,
                                        second: 0, of: Date())!
        guard fire > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Did you keep your word today?"
        content.body = "\u{201C}\(text)\u{201D}"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["dayID": record.id.uuidString]

        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(
            identifier: Self.requestID,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        ))
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let requestID = response.notification.request.identifier
        guard requestID == Self.requestID else {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                DispatchQueue.main.async { [weak self] in self?.onOtherTap?(requestID) }
            }
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        let dayID = (info["dayID"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case Self.yesAction:
                if let dayID { self.dayStore?.setFulfillment(true, forDayID: dayID) }
            case Self.noAction:
                if let dayID { self.dayStore?.setFulfillment(false, forDayID: dayID) }
            case Self.laterAction:
                self.snoozedUntil = Date().addingTimeInterval(3600)
                self.reschedule()
            case UNNotificationDefaultActionIdentifier:
                // The end-of-day review asks kept/missed along with the rest.
                self.onOpen?()
            default:
                break
            }
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let showCommitmentReview = Notification.Name("FocusShowCommitmentReview")
}
