import Foundation

public enum DeclarativeRuleError: Error, Equatable, Sendable {
    case unsupportedSchema, incompatibleImplementation, invalidVersion, invalidRuleSet
    case invalidParameters, unexpectedFields, invalidJSON, oversizedDocument, missingResource, defaultMismatch
}

/// Only reviewed, compiled detectors can be selected by configuration data.
public enum DetectorRuleID: String, Codable, CaseIterable, Sendable {
    case reportedClassification = "AGG-APPLE-001"
    case crossApp = "AGG-CROSSAPP-002"
    case locationNetwork = "LOC-NET-003"
    case unexpectedSensor = "SENSOR-UNEXPECTED-004"
    case unknownHighFanout = "UNKNOWN-HIGHFANOUT-005"
    case reviewedHighImpact = "VENDOR-KNOWN-006"
    case coverageGap = "COVERAGE-GAP-007"
    case freshness = "FRESHNESS-008"
}

public enum DeclarativeRuleParameters: Equatable, Sendable {
    case none
    case crossApp(minimumDistinctApps: Int)
    case highFanout(minimumDistinctDestinations: Int, maximumReviewedCoverage: Double)
    case freshness(minimumAgeDays: Int)
}

/// Configuration cannot supply prose, scores, categories, actions, or trust claims.
public struct DeclarativeRule: Codable, Equatable, Sendable {
    public let id: DetectorRuleID
    public let enabled: Bool
    public let parameters: DeclarativeRuleParameters

