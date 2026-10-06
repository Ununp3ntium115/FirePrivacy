import Foundation
import FirePrivacyCore
import UserNotifications

enum ReminderError: Error { case invalidSchedule, permissionDenied, consentRequired }

@MainActor
final class LocalReminderService {
    private let center: UNUserNotificationCenter
    private let identifier = "FirePrivacy.weekly-local-reminder"
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func schedule(weekday: Int, hour: Int, minute: Int, authorization: ConsentAuthorization,
                  checker: any ConsentAuthorizationChecking) async throws {
        guard (1...7).contains(weekday), (0...23).contains(hour), (0...59).contains(minute) else {
            throw ReminderError.invalidSchedule
        }
        guard authorization.feature == .localReminders,
              authorization.scopeIdentity == "weekly-local-reminder-v1",
              authorization.disclosureVersion == ConsentDisclosure.currentVersion,
              await checker.validateAuthorization(authorization) else { throw ReminderError.consentRequired }
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw ReminderError.permissionDenied }
        guard await checker.validateAuthorization(authorization) else { throw ReminderError.consentRequired }
        let content = UNMutableNotificationContent()
        content.title = "Your privacy review"
        content.body = "Import a fresh App Privacy Report when you’re ready to review recorded activity."
        content.sound = .default
        // Generic text only: no domain, app, finding, count or report identifier on the lock screen.
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute, weekday: weekday), repeats: true)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        guard await checker.validateAuthorization(authorization) else {
            await removeAll(); throw ReminderError.consentRequired
        }
    }

    func removeAll() async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
