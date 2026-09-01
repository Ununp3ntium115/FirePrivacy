import Foundation
import ObservationCore

/// What a domain is used for (KB-004).
///
/// Categories are deliberately non-exclusive: one endpoint can be an SDK's
/// analytics *and* attribution path, and forcing a single label would throw away
/// the distinction that matters to the user.
public enum DomainCategory: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case advertising
    case analytics
    case attribution
    case authentication
    case contentDelivery
    case content
    case crashReporting
    case dataBroker
    case fraudPrevention
    case locationIntelligence
    case messaging
    case payments
    case personalization
    case pushNotifications
    case social
    case telemetry
    case unknown

    /// Human-readable name. Localized in the app; this is the fallback.
    public var displayName: String {
        switch self {
        case .advertising: "Advertising"
        case .analytics: "Analytics"
        case .attribution: "Attribution"
        case .authentication: "Authentication"
        case .contentDelivery: "CDN / Infrastructure"
        case .content: "Content"
        case .crashReporting: "Crash Reporting"
        case .dataBroker: "Data Broker"
        case .fraudPrevention: "Fraud Prevention"
        case .locationIntelligence: "Location Intelligence"
        case .messaging: "Messaging"
        case .payments: "Payments"
        case .personalization: "Personalization"
        case .pushNotifications: "Push Notifications"
        case .social: "Social"
        case .telemetry: "Telemetry"
        case .unknown: "Unknown"
        }
    }

    /// Categories whose presence across unrelated apps is *expected* and
    /// therefore must not by itself raise an aggregation signal (DET-004).
    public var isCommonInfrastructure: Bool {
        switch self {
        case .contentDelivery, .authentication, .pushNotifications, .payments, .fraudPrevention: true
        default: false
        }
    }

    public static func < (lhs: DomainCategory, rhs: DomainCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How a domain rule is matched.
public enum DomainPatternKind: String, Codable, Sendable, Hashable {
    /// Matches exactly this host.
    case exactHost
    /// Matches this host and any subdomain of it. Never matches a host that
    /// merely ends with the same characters (`badexample.com` vs `example.com`).
    case domainSuffix
}

/// Where a classification came from (KB-003, KB-005).
public enum ClassificationSourceType: String, Codable, Sendable, Hashable {
    /// The vendor's own documentation names the endpoint.
    case vendorDocumentation
    /// A published, citable dataset or research paper.
    case publishedResearch
    /// Registration or corporate records.
    case registryRecord
    /// Fire Privacy review of observed behavior, with notes.
    case internalReview
    /// Pattern-based guess with no per-domain citation. Always labeled
    /// "heuristic only" in the UI.
    case heuristic
}

public enum ClassificationReviewStatus: String, Codable, Sendable, Hashable {
    case reviewed
    case provisional
    case disputed
    case retired
}

/// A citable source backing one or more classifications (KB-005).
public struct KnowledgeSource: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let url: String?
    public let type: ClassificationSourceType
    public let retrievedAt: Date?

    public init(id: String, title: String, url: String?, type: ClassificationSourceType, retrievedAt: Date?) {
        self.id = id
        self.title = title
        self.url = url
        self.type = type
        self.retrievedAt = retrievedAt
    }
}

/// One domain rule (KB-003).
public struct DomainClassification: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let pattern: String
    public let patternKind: DomainPatternKind
    public let organization: String?
    public let sdkFamily: String?
    public let categories: [DomainCategory]
    public let purposes: [String]
    public let confidence: Double
    public let sourceIDs: [String]
    public let sourceType: ClassificationSourceType
    public let firstSeen: Date?
    public let lastReviewed: Date
    public let expiresAt: Date?
    public let reviewStatus: ClassificationReviewStatus
    public let geographicNotes: String?
    public let falsePositiveNotes: String?
    public let ruleAuthor: String?
    public let changeReason: String?

    public init(
        id: String,
        pattern: String,
        patternKind: DomainPatternKind,
        organization: String?,
        sdkFamily: String?,
        categories: [DomainCategory],
        purposes: [String],
        confidence: Double,
        sourceIDs: [String],
        sourceType: ClassificationSourceType,
        firstSeen: Date?,
        lastReviewed: Date,
        expiresAt: Date?,
        reviewStatus: ClassificationReviewStatus,
        geographicNotes: String? = nil,
        falsePositiveNotes: String? = nil,
        ruleAuthor: String? = nil,
        changeReason: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.patternKind = patternKind
        self.organization = organization
        self.sdkFamily = sdkFamily
        self.categories = categories
        self.purposes = purposes
        self.confidence = confidence
        self.sourceIDs = sourceIDs
        self.sourceType = sourceType
        self.firstSeen = firstSeen
        self.lastReviewed = lastReviewed
        self.expiresAt = expiresAt
        self.reviewStatus = reviewStatus
        self.geographicNotes = geographicNotes
        self.falsePositiveNotes = falsePositiveNotes
        self.ruleAuthor = ruleAuthor
        self.changeReason = changeReason
    }

    /// True when the classification carries no citable source and must be shown
    /// as "heuristic only" (KB-005).
    public var isHeuristicOnly: Bool { sourceType == .heuristic || sourceIDs.isEmpty }

    /// Longer patterns are more specific and win when several rules match.
    var specificity: Int { pattern.count + (patternKind == .exactHost ? 1000 : 0) }
}

