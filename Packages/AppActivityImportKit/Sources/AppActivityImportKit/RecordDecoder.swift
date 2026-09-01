import Foundation
import ObservationCore

/// The record families the normalizer understands (IMP-005).
public enum AppActivityRecordKind: String, Sendable, Hashable {
    case networkActivity
    case access
}

/// One decoded line, before aggregation.
public struct DecodedRecord: Sendable, Hashable {
    public var kind: AppActivityRecordKind
    public var bundleID: BundleIdentifier?
    public var lineNumber: Int
    public var lineHash: FireDigest

    // Network fields
    public var host: NormalizedHost?
    public var registrableDomain: NormalizedHost?
    public var normalizationWarnings: NormalizationWarnings = []
    public var context: UntrustedText?
    public var hits: Int?
    public var domainType: ReportedDomainType = ReportedDomainType(rawValue: nil, rawLabel: nil)
    public var initiatedType: UntrustedText?
    public var domainOwner: UntrustedText?

    // Sensor fields
    public var sensorType: SensorType?
    /// `intervalBegin` records are the ones counted as accesses; `intervalEnd`
    /// only extends the window (see `AppActivityNormalizer`).
    public var accessKind: String?

    public var firstTimestamp: Date?
    public var lastTimestamp: Date?
}

/// Turns one JSON line into a `DecodedRecord`, tolerating unknown fields and
/// alternate spellings (IMP-004).
public struct AppActivityRecordDecoder: Sendable {
    /// Keys Apple has used, plus the spellings produced by common re-export
    /// tooling. Unknown keys are ignored after their type and size are checked.
    enum Keys {
        static let type = ["type", "recordType", "kind_type"]
        static let bundle = ["bundleID", "bundleId", "bundle_identifier", "identifier"]
        static let accessor = ["accessor", "subject"]
        static let accessorIdentifier = ["identifier", "bundleID", "bundleId"]
        static let domain = ["domain", "hostname", "host"]
        static let context = ["context", "websiteContext", "pageContext"]
        static let hits = ["hits", "count", "hitCount"]
        static let domainType = ["domainType", "domain_type"]
        static let domainClassification = ["domainClassification", "domainCategory", "classification"]
        static let initiatedType = ["initiatedType", "initiated_type"]
        static let domainOwner = ["domainOwner", "owner", "domain_owner"]
        static let firstTimestamp = ["firstTimeStamp", "firstTimestamp", "first_time_stamp"]
        static let timestamp = ["timeStamp", "timestamp", "lastTimeStamp", "lastTimestamp", "time_stamp"]
        static let category = ["category", "sensor", "accessCategory"]
        static let sensorIdentifier = ["identifier", "service", "tccService"]
        static let accessKind = ["kind", "accessKind", "eventKind"]
    }

    public enum DecodeFailure: Error, Equatable, Sendable {
        case notAnObject
        case missingDiscriminator
        case unknownRecordType
        case unusableRecord
    }

    public let normalizer: DomainNormalizer
    public let stringLimit: Int
    public let now: Date

    public init(normalizer: DomainNormalizer = DomainNormalizer(), stringLimit: Int = 512, now: Date = Date()) {
        self.normalizer = normalizer
        self.stringLimit = stringLimit
        self.now = now
    }

    public func decode(
        _ value: JSONValue,
        lineNumber: Int,
        lineHash: FireDigest,
        warnings: inout [ImportWarning]
    ) throws -> DecodedRecord {
        guard let object = value.objectValue else { throw DecodeFailure.notAnObject }
        guard let rawType = value.first(of: Keys.type)?.stringValue else {
            // Without a discriminator the record cannot be interpreted safely:
            // guessing from field shape would silently mislabel evidence.
            throw object.isEmpty ? DecodeFailure.notAnObject : DecodeFailure.missingDiscriminator
        }

        let normalizedType = rawType.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalizedType {
        case "networkactivity", "network":
            return try decodeNetwork(value, lineNumber: lineNumber, lineHash: lineHash, warnings: &warnings)
        case "access", "dataaccess", "sensoraccess":
            return try decodeAccess(value, lineNumber: lineNumber, lineHash: lineHash, warnings: &warnings)
        default:
            throw DecodeFailure.unknownRecordType
        }
    }

