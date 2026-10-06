import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ProtectionComponent: String, Codable, CaseIterable, Sendable {
    case safari, encryptedDNS, systemURLFilter, managed
}

public enum ProtectionPhase: String, Codable, Sendable {
    case unavailable, needsConfiguration, disabled, awaitingUserEnablement, active
    case staleDataset, revokedDataset, failed
}

/// Each component has a distinct scope. Resolver encryption does not imply tracker blocking.
public struct ProtectionComponentState: Codable, Equatable, Sendable {
    public let component: ProtectionComponent
    public let phase: ProtectionPhase
    public let systemConfirmed: Bool
    public let detail: String
    public let verifiedAt: Date?
    public let datasetVersion: UInt64?
    public var isActive: Bool { phase == .active && systemConfirmed }

    public init(component: ProtectionComponent, phase: ProtectionPhase,
                systemConfirmed: Bool = false, detail: String, verifiedAt: Date? = nil,
                datasetVersion: UInt64? = nil) {
        self.component = component
        self.phase = phase == .active && !systemConfirmed ? .awaitingUserEnablement : phase
        self.systemConfirmed = systemConfirmed
        self.detail = detail
        self.verifiedAt = verifiedAt
        self.datasetVersion = datasetVersion
    }
}

public struct ProtectionSnapshot: Codable, Equatable, Sendable {
    public var safari: ProtectionComponentState
    public var encryptedDNS: ProtectionComponentState
    public var systemURLFilter: ProtectionComponentState
    public var managed: ProtectionComponentState

    public init(safari: ProtectionComponentState, encryptedDNS: ProtectionComponentState,
                systemURLFilter: ProtectionComponentState, managed: ProtectionComponentState) {
        self.safari = safari
        self.encryptedDNS = encryptedDNS
        self.systemURLFilter = systemURLFilter
        self.managed = managed
    }
}

public enum ProtectionConfigurationError: Error, Equatable, Sendable {
    case invalidDomain, invalidEndpoint, invalidResolverAddress, missingDisclosure
    case invalidBundleIdentifier, excessiveRules, missingDataset, unapprovedDeployment
    case consentRequired, consentRevoked, appGroupUnavailable, wrongDatasetKind
}

public enum ProtectionCanonicalization {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Domains are ASCII/Punycode, never a URL, IP, wildcard or regular expression.
    public static func domain(_ input: String) throws -> String {
        let value = input.lowercased()
        guard value == input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty, value.utf8.count <= 253, !value.hasSuffix("."),
              value.contains("."), !value.contains(":"), !value.contains("/"),
              !isIPAddress(value) else { throw ProtectionConfigurationError.invalidDomain }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") &&
            !label.hasSuffix("-") && label.utf8.allSatisfy {
                ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
            }
        }) else { throw ProtectionConfigurationError.invalidDomain }
        return value
    }

    public static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    public static func requireHTTPS(_ value: URL) throws {
        guard value.scheme?.lowercased() == "https", let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.fragment == nil,
              !host.lowercased().hasSuffix(".example"), host.lowercased() != "example.com",
              host.lowercased() != "localhost", value.port == nil || value.port == 443 else {
            throw ProtectionConfigurationError.invalidEndpoint
        }
    }

    public static func requireBundleIdentifier(_ value: String) throws {
        guard value.utf8.count <= 200, value.split(separator: ".").count >= 2,
              !value.hasPrefix("."), !value.hasSuffix("."), !value.contains(".."),
              value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                  ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }) else {
            throw ProtectionConfigurationError.invalidBundleIdentifier
        }
    }
}

public struct DNSResolverConfiguration: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable { case https, tls }
    public let transport: Transport
    public let servers: [String]
    public let serverURL: URL?
    public let serverName: String?
    public let operatorName: String
    public let privacyPolicyURL: URL
    public let loggingDisclosure: String
    public let retentionDisclosure: String
    public let jurisdictionDisclosure: String
    public let filteringDisclosure: String

    public init(transport: Transport, servers: [String], serverURL: URL? = nil,
                serverName: String? = nil, operatorName: String, privacyPolicyURL: URL,
                loggingDisclosure: String, retentionDisclosure: String,
                jurisdictionDisclosure: String, filteringDisclosure: String) {
        self.transport = transport; self.servers = servers; self.serverURL = serverURL
        self.serverName = serverName; self.operatorName = operatorName
        self.privacyPolicyURL = privacyPolicyURL; self.loggingDisclosure = loggingDisclosure
        self.retentionDisclosure = retentionDisclosure; self.jurisdictionDisclosure = jurisdictionDisclosure
        self.filteringDisclosure = filteringDisclosure
    }

    public func validate() throws {
        guard !servers.isEmpty, servers.count <= 8, Set(servers).count == servers.count,
              servers.allSatisfy(ProtectionCanonicalization.isIPAddress) else {
            throw ProtectionConfigurationError.invalidResolverAddress
        }
        try ProtectionCanonicalization.requireHTTPS(privacyPolicyURL)
        for value in [operatorName, loggingDisclosure, retentionDisclosure, jurisdictionDisclosure, filteringDisclosure] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 4_000 else {
                throw ProtectionConfigurationError.missingDisclosure
            }
        }
        switch transport {
        case .https:
            guard let serverURL, serverName == nil else { throw ProtectionConfigurationError.invalidEndpoint }
            try ProtectionCanonicalization.requireHTTPS(serverURL)
        case .tls:
            guard serverURL == nil, let serverName else { throw ProtectionConfigurationError.invalidEndpoint }
            _ = try ProtectionCanonicalization.domain(serverName)
        }
    }

    public var scopeIdentity: String { get throws {
        try validate()
        return "dns/v1:" + ContentDigest.sha256(try ProtectionCanonicalization.encode(self))
    } }
}

