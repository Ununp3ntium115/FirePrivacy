import Foundation
import ObservationCore
import KnowledgeBaseKit
import FindingEngine

/// Deterministic fixtures shared by the test targets.
///
/// Everything here is synthetic: reserved TLDs and `com.example.` bundle
/// identifiers only, so no test can accidentally assert something about a real
/// company.
public enum Fixtures {
    public static let referenceDate = Date(timeIntervalSince1970: 1_787_000_000) // 2026-08-17

    public static func bundleID(_ value: String) -> BundleIdentifier {
        BundleIdentifier(value) ?? BundleIdentifier("com.example.fallback") ?? .placeholder
    }

    public static func host(_ value: String) -> NormalizedHost {
        DomainNormalizer().normalize(value).host ?? NormalizedHost(value: value, kind: .domain)
    }

    public static func session(
        id: UUID = DeterministicUUID.make(namespace: .importSession, name: "fixture"),
        reportStart: Date? = referenceDate.addingTimeInterval(-7 * 86_400),
        reportEnd: Date? = referenceDate,
        isDemo: Bool = false
    ) -> ImportSession {
        ImportSession(
            id: id,
            sourceHash: FireHasher.hash("fixture"),
            sourceFilename: UntrustedText("fixture.ndjson"),
            importedAt: referenceDate,
            reportStart: reportStart,
            reportEnd: reportEnd,
            recordCount: 0,
            invalidCount: 0,
            unknownCount: 0,
            status: .complete,
            isDemoData: isDemo
        )
    }

    public static func network(
        session: ImportSession,
        bundle: String,
        host hostValue: String,
        hits: Int = 10,
        domainType: Int? = 1,
        owner: String? = nil,
        context: String? = nil,
        line: Int = 1
    ) -> NetworkObservation {
        let normalized = DomainNormalizer().normalize(hostValue)
        let bundleID = bundleID(bundle)
        return NetworkObservation(
            id: DeterministicUUID.make(namespace: .networkObservation, name: "\(bundle)|\(hostValue)|\(line)"),
            importSessionID: session.id,
            applicationID: DeterministicUUID.make(namespace: .application, name: bundle),
            bundleID: bundleID,
            host: normalized.host ?? host(hostValue),
            registrableDomain: normalized.registrableDomain,
            context: context.map { UntrustedText($0) },
            firstTimestamp: referenceDate.addingTimeInterval(-6 * 86_400),
            lastTimestamp: referenceDate,
            hits: hits,
            domainType: ReportedDomainType(rawValue: domainType, rawLabel: nil),
            initiatedType: UntrustedText("AppInitiated"),
            domainOwner: owner.map { UntrustedText($0) },
            sourceLineHash: FireHasher.hash("\(bundle)|\(hostValue)|\(line)"),
            sourceLineNumber: line,
            normalizationWarnings: normalized.warnings
        )
    }

    public static func sensor(
        session: ImportSession,
        bundle: String,
        sensor sensorValue: String,
        count: Int = 3,
        line: Int = 1
    ) -> SensorObservation {
        SensorObservation(
            id: DeterministicUUID.make(namespace: .sensorObservation, name: "\(bundle)|\(sensorValue)"),
            importSessionID: session.id,
            applicationID: DeterministicUUID.make(namespace: .application, name: bundle),
            bundleID: bundleID(bundle),
            sensorType: SensorType(reportValue: sensorValue),
            firstTimestamp: referenceDate.addingTimeInterval(-5 * 86_400),
            lastTimestamp: referenceDate,
            count: count,
            sourceLineHash: FireHasher.hash("\(bundle)|\(sensorValue)|\(line)"),
            sourceLineNumber: line
        )
    }

    public static func snapshot(
        network: [NetworkObservation],
        sensors: [SensorObservation] = [],
        session: ImportSession? = nil
    ) -> ObservationSnapshot {
        let importSession = session ?? Self.session()
        let bundleIDs = Set(network.compactMap(\.bundleID) + sensors.compactMap(\.bundleID))
        let applications = bundleIDs.sorted().map { bundleID in
            ObservedApplication(
                id: DeterministicUUID.make(namespace: .application, name: bundleID.rawValue),
                bundleID: bundleID
            )
        }
        return ObservationSnapshot(
            session: importSession,
            applications: applications,
            networkObservations: network,
            sensorObservations: sensors
        ).sorted()
    }

    /// A tiny knowledge base with one rule per category the tests need.
    public static let knowledgeBase: KnowledgeBasePayload = {
        let source = KnowledgeSource(
            id: "src.test",
            title: "Test fixture",
            url: nil,
            type: .internalReview,
            retrievedAt: referenceDate
        )
        func rule(_ pattern: String, _ categories: [DomainCategory], organization: String?) -> DomainClassification {
            DomainClassification(
                id: "kb.\(pattern)",
                pattern: pattern,
                patternKind: .domainSuffix,
                organization: organization,
                sdkFamily: organization,
                categories: categories,
                purposes: ["test"],
                confidence: 0.9,
                sourceIDs: [source.id],
                sourceType: .internalReview,
                firstSeen: referenceDate,
                lastReviewed: referenceDate,
                expiresAt: nil,
                reviewStatus: .reviewed
            )
        }
        return KnowledgeBasePayload(
            datasetVersion: "kb-test-1",
            sources: [source],
            classifications: [
                rule("tracker.example", [.advertising, .attribution], organization: "Tracker Demo"),
                rule("ads.example", [.advertising], organization: "Ads Demo"),
                rule("broker.example", [.dataBroker], organization: "Broker Demo"),
                rule("places.example", [.locationIntelligence], organization: "Places Demo"),
                rule("cdn.example", [.contentDelivery], organization: "CDN Demo"),
                rule("login.example", [.authentication], organization: "Login Demo"),
            ]
        )
    }()

    public static var matcher: DomainMatcher { DomainMatcher(payload: knowledgeBase) }

    public static let knowledgeBaseVersion = KnowledgeBaseVersion(
        datasetVersion: "kb-test-1",
        generatedAt: referenceDate,
        expiresAt: referenceDate.addingTimeInterval(90 * 86_400),
        origin: .bundled,
        recordCount: 6
    )
}

extension BundleIdentifier {
    /// Only used if a fixture literal is ever mistyped, so tests fail on the
    /// assertion rather than on a nil unwrap.
    static let placeholder: BundleIdentifier = {
        guard let value = BundleIdentifier("com.example.placeholder") else {
            preconditionFailure("literal is a valid bundle identifier")
        }
        return value
    }()
}
