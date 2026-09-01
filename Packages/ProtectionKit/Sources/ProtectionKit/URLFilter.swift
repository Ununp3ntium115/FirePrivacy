import Foundation
import ObservationCore

/// Which dataset the filter is configured with (URLF-003).
public enum URLFilterProfile: String, Codable, Sendable, Hashable, CaseIterable {
    /// Reviewed advertising, attribution, cross-site tracking and data-broker
    /// endpoints, with conservative false-positive thresholds.
    case standard
    /// Adds broader analytics and personalization rules, with a stronger
    /// breakage warning.
    case strict
    /// Reserved. Disabled until per-user policy can be expressed without
    /// weakening the privacy properties of the lookup.
    case custom

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .strict: "Strict"
        case .custom: "Custom"
        }
    }

    public var isSelectable: Bool { self != .custom }

    public var breakageWarning: String? {
        switch self {
        case .standard: nil
        case .strict: "Strict blocks more measurement and personalization endpoints. Some apps show fewer recommendations, and a few may misbehave. You can switch back at any time."
        case .custom: "Custom lists are not available yet."
        }
    }
}

/// Whether the filter can be used at all (URLF-001).
public enum URLFilterAvailability: Sendable, Hashable {
    case available
    case unsupportedOSVersion(required: Int)
    case entitlementMissing
    case datasetUnavailable
    case relayNotApproved
    case managedByAnotherConfiguration

    public var isAvailable: Bool { self == .available }

    public var explanation: String {
        switch self {
        case .available: "Ready."
        case .unsupportedOSVersion(let required): "The system URL filter needs iOS \(required) or later."
        case .entitlementMissing: "This build does not carry the URL filter capability."
        case .datasetUnavailable: "No verified filter dataset is installed."
        case .relayNotApproved: "The privacy relay configuration has not been approved yet."
        case .managedByAnotherConfiguration: "Another filtering configuration is already installed on this device."
        }
    }
}

/// The states the UI must be able to tell apart (URLF-008).
///
/// `degraded` exists so the app can never show "protected" when it is not: a
/// filter that cannot reach a decision fails open, and the user is told.
public enum URLFilterState: String, Codable, Sendable, Hashable {
    case unsupported
    case available
    case enabling
    case active
    case updatePending
    case staleDataset
    case degradedFailOpen
    case disabled
    case configurationRemoved

    public var isProtecting: Bool { self == .active }

    public var displayName: String {
        switch self {
        case .unsupported: "Not available on this iPhone"
        case .available: "Available, not turned on"
        case .enabling: "Turning on…"
        case .active: "On"
        case .updatePending: "On, update pending"
        case .staleDataset: "On, list is out of date"
        case .degradedFailOpen: "Not filtering right now"
        case .disabled: "Off"
        case .configurationRemoved: "Removed in Settings"
        }
    }

    /// Plain statement of what is happening, used verbatim in the UI so the
    /// wording cannot drift into implying more protection than exists.
    public var explanation: String {
        switch self {
        case .unsupported: "This iPhone's version of iOS does not offer the system URL filter."
        case .available: "iOS can check requests against Fire Privacy's list once you turn this on."
        case .enabling: "Waiting for iOS to install the configuration."
        case .active: "iOS is checking requests against Fire Privacy's list. Fire Privacy does not receive the addresses."
        case .updatePending: "Filtering is on. A newer list is being installed."
        case .staleDataset: "Filtering is on, but the list has not been refreshed recently, so newer destinations may not be covered."
        case .degradedFailOpen: "The filter cannot reach a decision, so requests are being allowed. Nothing is being blocked right now."
        case .disabled: "No requests are being filtered."
        case .configurationRemoved: "The configuration was removed outside Fire Privacy. Turn it on again to restore filtering."
        }
    }
}

