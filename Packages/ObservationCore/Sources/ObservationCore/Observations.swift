import Foundation

/// One user-initiated import of an App Privacy Report file (§12.1).
public struct ImportSession: Hashable, Sendable, Codable, Identifiable {
    public enum Status: String, Hashable, Sendable, Codable {
        case complete
        case partial
        case failed
    }

    public enum RawCopyState: String, Hashable, Sendable, Codable {
        case none
        case encrypted
    }

    public let id: UUID
    public let sourceHash: FireDigest
    public let sourceFilename: UntrustedText?
    public let importedAt: Date
    public let reportStart: Date?
    public let reportEnd: Date?
    public let parserVersion: String
    public let normalizationVersion: String
    public let recordCount: Int
    public let invalidCount: Int
    public let unknownCount: Int
    public let rawCopyState: RawCopyState
    public let status: Status
    public let warningCodes: [String]
    /// User-visible label when several sessions are kept side by side (IMP-006).
    public let label: UntrustedText?
    /// True for the bundled synthetic dataset, which the UI watermarks (IMP-011).
    public let isDemoData: Bool

    public init(
        id: UUID,
        sourceHash: FireDigest,
        sourceFilename: UntrustedText?,
        importedAt: Date,
        reportStart: Date?,
        reportEnd: Date?,
        parserVersion: String = ComponentVersion.parser,
        normalizationVersion: String = ComponentVersion.normalization,
        recordCount: Int,
        invalidCount: Int,
        unknownCount: Int,
        rawCopyState: RawCopyState = .none,
        status: Status,
        warningCodes: [String] = [],
        label: UntrustedText? = nil,
        isDemoData: Bool = false
    ) {
        self.id = id
        self.sourceHash = sourceHash
        self.sourceFilename = sourceFilename
        self.importedAt = importedAt
        self.reportStart = reportStart
        self.reportEnd = reportEnd
        self.parserVersion = parserVersion
        self.normalizationVersion = normalizationVersion
        self.recordCount = recordCount
        self.invalidCount = invalidCount
        self.unknownCount = unknownCount
        self.rawCopyState = rawCopyState
        self.status = status
        self.warningCodes = warningCodes
        self.label = label
        self.isDemoData = isDemoData
    }

    /// The window the report covers, when it can be inferred from the records.
    /// `nil` means "unknown", which the dashboard states rather than hides
    /// (DASH-002).
    public var coveredInterval: DateInterval? {
        guard let reportStart, let reportEnd, reportEnd >= reportStart else { return nil }
        return DateInterval(start: reportStart, end: reportEnd)
    }
}

/// An application observed in an imported report (§12.1).
public struct ObservedApplication: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let bundleID: BundleIdentifier
    /// Only set from a verified mapping; the bundle identifier stays visible
    /// either way (DASH-004).
    public let displayName: UntrustedText?
    public let publisherID: String?
    public let publisherName: UntrustedText?
    public let firstObserved: Date?
    public let lastObserved: Date?
    /// How much the identification of this app is trusted, 0–1.
    public let sourceConfidence: Double

    public init(
        id: UUID,
        bundleID: BundleIdentifier,
        displayName: UntrustedText? = nil,
        publisherID: String? = nil,
        publisherName: UntrustedText? = nil,
        firstObserved: Date? = nil,
        lastObserved: Date? = nil,
        sourceConfidence: Double = 0.98
    ) {
        self.id = id
        self.bundleID = bundleID
        self.displayName = displayName
        self.publisherID = publisherID
        self.publisherName = publisherName
        self.firstObserved = firstObserved
        self.lastObserved = lastObserved
        self.sourceConfidence = sourceConfidence
    }

    /// What the UI shows as the app's name. Never invents a name.
    public var preferredLabel: String { displayName?.value ?? bundleID.rawValue }
}

/// Apple's own classification of a contacted domain, preserved as reported.
///
/// The numeric value is kept verbatim (IMP-005) because Apple may add values;
/// the interpretation is separate and versioned.
public struct ReportedDomainType: Hashable, Sendable, Codable {
    public let rawValue: Int?
    public let rawLabel: UntrustedText?

    public init(rawValue: Int?, rawLabel: UntrustedText?) {
        self.rawValue = rawValue
        self.rawLabel = rawLabel
    }

    /// True when the export marks the domain as one that may collect information
    /// about the user across apps and websites. Used by rule AGG-APPLE-001.
    ///
    /// Apple's export has used both a numeric `domainType` and a textual label.
    /// Only an explicit signal counts; absence is never treated as "safe".
    public var indicatesCrossAppCollection: Bool {
        if let label = rawLabel?.value.lowercased(),
           label.contains("tracker") || label.contains("cross-site") || label.contains("cross site")
            || label.contains("cross-app") || label.contains("cross app") {
            return true
        }
        // Apple has used 2 for "may be collecting data about you across apps and
        // websites" in exported reports. The mapping is data, not a claim about
        // any app's conduct, and is re-verified against each OS seed.
        return rawValue == 2
    }

    public var isKnown: Bool { rawValue != nil || rawLabel != nil }
}

