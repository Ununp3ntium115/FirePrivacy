import Foundation

public enum ManagedDeploymentMode: String, Codable, Sendable {
    case supervisedDevice, mdmPerApp
}
public struct ManagedPolicy: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case allow, drop }
    public struct Rule: Codable, Equatable, Sendable {
        public let appIdentifier: String?
        public let domain: String
        public let includeSubdomains: Bool
        public let action: Action
        public init(appIdentifier: String? = nil, domain: String, includeSubdomains: Bool = true, action: Action) {
            self.appIdentifier = appIdentifier; self.domain = domain
            self.includeSubdomains = includeSubdomains; self.action = action
        }
    }
    public let version: UInt64
    public let deploymentMode: ManagedDeploymentMode
    public let rules: [Rule]
    public let expiresAtSeconds: Int64
    public init(version: UInt64, deploymentMode: ManagedDeploymentMode, rules: [Rule], expiresAtSeconds: Int64) {
        self.version = version; self.deploymentMode = deploymentMode; self.rules = rules
        self.expiresAtSeconds = expiresAtSeconds
    }
    public func validate() throws {
        guard version > 0, rules.count <= 50_000, expiresAtSeconds > 0 else {
            throw ProtectionConfigurationError.excessiveRules
        }
        for rule in rules {
            guard try ProtectionCanonicalization.domain(rule.domain) == rule.domain else {
                throw ProtectionConfigurationError.invalidDomain
            }
            if let identifier = rule.appIdentifier { try ProtectionCanonicalization.requireBundleIdentifier(identifier) }
        }
    }
    public var scopeIdentity: String { get throws {
        try validate()
        return "managed/v1:" + ContentDigest.sha256(try ProtectionCanonicalization.encode(self))
    } }
    /// Explicit allows take priority. Unknown attribution cannot satisfy an app-scoped rule.
    /// Expired/unavailable policy permits the flow, while activation is refused by the app.
    public func decision(host: String?, sourceAppIdentifier: String?, now: Date = Date()) -> Action {
        (try? ManagedPolicyIndex(policy: self).decision(host: host, sourceAppIdentifier: sourceAppIdentifier, now: now)) ?? .allow
    }
}

/// Build once at provider start or rules-changed. A lookup visits the host's
/// suffixes rather than revalidating or scanning every rule on every connection.
public struct ManagedPolicyIndex: Sendable {
    private let rulesByDomain: [String: [ManagedPolicy.Rule]]
    private let expiresAt: Date
    public init(policy: ManagedPolicy, authorizationExpiresAt: Date? = nil) throws {
        try policy.validate()
        rulesByDomain = Dictionary(grouping: policy.rules, by: \.domain)
        let policyExpiry = Date(timeIntervalSince1970: Double(policy.expiresAtSeconds))
        expiresAt = authorizationExpiresAt.map { min($0, policyExpiry) } ?? policyExpiry
    }
    public func decision(host: String?, sourceAppIdentifier: String?, now: Date = Date()) -> ManagedPolicy.Action {
        guard expiresAt > now, let host, let domain = try? ProtectionCanonicalization.domain(host) else { return .allow }
        let labels = domain.split(separator: ".")
        var matchedDrop = false
        for offset in labels.indices {
            let candidate = labels[offset...].joined(separator: ".")
            for rule in rulesByDomain[candidate] ?? [] {
                guard (offset == 0 || rule.includeSubdomains),
                      rule.appIdentifier == nil || rule.appIdentifier == sourceAppIdentifier else { continue }
                if rule.action == .allow { return .allow }
                matchedDrop = true
            }
        }
        return matchedDrop ? .drop : .allow
    }
}