/// Signed metadata describing a knowledge-base release (KB-001).
public struct KnowledgeBaseManifest: Codable, Sendable, Hashable {
    public let schemaVersion: String
    public let datasetVersion: String
    public let generatedAt: Date
    public let expiresAt: Date
    public let minimumAppVersion: String
    public let recordCount: Int
    /// SHA-256 of the payload the manifest describes.
    public let payloadDigest: FireDigest
    public let signingKeyID: String
    /// Ed25519 signature over the canonical manifest bytes, base64 encoded.
    public let signature: String

    public init(
        schemaVersion: String,
        datasetVersion: String,
        generatedAt: Date,
        expiresAt: Date,
        minimumAppVersion: String,
        recordCount: Int,
        payloadDigest: FireDigest,
        signingKeyID: String,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.datasetVersion = datasetVersion
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.minimumAppVersion = minimumAppVersion
        self.recordCount = recordCount
        self.payloadDigest = payloadDigest
        self.signingKeyID = signingKeyID
        self.signature = signature
    }

    /// The bytes that are signed: every field except the signature itself, in a
    /// fixed order. Canonicalization is explicit rather than JSON-encoder
    /// dependent so a signature stays valid across encoder versions.
    public var signedRepresentation: [UInt8] {
        let fields = [
            schemaVersion,
            datasetVersion,
            String(Int(generatedAt.timeIntervalSince1970)),
            String(Int(expiresAt.timeIntervalSince1970)),
            minimumAppVersion,
            String(recordCount),
            payloadDigest.hexString,
            signingKeyID,
        ]
        return Array(fields.joined(separator: "\u{1F}").utf8)
    }
}

/// The payload a manifest describes.
public struct KnowledgeBasePayload: Codable, Sendable, Hashable {
    public let datasetVersion: String
    public let sources: [KnowledgeSource]
    public let classifications: [DomainClassification]

    public init(datasetVersion: String, sources: [KnowledgeSource], classifications: [DomainClassification]) {
        self.datasetVersion = datasetVersion
        self.sources = sources
        self.classifications = classifications
    }
}

/// Where an installed dataset came from. Bundled data is trusted because it is
/// inside the app's own code signature; downloaded data must verify (KB-002).
public enum KnowledgeBaseOrigin: String, Codable, Sendable, Hashable {
    case bundled
    case downloaded
}

/// An installed, ready-to-query knowledge base.
public struct KnowledgeBaseSnapshot: Sendable {
    public let manifest: KnowledgeBaseManifest?
    public let payload: KnowledgeBasePayload
    public let origin: KnowledgeBaseOrigin
    public let installedAt: Date

    public init(manifest: KnowledgeBaseManifest?, payload: KnowledgeBasePayload, origin: KnowledgeBaseOrigin, installedAt: Date) {
        self.manifest = manifest
        self.payload = payload
        self.origin = origin
        self.installedAt = installedAt
    }

    public var version: KnowledgeBaseVersion {
        KnowledgeBaseVersion(
            datasetVersion: payload.datasetVersion,
            generatedAt: manifest?.generatedAt,
            expiresAt: manifest?.expiresAt,
            origin: origin,
            recordCount: payload.classifications.count
        )
    }

    /// Expired data still answers queries — the analysis stays viewable — but
    /// every finding built from it is marked stale (KB-006).
    ///
    /// The bundled dataset has no manifest and therefore no expiry: it is
    /// refreshed by shipping a new app version, so treating it as expired would
    /// mark every finding stale on a device that is simply offline.
    public func isExpired(now: Date) -> Bool {
        guard let expiresAt = manifest?.expiresAt else { return false }
        return now > expiresAt
    }
}

public struct KnowledgeBaseVersion: Codable, Sendable, Hashable {
    public let datasetVersion: String
    public let generatedAt: Date?
    public let expiresAt: Date?
    public let origin: KnowledgeBaseOrigin
    public let recordCount: Int

    public init(datasetVersion: String, generatedAt: Date?, expiresAt: Date?, origin: KnowledgeBaseOrigin, recordCount: Int) {
        self.datasetVersion = datasetVersion
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.origin = origin
        self.recordCount = recordCount
    }
}
