import Foundation
import ObservationCore

/// A user's local decision about a domain (KB-007).
///
/// Overrides never leave the device automatically and never modify the shared
/// knowledge base: they are the user's opinion about their own device.
public struct DomainOverride: Codable, Sendable, Hashable, Identifiable {
    public enum Disposition: String, Codable, Sendable, Hashable {
        /// Treat as expected on this device; lowers severity, never confidence.
        case trusted
        /// Always surface, even when the rules would rank it low.
        case alwaysReview
        /// User's own category assignment.
        case customCategory
        /// User asked for this host to be allowed by protection.
        case localAllow
        /// User asked for this host to be blocked by protection.
        case localBlockRequest
    }

    public var id: String { host.value }
    public let host: NormalizedHost
    public let disposition: Disposition
    public let customCategories: [DomainCategory]
    public let note: UntrustedText?
    public let createdAt: Date

    public init(
        host: NormalizedHost,
        disposition: Disposition,
        customCategories: [DomainCategory] = [],
        note: UntrustedText? = nil,
        createdAt: Date
    ) {
        self.host = host
        self.disposition = disposition
        self.customCategories = customCategories
        self.note = note
        self.createdAt = createdAt
    }
}

/// The user's override set, keyed by normalized host.
public struct DomainOverrideSet: Codable, Sendable, Hashable {
    public private(set) var overrides: [String: DomainOverride]

    public init(overrides: [DomainOverride] = []) {
        self.overrides = Dictionary(overrides.map { ($0.host.value, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func override(for host: NormalizedHost) -> DomainOverride? {
        overrides[host.value]
    }

    public mutating func set(_ override: DomainOverride) {
        overrides[override.host.value] = override
    }

    public mutating func remove(host: NormalizedHost) {
        overrides.removeValue(forKey: host.value)
    }

    public var isEmpty: Bool { overrides.isEmpty }

    public var sorted: [DomainOverride] {
        overrides.values.sorted { $0.host.value < $1.host.value }
    }
}