/// A contact between an app and a network domain, as recorded by Apple (§12.1).
public struct NetworkObservation: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let importSessionID: UUID
    public let applicationID: UUID?
    public let bundleID: BundleIdentifier?
    public let host: NormalizedHost
    public let registrableDomain: NormalizedHost?
    /// Website context, when the export includes one. Encrypted at rest.
    public let context: UntrustedText?
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    /// Contact count. Never described as a data volume (DET-008).
    public let hits: Int?
    public let domainType: ReportedDomainType
    public let initiatedType: UntrustedText?
    public let domainOwner: UntrustedText?
    public let sourceLineHash: FireDigest
    public let sourceLineNumber: Int
    public let normalizationWarnings: NormalizationWarnings
    /// How many report lines were folded into this observation. Apple emits one
    /// line per contact window, so a single app/domain pair usually spans
    /// several lines; the count is kept so the evidence view can say how many.
    public let mergedRecordCount: Int

    public init(
        id: UUID,
        importSessionID: UUID,
        applicationID: UUID?,
        bundleID: BundleIdentifier?,
        host: NormalizedHost,
        registrableDomain: NormalizedHost?,
        context: UntrustedText? = nil,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        hits: Int?,
        domainType: ReportedDomainType,
        initiatedType: UntrustedText? = nil,
        domainOwner: UntrustedText? = nil,
        sourceLineHash: FireDigest,
        sourceLineNumber: Int,
        normalizationWarnings: NormalizationWarnings = [],
        mergedRecordCount: Int = 1
    ) {
        self.id = id
        self.importSessionID = importSessionID
        self.applicationID = applicationID
        self.bundleID = bundleID
        self.host = host
        self.registrableDomain = registrableDomain
        self.context = context
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.hits = hits
        self.domainType = domainType
        self.initiatedType = initiatedType
        self.domainOwner = domainOwner
        self.sourceLineHash = sourceLineHash
        self.sourceLineNumber = sourceLineNumber
        self.normalizationWarnings = normalizationWarnings
        self.mergedRecordCount = mergedRecordCount
    }

    /// Grouping key for owner-level analysis: the registrable domain when known,
    /// otherwise the host itself.
    public var ownerKey: NormalizedHost { registrableDomain ?? host }

    /// Evidence identifier referenced by findings and by advisory output.
    public var evidenceID: String { "net:\(sourceLineHash.shortHexString)" }
}

/// An access to a privacy-sensitive resource, as recorded by Apple (§12.1).
public struct SensorObservation: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let importSessionID: UUID
    public let applicationID: UUID?
    public let bundleID: BundleIdentifier?
    public let sensorType: SensorType
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let count: Int?
    public let sourceLineHash: FireDigest
    public let sourceLineNumber: Int
    public let mergedRecordCount: Int

    public init(
        id: UUID,
        importSessionID: UUID,
        applicationID: UUID?,
        bundleID: BundleIdentifier?,
        sensorType: SensorType,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        count: Int?,
        sourceLineHash: FireDigest,
        sourceLineNumber: Int,
        mergedRecordCount: Int = 1
    ) {
        self.id = id
        self.importSessionID = importSessionID
        self.applicationID = applicationID
        self.bundleID = bundleID
        self.sensorType = sensorType
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.count = count
        self.sourceLineHash = sourceLineHash
        self.sourceLineNumber = sourceLineNumber
        self.mergedRecordCount = mergedRecordCount
    }

    public var evidenceID: String { "sensor:\(sourceLineHash.shortHexString)" }
}

/// Everything one import produced, in the form the rules engine consumes.
public struct ObservationSnapshot: Hashable, Sendable, Codable {
    public let session: ImportSession
    public let applications: [ObservedApplication]
    public let networkObservations: [NetworkObservation]
    public let sensorObservations: [SensorObservation]

    public init(
        session: ImportSession,
        applications: [ObservedApplication],
        networkObservations: [NetworkObservation],
        sensorObservations: [SensorObservation]
    ) {
        self.session = session
        self.applications = applications
        self.networkObservations = networkObservations
        self.sensorObservations = sensorObservations
    }

    public var isEmpty: Bool { networkObservations.isEmpty && sensorObservations.isEmpty }

    public func application(for id: UUID?) -> ObservedApplication? {
        guard let id else { return nil }
        return applications.first { $0.id == id }
    }

    public func application(bundleID: BundleIdentifier) -> ObservedApplication? {
        applications.first { $0.bundleID == bundleID }
    }

    /// Deterministic ordering used everywhere results are produced, so two runs
    /// over the same file emit byte-identical output (DET-012).
    public func sorted() -> ObservationSnapshot {
        ObservationSnapshot(
            session: session,
            applications: applications.sorted { $0.bundleID < $1.bundleID },
            networkObservations: networkObservations.sorted {
                if $0.bundleID?.rawValue != $1.bundleID?.rawValue {
                    return ($0.bundleID?.rawValue ?? "") < ($1.bundleID?.rawValue ?? "")
                }
                if $0.host != $1.host { return $0.host < $1.host }
                return $0.sourceLineNumber < $1.sourceLineNumber
            },
            sensorObservations: sensorObservations.sorted {
                if $0.bundleID?.rawValue != $1.bundleID?.rawValue {
                    return ($0.bundleID?.rawValue ?? "") < ($1.bundleID?.rawValue ?? "")
                }
                if $0.sensorType.identifier != $1.sensorType.identifier {
                    return $0.sensorType.identifier < $1.sensorType.identifier
                }
                return $0.sourceLineNumber < $1.sourceLineNumber
            }
        )
    }
}