    private func decodeNetwork(
        _ value: JSONValue,
        lineNumber: Int,
        lineHash: FireDigest,
        warnings: inout [ImportWarning]
    ) throws -> DecodedRecord {
        var record = DecodedRecord(kind: .networkActivity, bundleID: nil, lineNumber: lineNumber, lineHash: lineHash)

        if let rawBundle = value.first(of: Keys.bundle)?.stringValue {
            record.bundleID = BundleIdentifier(rawBundle)
            if record.bundleID == nil {
                warnings.append(ImportWarning(code: .invalidBundleIdentifier, lineNumber: lineNumber))
            }
        }

        guard let rawDomain = value.first(of: Keys.domain)?.stringValue else {
            throw DecodeFailure.unusableRecord
        }
        let normalized = normalizer.normalize(rawDomain)
        guard let host = normalized.host else {
            warnings.append(ImportWarning(
                code: .invalidDomain,
                lineNumber: lineNumber,
                detail: normalized.rejectionReason?.rawValue
            ))
            throw DecodeFailure.unusableRecord
        }
        record.host = host
        record.registrableDomain = normalized.registrableDomain
        record.normalizationWarnings = normalized.warnings

        record.context = UntrustedText(optional: value.first(of: Keys.context)?.stringValue, limit: stringLimit)
        record.initiatedType = UntrustedText(optional: value.first(of: Keys.initiatedType)?.stringValue, limit: 64)
        record.domainOwner = UntrustedText(optional: value.first(of: Keys.domainOwner)?.stringValue, limit: 128)
        record.domainType = ReportedDomainType(
            rawValue: value.first(of: Keys.domainType)?.intValue,
            rawLabel: UntrustedText(optional: value.first(of: Keys.domainClassification)?.stringValue, limit: 64)
        )

        if let rawHits = value.first(of: Keys.hits) {
            if let hits = rawHits.intValue, hits >= 0 {
                record.hits = hits
            } else {
                warnings.append(ImportWarning(code: .invalidHitCount, lineNumber: lineNumber))
            }
        }

        record.firstTimestamp = timestamp(value.first(of: Keys.firstTimestamp), lineNumber: lineNumber, warnings: &warnings)
        record.lastTimestamp = timestamp(value.first(of: Keys.timestamp), lineNumber: lineNumber, warnings: &warnings)
        if record.firstTimestamp == nil { record.firstTimestamp = record.lastTimestamp }
        if record.lastTimestamp == nil { record.lastTimestamp = record.firstTimestamp }

        return record
    }

    private func decodeAccess(
        _ value: JSONValue,
        lineNumber: Int,
        lineHash: FireDigest,
        warnings: inout [ImportWarning]
    ) throws -> DecodedRecord {
        var record = DecodedRecord(kind: .access, bundleID: nil, lineNumber: lineNumber, lineHash: lineHash)

        let accessor = value.first(of: Keys.accessor)
        let rawBundle = accessor?.first(of: Keys.accessorIdentifier)?.stringValue
            ?? value.first(of: Keys.bundle)?.stringValue
        if let rawBundle {
            record.bundleID = BundleIdentifier(rawBundle)
            if record.bundleID == nil {
                warnings.append(ImportWarning(code: .invalidBundleIdentifier, lineNumber: lineNumber))
            }
        }

        // Apple reports the accessed resource in `category`, and older exports
        // in the TCC service `identifier`. Prefer the explicit category.
        let rawCategory = value.first(of: Keys.category)?.stringValue
            ?? value.first(of: Keys.sensorIdentifier)?.stringValue
        guard let rawCategory, !rawCategory.isEmpty else { throw DecodeFailure.unusableRecord }
        record.sensorType = SensorType(reportValue: rawCategory)
        record.accessKind = value.first(of: Keys.accessKind)?.stringValue?.lowercased()

        let stamp = timestamp(value.first(of: Keys.timestamp), lineNumber: lineNumber, warnings: &warnings)
        record.firstTimestamp = stamp
        record.lastTimestamp = stamp
        return record
    }

    private func timestamp(
        _ value: JSONValue?,
        lineNumber: Int,
        warnings: inout [ImportWarning]
    ) -> Date? {
        guard let value else { return nil }
        let raw: String? = switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        default: nil
        }
        guard let raw else { return nil }
        guard let date = TimestampParser.parse(raw, now: now) else {
            warnings.append(ImportWarning(code: .invalidTimestamp, lineNumber: lineNumber))
            return nil
        }
        return date
    }
}
