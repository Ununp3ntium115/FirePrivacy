import Foundation
import ObservationCore

/// A permission state the *user* told Fire Privacy about (PER-005).
///
/// Stored separately from anything Apple reported and always labeled as
/// user-entered, because Fire Privacy cannot read another app's current
/// permission state and must never imply that it can (§3.1).
public struct SelfReportedPermission: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable, CaseIterable {
        case notReviewed
        case denied
        case askNextTime
        case whileUsing
        case always
        case limited
        case full
        case unknown

        public var displayName: String {
            switch self {
            case .notReviewed: "Not reviewed"
            case .denied: "Denied"
            case .askNextTime: "Ask next time"
            case .whileUsing: "While using the app"
            case .always: "Always"
            case .limited: "Limited"
            case .full: "Full access"
            case .unknown: "Unknown"
            }
        }
    }

    public var id: String { "\(bundleID.rawValue)|\(sensorType.identifier)" }
    public let bundleID: BundleIdentifier
    public let sensorType: SensorType
    public let state: State
    /// The user's judgement of whether the access made sense (rule
    /// SENSOR-UNEXPECTED-004).
    public let isExpected: Bool?
    public let recordedAt: Date
    public let note: UntrustedText?

    public init(
        bundleID: BundleIdentifier,
        sensorType: SensorType,
        state: State,
        isExpected: Bool?,
        recordedAt: Date,
        note: UntrustedText? = nil
    ) {
        self.bundleID = bundleID
        self.sensorType = sensorType
        self.state = state
        self.isExpected = isExpected
        self.recordedAt = recordedAt
        self.note = note
    }
}

public struct SelfReportedPermissionSet: Codable, Sendable, Hashable {
    public private(set) var entries: [String: SelfReportedPermission]

    public init(entries: [SelfReportedPermission] = []) {
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func entry(bundleID: BundleIdentifier, sensorType: SensorType) -> SelfReportedPermission? {
        entries["\(bundleID.rawValue)|\(sensorType.identifier)"]
    }

    public mutating func record(_ entry: SelfReportedPermission) {
        entries[entry.id] = entry
    }

    public var isEmpty: Bool { entries.isEmpty }
}

/// The manual verification steps Fire Privacy can offer (PER-002).
///
/// Fire Privacy can open **its own** settings page and nothing else, so the
/// checklist is written as instructions the user performs, not as automation it
/// pretends to do (PER-003).
public struct PermissionAuditChecklist: Sendable, Hashable {
    public struct Step: Sendable, Hashable, Identifiable {
        public let id: String
        public let text: String
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public let sensorType: SensorType
    public let settingsPath: String
    public let steps: [Step]
    /// What the user loses by tightening this permission (PER-004).
    public let featureImpact: String
    /// A middle option, when iOS offers one.
    public let lessRestrictiveAlternative: String?

    public static func checklist(for sensorType: SensorType) -> PermissionAuditChecklist {
        switch sensorType {
        case .location, .preciseLocation, .approximateLocation:
            PermissionAuditChecklist(
                sensorType: sensorType,
                settingsPath: "Settings › Privacy & Security › Location Services",
                steps: [
                    Step(id: "open", text: "Open Settings, then Privacy & Security."),
                    Step(id: "category", text: "Choose Location Services."),
                    Step(id: "review", text: "Review each app and the access it has."),
                    Step(id: "precise", text: "For apps that do not need street-level accuracy, turn Precise Location off."),
                    Step(id: "return", text: "Return to Fire Privacy and record what you chose."),
                ],
                featureImpact: "Apps that rely on your position may ask you to enter it manually, or may show results for a wider area.",
                lessRestrictiveAlternative: "“While Using the App” with Precise Location off is often enough for weather, news and shopping apps."
            )
        case .microphone:
            PermissionAuditChecklist(
                sensorType: sensorType,
                settingsPath: "Settings › Privacy & Security › Microphone",
                steps: [
                    Step(id: "open", text: "Open Settings, then Privacy & Security."),
                    Step(id: "category", text: "Choose Microphone."),
                    Step(id: "review", text: "Turn off any app that does not need to record audio."),
                    Step(id: "return", text: "Return to Fire Privacy and record what you chose."),
                ],
                featureImpact: "Voice messages, calls and voice search stop working in apps you turn off.",
                lessRestrictiveAlternative: nil
            )
        case .camera:
            PermissionAuditChecklist(
                sensorType: sensorType,
                settingsPath: "Settings › Privacy & Security › Camera",
                steps: [
                    Step(id: "open", text: "Open Settings, then Privacy & Security."),
                    Step(id: "category", text: "Choose Camera."),
                    Step(id: "review", text: "Turn off any app that does not need the camera."),
                    Step(id: "return", text: "Return to Fire Privacy and record what you chose."),
                ],
                featureImpact: "Scanning, video calls and in-app photo capture stop working in apps you turn off.",
                lessRestrictiveAlternative: nil
            )
        case .contacts:
            PermissionAuditChecklist(
                sensorType: sensorType,
                settingsPath: "Settings › Privacy & Security › Contacts",
                steps: [
                    Step(id: "open", text: "Open Settings, then Privacy & Security."),
                    Step(id: "category", text: "Choose Contacts."),
                    Step(id: "review", text: "Review which apps can read your address book."),
                    Step(id: "return", text: "Return to Fire Privacy and record what you chose."),
                ],
                featureImpact: "Friend-finding and invite features stop working, and some apps ask you to type addresses manually.",
                lessRestrictiveAlternative: "iOS 18 and later can share only selected contacts instead of the whole address book."
            )
        case .photos, .photosFullLibrary, .photosSelected:
            PermissionAuditChecklist(
                sensorType: sensorType,
                settingsPath: "Settings › Privacy & Security › Photos",
                steps: [
                    Step(id: "open", text: "Open Settings, then Privacy & Security."),
                    Step(id: "category", text: "Choose Photos."),
                    Step(id: "review", text: "Change apps with Full Access to Limited Access where you can."),
                    Step(id: "return", text: "Return to Fire Privacy and record what you chose."),
                ],
                featureImpact: "You pick photos one at a time instead of the app browsing your whole library.",
                lessRestrictiveAlternative: "“Limited Access” lets you choose exactly which photos an app can see."
            )
        default:
            PermissionAuditChecklist(
                sensorType: sensorType,
                settingsPath: "Settings › Privacy & Security",
                steps: [
                    Step(id: "open", text: "Open Settings, then Privacy & Security."),
                    Step(id: "category", text: "Choose the category for this kind of access."),
                    Step(id: "review", text: "Review which apps have access."),
                    Step(id: "return", text: "Return to Fire Privacy and record what you chose."),
                ],
                featureImpact: "Features that depend on this access may stop working in apps you turn off.",
                lessRestrictiveAlternative: nil
            )
        }
    }
}
