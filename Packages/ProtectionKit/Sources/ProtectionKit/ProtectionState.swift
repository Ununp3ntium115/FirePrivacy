import Foundation
import ObservationCore

/// Encrypted DNS state (DNS-001).
public enum EncryptedDNSState: String, Codable, Sendable, Hashable {
    case notConfigured
    case configured
    case active
    case failed
}

/// What the user must be shown before encrypted DNS is enabled (DNS-003).
public struct DNSResolverDisclosure: Codable, Sendable, Hashable {
    public let providerID: String
    public let operatorName: String
    public let destination: String
    public let loggingPolicy: String
    public let retention: String
    public let jurisdiction: String
    public let blockingBehavior: String
    public let failureBehavior: String
    public let queryNamesLeaveDevice: Bool

    public init(
        providerID: String,
        operatorName: String,
        destination: String,
        loggingPolicy: String,
        retention: String,
        jurisdiction: String,
        blockingBehavior: String,
        failureBehavior: String,
        queryNamesLeaveDevice: Bool
    ) {
        self.providerID = providerID
        self.operatorName = operatorName
        self.destination = destination
        self.loggingPolicy = loggingPolicy
        self.retention = retention
        self.jurisdiction = jurisdiction
        self.blockingBehavior = blockingBehavior
        self.failureBehavior = failureBehavior
        self.queryNamesLeaveDevice = queryNamesLeaveDevice
    }

    /// What encrypted DNS does *not* cover (DNS-005). Shown alongside every
    /// resolver choice so the feature is never oversold.
    public static let coverageLimits = [
        "Apps that use their own encrypted resolver are unaffected.",
        "Connections made straight to an IP address never ask DNS anything.",
        "Answers already cached on the device are not re-resolved.",
        "Private Relay and other tunnels resolve names their own way.",
    ]
}

public enum SafariContentBlockerState: String, Codable, Sendable, Hashable {
    case unavailable
    case disabled
    case enabled
}

public enum ManagedFilterState: String, Codable, Sendable, Hashable {
    /// Consumer builds never activate the managed content filter (ENT-002).
    case notApplicable
    case requiresSupervision
    case configured
    case active
}

/// The whole protection picture (§12.1).
public struct ProtectionState: Codable, Sendable, Hashable {
    public var urlFilterState: URLFilterState
    public var urlFilterProfile: URLFilterProfile?
    public var filterDatasetVersion: String?
    public var filterLastVerified: Date?
    public var dnsState: EncryptedDNSState
    public var dnsProviderID: String?
    public var safariExtensionState: SafariContentBlockerState
    public var managedFilterState: ManagedFilterState

    public init(
        urlFilterState: URLFilterState = .unsupported,
        urlFilterProfile: URLFilterProfile? = nil,
        filterDatasetVersion: String? = nil,
        filterLastVerified: Date? = nil,
        dnsState: EncryptedDNSState = .notConfigured,
        dnsProviderID: String? = nil,
        safariExtensionState: SafariContentBlockerState = .unavailable,
        managedFilterState: ManagedFilterState = .notApplicable
    ) {
        self.urlFilterState = urlFilterState
        self.urlFilterProfile = urlFilterProfile
        self.filterDatasetVersion = filterDatasetVersion
        self.filterLastVerified = filterLastVerified
        self.dnsState = dnsState
        self.dnsProviderID = dnsProviderID
        self.safariExtensionState = safariExtensionState
        self.managedFilterState = managedFilterState
    }

    /// True only when something is actually filtering. Used by the dashboard so
    /// "protected" is never shown optimistically.
    public var isAnyProtectionActive: Bool {
        urlFilterState.isProtecting || dnsState == .active || safariExtensionState == .enabled
    }
}

/// Steps offered when an app or site stops working (URLF-010).
public enum ProtectionTroubleshooting {
    public struct Step: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
    }

    public static let steps: [Step] = [
        Step(
            id: "pause",
            title: "Pause protection for an hour",
            detail: "If the problem disappears while protection is paused, the filter is involved. If it does not, something else is."
        ),
        Step(
            id: "identify",
            title: "Note which app or site is affected",
            detail: "Fire Privacy does not record what you visit, so it cannot work this out for you."
        ),
        Step(
            id: "allow",
            title: "Add a local allowance",
            detail: "You can record a destination as allowed on this device. The note stays on this iPhone."
        ),
        Step(
            id: "report",
            title: "Report the rule",
            detail: "Sending a rule report includes the destination and the app you name — never your browsing history, and never automatically."
        ),
        Step(
            id: "rollback",
            title: "Roll back to the previous list",
            detail: "Fire Privacy keeps the previous signed list so a bad release can be undone without waiting for an app update."
        ),
        Step(
            id: "remove",
            title: "Remove protection entirely",
            detail: "Turn it off here, or open Settings › General › VPN & Device Management and remove the Fire Privacy configuration. This works even if Fire Privacy will not open."
        ),
    ]
}
