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
        guard Double(expiresAtSeconds) > now.timeIntervalSince1970,
              let host, let domain = try? ProtectionCanonicalization.domain(host),
              (try? validate()) != nil else { return .allow }
        let matching = rules.filter { rule in
            (rule.appIdentifier == nil || rule.appIdentifier == sourceAppIdentifier) &&
            (domain == rule.domain || (rule.includeSubdomains && domain.hasSuffix("." + rule.domain)))
        }
        if matching.contains(where: { $0.action == .allow }) { return .allow }
        return matching.contains(where: { $0.action == .drop }) ? .drop : .allow
    }
}