public struct SafariRuleConfiguration: Codable, Equatable, Sendable {
    public let blockedDomains: [String]
    public let allowedDomains: [String]
    public let userBlockedDomains: [String]
    public let datasetVersion: UInt64
    public let manifestDigest: String?
    public init(blockedDomains: [String], allowedDomains: [String] = [], userBlockedDomains: [String] = [],
                datasetVersion: UInt64, manifestDigest: String? = nil) {
        self.blockedDomains = blockedDomains; self.allowedDomains = allowedDomains; self.datasetVersion = datasetVersion
        self.userBlockedDomains = userBlockedDomains
        self.manifestDigest = manifestDigest
    }
    public func validate() throws {
        guard datasetVersion > 0, blockedDomains.count <= 50_000, allowedDomains.count <= 5_000,
              userBlockedDomains.count <= 5_000 else {
            throw ProtectionConfigurationError.excessiveRules
        }
        for domain in blockedDomains + allowedDomains + userBlockedDomains { _ = try ProtectionCanonicalization.domain(domain) }
        guard !blockedDomains.isEmpty else { throw ProtectionConfigurationError.missingDataset }
        if let manifestDigest {
            guard manifestDigest.count == 64, manifestDigest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                throw ProtectionConfigurationError.missingDataset
            }
        }
    }
    public var scopeIdentity: String { get throws {
        try validate()
        return "safari/v1:" + ContentDigest.sha256(try ProtectionCanonicalization.encode(self))
    } }
}

/// Safari processes this JSON internally. It does not expose visited pages to the extension.
public enum SafariRuleCompiler {
    private struct Rule: Encodable {
        struct Trigger: Encodable {
            let urlFilter: String
            let loadType: [String]
            enum CodingKeys: String, CodingKey { case urlFilter = "url-filter", loadType = "load-type" }
        }
        struct Action: Encodable { let type: String }
        let trigger: Trigger
        let action: Action
    }
    public static func compile(_ configuration: SafariRuleConfiguration) throws -> Data {
        try configuration.validate()
        let allowed = Set(try configuration.allowedDomains.map(ProtectionCanonicalization.domain))
        let blocked = Set(try configuration.blockedDomains.map(ProtectionCanonicalization.domain))
        let custom = Set(try configuration.userBlockedDomains.map(ProtectionCanonicalization.domain))
        let domains = blocked.filter { candidate in
            !allowed.contains { candidate == $0 || candidate.hasSuffix("." + $0) }
        }.sorted()
        var rules = domains.map { domain in
            Rule(trigger: .init(urlFilter: "^https?://([^/]+\\.)?" +
                                NSRegularExpression.escapedPattern(for: domain) + "[:/]",
                                loadType: ["third-party"]), action: .init(type: "block"))
        }
        let customDomains = custom.filter { candidate in
            !allowed.contains { candidate == $0 || candidate.hasSuffix("." + $0) }
        }.sorted()
        rules += customDomains.map { domain in
            Rule(trigger: .init(urlFilter: "^https?://" + NSRegularExpression.escapedPattern(for: domain) + "[:/]",
                                loadType: ["third-party"]), action: .init(type: "block"))
        }
        // A child allow entry must not whitelist the parent or its other children.
        let exceptions = allowed.filter { allowedDomain in
            domains.contains { allowedDomain.hasSuffix("." + $0) }
        }.sorted()
        rules += exceptions.map { domain in
            Rule(trigger: .init(urlFilter: "^https?://([^/]+\\.)?" +
                                NSRegularExpression.escapedPattern(for: domain) + "[:/]",
                                loadType: ["third-party"]), action: .init(type: "ignore-previous-rules"))
        }
        return try ProtectionCanonicalization.encode(rules)
    }
}

public struct URLFilterServiceConfiguration: Codable, Equatable, Sendable {
    public let pirServerURL: URL
    public let privacyPassIssuerURL: URL?
    public let controlProviderBundleIdentifier: String
    public let datasetDigest: String
    /// Identity of a server configuration registered with Apple's Identity & Trust service.
    /// This value is bound by the signed dataset manifest, not a local approval toggle.
    public let appleApprovedConfigurationIdentity: String
    public init(pirServerURL: URL, privacyPassIssuerURL: URL? = nil,
                controlProviderBundleIdentifier: String, datasetDigest: String,
                appleApprovedConfigurationIdentity: String) {
        self.pirServerURL = pirServerURL; self.privacyPassIssuerURL = privacyPassIssuerURL
        self.controlProviderBundleIdentifier = controlProviderBundleIdentifier
        self.datasetDigest = datasetDigest; self.appleApprovedConfigurationIdentity = appleApprovedConfigurationIdentity
    }
    public func validate() throws {
        try ProtectionCanonicalization.requireHTTPS(pirServerURL)
        if let privacyPassIssuerURL { try ProtectionCanonicalization.requireHTTPS(privacyPassIssuerURL) }
        try ProtectionCanonicalization.requireBundleIdentifier(controlProviderBundleIdentifier)
        guard datasetDigest.count == 64, datasetDigest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
              !appleApprovedConfigurationIdentity.isEmpty, appleApprovedConfigurationIdentity.utf8.count <= 200 else {
            throw ProtectionConfigurationError.unapprovedDeployment
        }
    }
    public var scopeIdentity: String { get throws {
        try validate()
        return "url-filter/v1:" + ContentDigest.sha256(try ProtectionCanonicalization.encode(self))
    } }
}
