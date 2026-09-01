import Foundation
import ObservationCore

/// What the user cares about, expressed as preferences rather than as rules.
///
/// The profile changes *ranking and wording* only. It never changes what is
/// observed, never changes confidence, and never silently changes a setting on
/// the device (§9.7).
public struct PrivacyProfile: Codable, Sendable, Hashable, Identifiable {
    public enum Strictness: String, Codable, Sendable, Hashable, CaseIterable {
        case balanced
        case minimizeTracking
        case maximumLocalProcessing
        case custom
    }

    public enum DeviceRole: String, Codable, Sendable, Hashable, CaseIterable {
        case personal
        case work
        case shared
    }

    public let id: UUID
    public var name: String
    /// 0 = "surface every tracker", 100 = "I accept tracking".
    public var trackingTolerance: Int
    /// 0 = "location access is fine", 100 = "location is my top concern".
    public var locationSensitivity: Int
    public var analyticsTolerance: Int
    public var crashReportingTolerance: Int
    public var advertisingTolerance: Int
    public var socialSharingTolerance: Int
    public var strictness: Strictness
    public var deviceRole: DeviceRole
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        trackingTolerance: Int,
        locationSensitivity: Int,
        analyticsTolerance: Int,
        crashReportingTolerance: Int,
        advertisingTolerance: Int,
        socialSharingTolerance: Int,
        strictness: Strictness,
        deviceRole: DeviceRole = .personal,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.trackingTolerance = Self.clamp(trackingTolerance)
        self.locationSensitivity = Self.clamp(locationSensitivity)
        self.analyticsTolerance = Self.clamp(analyticsTolerance)
        self.crashReportingTolerance = Self.clamp(crashReportingTolerance)
        self.advertisingTolerance = Self.clamp(advertisingTolerance)
        self.socialSharingTolerance = Self.clamp(socialSharingTolerance)
        self.strictness = strictness
        self.deviceRole = deviceRole
        self.updatedAt = updatedAt
    }

    private static func clamp(_ value: Int) -> Int { min(100, max(0, value)) }

    public static let balanced = PrivacyProfile(
        id: DeterministicUUID.make(namespace: .application, name: "profile.balanced"),
        name: "Balanced",
        trackingTolerance: 45,
        locationSensitivity: 55,
        analyticsTolerance: 55,
        crashReportingTolerance: 75,
        advertisingTolerance: 40,
        socialSharingTolerance: 50,
        strictness: .balanced,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    public static let minimizeTracking = PrivacyProfile(
        id: DeterministicUUID.make(namespace: .application, name: "profile.minimize-tracking"),
        name: "Minimize Tracking",
        trackingTolerance: 10,
        locationSensitivity: 80,
        analyticsTolerance: 25,
        crashReportingTolerance: 60,
        advertisingTolerance: 5,
        socialSharingTolerance: 25,
        strictness: .minimizeTracking,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    public static let maximumLocalProcessing = PrivacyProfile(
        id: DeterministicUUID.make(namespace: .application, name: "profile.maximum-local"),
        name: "Maximum Local Processing",
        trackingTolerance: 15,
        locationSensitivity: 85,
        analyticsTolerance: 20,
        crashReportingTolerance: 40,
        advertisingTolerance: 5,
        socialSharingTolerance: 20,
        strictness: .maximumLocalProcessing,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    public static let presets: [PrivacyProfile] = [balanced, minimizeTracking, maximumLocalProcessing]

    /// Multiplier applied when ranking a finding (§13.6). Never below 0.5, so a
    /// tolerant profile reorders findings but never hides one.
    public func relevanceMultiplier(forCategoryKeys keys: Set<String>) -> Double {
        var multiplier = 1.0
        func apply(_ key: String, tolerance: Int, weight: Double) {
            guard keys.contains(key) else { return }
            // tolerance 0 → weight up, tolerance 100 → weight down
            multiplier *= 1.0 + weight * (50.0 - Double(tolerance)) / 100.0
        }
        apply("advertising", tolerance: advertisingTolerance, weight: 0.6)
        apply("analytics", tolerance: analyticsTolerance, weight: 0.5)
        apply("crashReporting", tolerance: crashReportingTolerance, weight: 0.4)
        apply("social", tolerance: socialSharingTolerance, weight: 0.4)
        apply("attribution", tolerance: trackingTolerance, weight: 0.5)
        apply("dataBroker", tolerance: trackingTolerance, weight: 0.6)
        apply("locationIntelligence", tolerance: 100 - locationSensitivity, weight: 0.6)
        apply("location", tolerance: 100 - locationSensitivity, weight: 0.6)
        return min(1.8, max(0.5, multiplier))
    }
}