/// Everything needed to configure the system filter (URLF-004).
public struct URLFilterConfiguration: Codable, Sendable, Hashable {
    public let profile: URLFilterProfile
    public let pirServerURL: URL
    public let privacyPassIssuerURL: URL
    public let controlProviderBundleIdentifier: String
    public let prefilterUpdateInterval: TimeInterval
    public let localizedDescription: String
    /// Always false in Consumer Edition (§14.4): if the filter cannot decide,
    /// traffic is allowed and the user keeps working connectivity.
    public let shouldFailClosed: Bool
    /// Off by default and requires its own disclosure before it can be enabled
    /// (URLF-007).
    public let blockedURLReportingEnabled: Bool

    public init(
        profile: URLFilterProfile,
        pirServerURL: URL,
        privacyPassIssuerURL: URL,
        controlProviderBundleIdentifier: String,
        prefilterUpdateInterval: TimeInterval = 60 * 60 * 12,
        localizedDescription: String = "Fire Privacy tracker filter",
        shouldFailClosed: Bool = false,
        blockedURLReportingEnabled: Bool = false
    ) {
        self.profile = profile
        self.pirServerURL = pirServerURL
        self.privacyPassIssuerURL = privacyPassIssuerURL
        self.controlProviderBundleIdentifier = controlProviderBundleIdentifier
        self.prefilterUpdateInterval = prefilterUpdateInterval
        self.localizedDescription = localizedDescription
        self.shouldFailClosed = shouldFailClosed
        self.blockedURLReportingEnabled = blockedURLReportingEnabled
    }
}

/// What the user must be shown before the configuration is saved (URLF-002).
public struct URLFilterDisclosure: Sendable, Hashable {
    public let profile: URLFilterProfile
    public let datasetVersion: String
    public let blockedCategories: [String]
    public let covered: [String]
    public let notCovered: [String]
    public let privacyStatements: [String]
    public let howToTurnOff: [String]

    public static func standard(profile: URLFilterProfile, datasetVersion: String) -> URLFilterDisclosure {
        URLFilterDisclosure(
            profile: profile,
            datasetVersion: datasetVersion,
            blockedCategories: profile == .strict
                ? ["Advertising", "Attribution", "Cross-site tracking", "Data brokers", "Analytics", "Personalization"]
                : ["Advertising", "Attribution", "Cross-site tracking", "Data brokers"],
            covered: [
                "Requests made through Apple's networking, including Safari and apps that use URLSession.",
                "Apps that opt in to participate in URL filtering.",
            ],
            notCovered: [
                "Apps that use their own networking stack and do not opt in.",
                "Connections made directly to an IP address.",
                "Traffic inside another VPN or private relay that Fire Privacy cannot see.",
            ],
            privacyStatements: [
                "iOS performs the check. Fire Privacy does not receive the addresses you request.",
                "The lookup uses Apple's privacy-preserving path, so the server cannot see which entry was checked.",
                "Nothing about your imported report is sent anywhere as part of filtering.",
                "If a check cannot complete, the request is allowed rather than blocked.",
            ],
            howToTurnOff: [
                "Turn it off on the Protection screen in Fire Privacy.",
                "Or open Settings › General › VPN & Device Management and remove the Fire Privacy configuration.",
            ]
        )
    }
}

/// The interface the app depends on (§23.4).
public protocol URLFiltering: Sendable {
    func availability() async -> URLFilterAvailability
    func currentState() async -> URLFilterState
    func enable(profile: URLFilterProfile) async throws
    func disable() async throws
    func refreshDataset() async throws
}

/// Bridges to `NEURLFilterManager`.
///
/// Kept behind a protocol so this package builds and tests without the
/// NetworkExtension entitlement, and so the one file that touches iOS 26 API
/// lives in the app target where it is re-verified against each SDK.
public protocol URLFilterSystemBridge: Sendable {
    func systemAvailability() async -> URLFilterAvailability
    func loadState() async -> URLFilterState
    func save(configuration: URLFilterConfiguration) async throws
    func removeConfiguration() async throws
}

public enum URLFilterError: Error, Sendable, Equatable {
    case unavailable(String)
    case profileNotSelectable
    case datasetVerificationFailed(String)
    case saveFailed(String)
    case removeFailed(String)
}
