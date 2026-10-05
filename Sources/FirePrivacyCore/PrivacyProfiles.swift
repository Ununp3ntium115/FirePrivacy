import Foundation

public enum ProfileStrictness: String, Codable, Sendable { case balanced, minimizeTracking, maximumLocalProcessing, custom }
public enum DeviceRole: String, Codable, Sendable { case personal, work, shared }

/// User preferences change recommendation relevance, never observed facts or confidence.
public struct PrivacyProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let trackingTolerance: Int
    public let locationSensitivity: Int
    public let analyticsTolerance: Int
    public let crashReportingTolerance: Int
    public let advertisingTolerance: Int
    public let socialSharingTolerance: Int
    public let strictness: ProfileStrictness
    public let deviceRole: DeviceRole
    public let updatedAt: Date

    public init(id: UUID = UUID(), name: String, trackingTolerance: Int = 45, locationSensitivity: Int = 55,
                analyticsTolerance: Int = 55, crashReportingTolerance: Int = 75,
                advertisingTolerance: Int = 40, socialSharingTolerance: Int = 50,
                strictness: ProfileStrictness = .custom, deviceRole: DeviceRole = .personal,
                updatedAt: Date = Date()) {
        self.id = id
        self.name = ImportedText.sanitize(name, maximumCharacters: 80)
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
    public static let balanced = PrivacyProfile(id: ContentDigest.stableID("FirePrivacy/Profile/v1/balanced"), name: "Balanced", strictness: .balanced, updatedAt: Date(timeIntervalSince1970: 0))
    public static let minimizeTracking = PrivacyProfile(id: ContentDigest.stableID("FirePrivacy/Profile/v1/minimizeTracking"), name: "Minimize tracking", trackingTolerance: 10, locationSensitivity: 80, analyticsTolerance: 25, crashReportingTolerance: 60, advertisingTolerance: 5, socialSharingTolerance: 25, strictness: .minimizeTracking, updatedAt: Date(timeIntervalSince1970: 0))
    public static let maximumLocalProcessing = PrivacyProfile(id: ContentDigest.stableID("FirePrivacy/Profile/v1/maximumLocalProcessing"), name: "Maximum local processing", trackingTolerance: 15, locationSensitivity: 85, analyticsTolerance: 20, crashReportingTolerance: 40, advertisingTolerance: 5, socialSharingTolerance: 20, strictness: .maximumLocalProcessing, updatedAt: Date(timeIntervalSince1970: 0))
    public static let presets: [PrivacyProfile] = [.balanced, .minimizeTracking, .maximumLocalProcessing]

    /// Version 1 preference weighting. This is relevance, not a probability or privacy score.
    public func relevanceMultiplier(forCategoryKeys keys: Set<String>) -> Double {
        var multiplier = 1.0
        let settings: [(String, Int, Double)] = [
            ("advertising", advertisingTolerance, 0.6), ("analytics", analyticsTolerance, 0.5),
            ("crashReporting", crashReportingTolerance, 0.4), ("social", socialSharingTolerance, 0.4),
            ("attribution", trackingTolerance, 0.5), ("dataBroker", trackingTolerance, 0.6),
            ("locationIntelligence", 100 - locationSensitivity, 0.6), ("location", 100 - locationSensitivity, 0.6)
        ]
        for (key, tolerance, weight) in settings where keys.contains(key) {
            multiplier *= 1 + weight * Double(50 - tolerance) / 100
        }
        return min(1.8, max(0.5, multiplier))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, trackingTolerance, locationSensitivity, analyticsTolerance, crashReportingTolerance
        case advertisingTolerance, socialSharingTolerance, strictness, deviceRole, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  trackingTolerance: try c.decode(Int.self, forKey: .trackingTolerance),
                  locationSensitivity: try c.decode(Int.self, forKey: .locationSensitivity),
                  analyticsTolerance: try c.decode(Int.self, forKey: .analyticsTolerance),
                  crashReportingTolerance: try c.decode(Int.self, forKey: .crashReportingTolerance),
                  advertisingTolerance: try c.decode(Int.self, forKey: .advertisingTolerance),
                  socialSharingTolerance: try c.decode(Int.self, forKey: .socialSharingTolerance),
                  strictness: try c.decode(ProfileStrictness.self, forKey: .strictness),
                  deviceRole: try c.decode(DeviceRole.self, forKey: .deviceRole),
                  updatedAt: try c.decode(Date.self, forKey: .updatedAt))
    }
}

public enum PermissionState: String, Codable, Sendable { case unknown, notAsked, denied, limited, allowed, whileUsing, always }

/// A user's dated statement. App Privacy Report does not reveal current permission settings.
public struct SelfReportedPermission: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(bundleID.utf8.count):\(bundleID)|\(category.utf8.count):\(category)" }
    public let bundleID: String
    public let category: String
    public let state: PermissionState
    public let isExpected: Bool?
    public let note: String?
    public let updatedAt: Date
    public init(bundleID: String, category: String, state: PermissionState = .unknown,
                isExpected: Bool? = nil, note: String? = nil, updatedAt: Date = Date()) {
        self.bundleID = ImportedText.sanitize(bundleID, maximumCharacters: 256)
        self.category = ImportedText.sanitize(category, maximumCharacters: 128)
        self.state = state
        self.isExpected = isExpected
        self.note = note.map { ImportedText.sanitize($0, maximumCharacters: 512) }
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case bundleID, category, state, isExpected, note, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bundleID: try c.decode(String.self, forKey: .bundleID), category: try c.decode(String.self, forKey: .category),
                  state: try c.decode(PermissionState.self, forKey: .state), isExpected: try c.decodeIfPresent(Bool.self, forKey: .isExpected),
                  note: try c.decodeIfPresent(String.self, forKey: .note), updatedAt: try c.decode(Date.self, forKey: .updatedAt))
    }
}

public struct ManualPermissionAudit: Codable, Equatable, Sendable {
    public private(set) var entries: [SelfReportedPermission]
    public init(entries: [SelfReportedPermission] = []) {
        var byID: [String: SelfReportedPermission] = [:]
        for entry in entries {
            if let previous = byID[entry.id], previous.updatedAt > entry.updatedAt { continue }
            byID[entry.id] = entry
        }
        self.entries = byID.values.sorted { $0.id < $1.id }
    }
    public func entry(bundleID: String, category: String) -> SelfReportedPermission? {
        entries.first { $0.bundleID == bundleID && $0.category == category }
    }
    public mutating func record(_ entry: SelfReportedPermission) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.id < $1.id }
    }
    public mutating func remove(bundleID: String, category: String) {
        entries.removeAll { $0.bundleID == bundleID && $0.category == category }
    }
    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try c.decode([SelfReportedPermission].self, forKey: .entries))
    }
}