    public init(id: DetectorRuleID, enabled: Bool = true, parameters: DeclarativeRuleParameters = .none) throws {
        switch (id, parameters) {
        case (.crossApp, .crossApp(let minimum)):
            guard (3...1_000).contains(minimum) else { throw DeclarativeRuleError.invalidParameters }
        case (.unknownHighFanout, .highFanout(let minimum, let coverage)):
            guard (10...1_000).contains(minimum), coverage.isFinite, (0.05...0.5).contains(coverage) else {
                throw DeclarativeRuleError.invalidParameters
            }
        case (.freshness, .freshness(let days)):
            guard (1...365).contains(days) else { throw DeclarativeRuleError.invalidParameters }
        case (.reportedClassification, .none), (.locationNetwork, .none), (.unexpectedSensor, .none),
             (.reviewedHighImpact, .none), (.coverageGap, .none): break
        default: throw DeclarativeRuleError.invalidParameters
        }
        self.id = id; self.enabled = enabled; self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey { case id, enabled, parameters }
    private enum ParameterKeys: String, CodingKey {
        case minimumDistinctApps, minimumDistinctDestinations, maximumReviewedCoverage, minimumAgeDays
    }

    public init(from decoder: any Decoder) throws {
        try RuleConfigurationJSON.closed(decoder, fields: ["id", "enabled", "parameters"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(DetectorRuleID.self, forKey: .id)
        let enabled = try values.decode(Bool.self, forKey: .enabled)
        let parameterDecoder = try values.superDecoder(forKey: .parameters)
        let fields: Set<String>
        switch id {
        case .crossApp: fields = ["minimumDistinctApps"]
        case .unknownHighFanout: fields = ["minimumDistinctDestinations", "maximumReviewedCoverage"]
        case .freshness: fields = ["minimumAgeDays"]
        default: fields = []
        }
        try RuleConfigurationJSON.closed(parameterDecoder, fields: fields)
        let parameters = try parameterDecoder.container(keyedBy: ParameterKeys.self)
        let selection: DeclarativeRuleParameters
        switch id {
        case .crossApp: selection = .crossApp(minimumDistinctApps: try parameters.decode(Int.self, forKey: .minimumDistinctApps))
        case .unknownHighFanout:
            selection = .highFanout(minimumDistinctDestinations: try parameters.decode(Int.self, forKey: .minimumDistinctDestinations),
                maximumReviewedCoverage: try parameters.decode(Double.self, forKey: .maximumReviewedCoverage))
        case .freshness: selection = .freshness(minimumAgeDays: try parameters.decode(Int.self, forKey: .minimumAgeDays))
        default: selection = .none
        }
        try self.init(id: id, enabled: enabled, parameters: selection)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(enabled, forKey: .enabled)
        var parameters = values.nestedContainer(keyedBy: ParameterKeys.self, forKey: .parameters)
        switch self.parameters {
        case .none: break
        case .crossApp(let minimum): try parameters.encode(minimum, forKey: .minimumDistinctApps)
        case .highFanout(let minimum, let coverage):
            try parameters.encode(minimum, forKey: .minimumDistinctDestinations)
            try parameters.encode(coverage, forKey: .maximumReviewedCoverage)
        case .freshness(let days): try parameters.encode(days, forKey: .minimumAgeDays)
        }
    }
}

/// Every configuration contains all eight known rules. Disabled means suppressed,
/// never proof that the imported activity, a permission, or an exposure disappeared.
public struct DeclarativeRuleConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let implementationVersion = "ruleset-2.0.0"
    public static let maximumDocumentBytes = 16 * 1_024
    public let schemaVersion: Int
    public let version: String
    public let implementationVersion: String
    public let rules: [DeclarativeRule]
    /// SHA-256 of normalized configuration JSON, distinct from raw signed payload hash.
    public let digest: String
    public var analysisVersion: String { "\(implementationVersion)/config-\(version)/\(digest)" }

    public init(schemaVersion: Int = Self.schemaVersion, version: String,
                implementationVersion: String = Self.implementationVersion, rules: [DeclarativeRule]) throws {
        guard schemaVersion == Self.schemaVersion else { throw DeclarativeRuleError.unsupportedSchema }
        guard implementationVersion == Self.implementationVersion else { throw DeclarativeRuleError.incompatibleImplementation }
        guard RuleConfigurationJSON.version(version) else { throw DeclarativeRuleError.invalidVersion }
        guard rules.count == DetectorRuleID.allCases.count,
              Set(rules.map(\.id)) == Set(DetectorRuleID.allCases) else { throw DeclarativeRuleError.invalidRuleSet }
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        let normalized = DetectorRuleID.allCases.compactMap { byID[$0] }
        self.schemaVersion = schemaVersion; self.version = version
        self.implementationVersion = implementationVersion; self.rules = normalized
        digest = ContentDigest.sha256(try RuleConfigurationJSON.encode(Payload(schemaVersion: schemaVersion,
            version: version, implementationVersion: implementationVersion, rules: normalized)))
    }

    public func rule(_ id: DetectorRuleID) -> DeclarativeRule { rules[DetectorRuleID.allCases.firstIndex(of: id)!] }
    public func isEnabled(_ id: DetectorRuleID) -> Bool { rule(id).enabled }
    public var minimumDistinctApps: Int {
        if case .crossApp(let minimum) = rule(.crossApp).parameters { return minimum }
        preconditionFailure("Validated cross-app parameters are absent.")
    }
    public var minimumDistinctDestinations: Int {
        if case .highFanout(let minimum, _) = rule(.unknownHighFanout).parameters { return minimum }
        preconditionFailure("Validated fanout parameters are absent.")
    }
    public var maximumReviewedCoverage: Double {
        if case .highFanout(_, let maximum) = rule(.unknownHighFanout).parameters { return maximum }
        preconditionFailure("Validated fanout parameters are absent.")
    }
    public var minimumAgeDays: Int {
        if case .freshness(let days) = rule(.freshness).parameters { return days }
        preconditionFailure("Validated freshness parameters are absent.")
    }

    func explaining(_ scores: PostureScores) -> PostureScores {
        let disabled = rules.filter { !$0.enabled }.map { $0.id.rawValue }
        var explanation = scores.explanation
        explanation["ruleConfiguration"] = "Reviewed configuration \(version), SHA-256 \(digest). Shared destinations require \(minimumDistinctApps) apps; fanout requires \(minimumDistinctDestinations) destinations and reviewed coverage below \(maximumReviewedCoverage); freshness requires more than \(minimumAgeDays) days. Disabled detectors: \(disabled.isEmpty ? "none" : disabled.joined(separator: ", ")). Suppression changes finding-derived signals, not recorded activity, knowledge coverage, or permissions."
        if !disabled.isEmpty {
            explanation["privacyPosture"] = "Overall summary withheld because one or more reviewed detectors are disabled. Suppressed findings cannot establish lower exposure or safety."
        }
        return .init(version: scores.version, sensorExposure: scores.sensorExposure, thirdPartyReach: scores.thirdPartyReach,
            aggregationSignals: scores.aggregationSignals, repetition: scores.repetition, controlGap: scores.controlGap,
            evidenceConfidence: scores.evidenceConfidence, classificationCoverage: scores.classificationCoverage,
            privacyPosture: disabled.isEmpty ? scores.privacyPosture : nil, explanation: explanation)
    }

    public func encoded() throws -> Data { try RuleConfigurationJSON.encode(self) }
    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumDocumentBytes else { throw DeclarativeRuleError.oversizedDocument }
        try RuleConfigurationJSON.validateShape(bytes)
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    private struct Payload: Encodable {
        let schemaVersion: Int
        let version: String
        let implementationVersion: String
        let rules: [DeclarativeRule]
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, version, implementationVersion, rules }
    public init(from decoder: any Decoder) throws {
        try RuleConfigurationJSON.closed(decoder, fields: ["schemaVersion", "version", "implementationVersion", "rules"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var entries = try values.nestedUnkeyedContainer(forKey: .rules)
        guard entries.count == DetectorRuleID.allCases.count else { throw DeclarativeRuleError.invalidRuleSet }
        var rules: [DeclarativeRule] = []
        while !entries.isAtEnd { rules.append(try entries.decode(DeclarativeRule.self)) }
        try self.init(schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            version: values.decode(String.self, forKey: .version),
            implementationVersion: values.decode(String.self, forKey: .implementationVersion), rules: rules)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(version, forKey: .version)
        try values.encode(implementationVersion, forKey: .implementationVersion); try values.encode(rules, forKey: .rules)
    }
}

public extension VersionedRuleSet {
    static let defaultConfiguration: DeclarativeRuleConfiguration = {
        do {
            return try DeclarativeRuleConfiguration(version: "1.0.0", rules: DetectorRuleID.allCases.map { id in
                let parameters: DeclarativeRuleParameters
                switch id {
                case .crossApp: parameters = .crossApp(minimumDistinctApps: 3)
                case .unknownHighFanout: parameters = .highFanout(minimumDistinctDestinations: 10, maximumReviewedCoverage: 0.4)
                case .freshness: parameters = .freshness(minimumAgeDays: 14)
                default: parameters = .none
                }
                return try DeclarativeRule(id: id, parameters: parameters)
            })
        } catch { preconditionFailure("Compiled declarative rule defaults are invalid.") }
    }()
}

public enum DeclarativeRuleResources {
    public static func loadBundled() throws -> DeclarativeRuleConfiguration {
        guard let url = Bundle.module.url(forResource: "default-rules", withExtension: "json") else {
            throw DeclarativeRuleError.missingResource
        }
        let bytes = try Data(contentsOf: url)
        let configuration = try DeclarativeRuleConfiguration.decode(bytes)
        guard configuration == VersionedRuleSet.defaultConfiguration else { throw DeclarativeRuleError.defaultMismatch }
        return configuration
    }
}

/// Shared by the signed envelope. Duplicate/escaped duplicate keys are rejected
/// before Foundation's keyed decoding can collapse them. Typed decoding checks syntax.
enum RuleConfigurationJSON {
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func closed(_ decoder: any Decoder, fields: Set<String>) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)) == fields else { throw DeclarativeRuleError.unexpectedFields }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func version(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 6 && ($0.count == 1 || $0.first != "0")
                && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    static func validateShape(_ data: Data, maximumDepth: Int = 4, maximumStringBytes: Int = 256,
                              maximumObjects: Int = 32, maximumKeys: Int = 16, maximumKeyBytes: Int = 256) throws {
        struct Scope { let object: Bool; var expectsKey: Bool; var keys: Set<String> = [] }
        let bytes = Array(data)
        guard bytes.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 else { throw DeclarativeRuleError.invalidJSON }
        var scopes: [Scope] = [], index = 0, objectCount = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91:
                let object = bytes[index] == 123
                if object { objectCount += 1 }
                scopes.append(.init(object: object, expectsKey: object))
                guard scopes.count <= maximumDepth, objectCount <= maximumObjects else { throw DeclarativeRuleError.invalidJSON }
            case 125, 93:
                guard let scope = scopes.popLast(), scope.object == (bytes[index] == 125) else { throw DeclarativeRuleError.invalidJSON }
            case 44: if scopes.last?.object == true { scopes[scopes.count - 1].expectsKey = true }
            case 58: if scopes.last?.object == true { scopes[scopes.count - 1].expectsKey = false }
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    guard index - start <= maximumStringBytes else { throw DeclarativeRuleError.invalidJSON }
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                guard index < bytes.count else { throw DeclarativeRuleError.invalidJSON }
                if scopes.last?.object == true, scopes.last?.expectsKey == true {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard key.utf8.count <= maximumKeyBytes, scopes[scopes.count - 1].keys.insert(key).inserted,
                          scopes[scopes.count - 1].keys.count <= maximumKeys else { throw DeclarativeRuleError.invalidJSON }
                }
            default: break
            }
            index += 1
        }
        guard scopes.isEmpty else { throw DeclarativeRuleError.invalidJSON }
    }
}
