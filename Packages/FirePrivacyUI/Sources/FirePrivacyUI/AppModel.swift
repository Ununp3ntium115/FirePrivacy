import Foundation
import ObservationCore
import AppActivityImportKit
import KnowledgeBaseKit
import PrivacyProfileKit
import FindingEngine
import AdvisorKit
import ProtectionKit
import ConsentKit
import ObservationStore
import ReportKit
import TrustCenterKit
#if canImport(Observation)
import Observation
#endif

/// The single place the app's state lives.
///
/// Views read from here and call methods on it; no view performs analysis,
/// storage or protection work itself (§18.7).
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case needsOnboarding
        case idle
        case importing(ImportProgress)
        case analyzing
        case failed(String)
    }

    // MARK: Published state

    public private(set) var phase: Phase = .needsOnboarding
    public private(set) var sessions: [StoredSession] = []
    public private(set) var currentResult: FindingEvaluationResult?
    public private(set) var lastImport: ImportResult?
    public private(set) var protection = ProtectionState()
    public private(set) var inventory: TrustCenterInventory?
    public private(set) var comparison: ReportComparison?
    public var profile: PrivacyProfile = .balanced
    public var advisorMode: AdvisorMode = .deterministic
    public private(set) var advisorAvailability: AdvisorAvailability = .available
    public private(set) var explanations: [String: AdvisoryResolution] = [:]

    // MARK: Dependencies

    private let importer: AppActivityImporter
    private let knowledgeBase: KnowledgeBaseService
    private let engine: DeterministicFindingEngine
    private let store: EncryptedObservationStore
    private let consent: ConsentStore
    private let advisor: AdvisorCoordinator
    private let urlFilter: URLFilterController
    private let clock: @Sendable () -> Date
    public let appVersion: String
    public let osVersion: String
    public let osMajorVersion: Int

    public init(
        importer: AppActivityImporter = AppActivityImporter(),
        knowledgeBase: KnowledgeBaseService = KnowledgeBaseService(),
        engine: DeterministicFindingEngine = DeterministicFindingEngine(),
        store: EncryptedObservationStore,
        consent: ConsentStore,
        advisor: AdvisorCoordinator,
        urlFilter: URLFilterController,
        appVersion: String,
        osVersion: String,
        osMajorVersion: Int,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.importer = importer
        self.knowledgeBase = knowledgeBase
        self.engine = engine
        self.store = store
        self.consent = consent
        self.advisor = advisor
        self.urlFilter = urlFilter
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.osMajorVersion = osMajorVersion
        self.clock = clock
    }

    // MARK: Lifecycle

    public func start() async {
        sessions = await store.loadAll()
        phase = sessions.isEmpty ? .needsOnboarding : .idle
        await refreshProtectionState()
        if let latest = sessions.last {
            await reevaluate(session: latest)
        }
        await refreshInventory()
    }

    // MARK: Import

    public func importDemoReport() async {
        await runImport { [importer, clock] in
            try await DemoReport.load(using: importer, now: clock())
        }
    }

    public func importReport(at url: URL) async {
        let known = await store.knownSourceHashes()
        await runImport { [importer, clock] in
            let options = ImportOptions(knownSourceHashes: known, now: clock())
            return try await importer.importReport(from: url, options: options) { _ in }
        }
    }

    private func runImport(_ work: @escaping @Sendable () async throws -> ImportResult) async {
        phase = .importing(ImportProgress(stage: .readingFile, bytesRead: 0, totalBytes: 0, recordsAccepted: 0))
        do {
            let result = try await work()
            lastImport = result
            phase = .analyzing
            try await analyze(result.snapshot)
            phase = .idle
        } catch let error as ImportError {
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed("The file could not be read.")
        }
        await refreshInventory()
    }

    static func message(for error: ImportError) -> String {
        switch error {
        case .unreadableFile: "Fire Privacy could not open that file."
        case .emptyFile: "That file is empty."
        case .fileTooLarge(_, let limit): "That file is larger than the \(limit / (1024 * 1024)) MB limit."
        case .unsupportedFileType: "Choose the .ndjson file exported from Settings."
        case .securityScopedAccessDenied: "Fire Privacy was not granted access to that file."
        case .tooManyInvalidLines: "Too much of that file could not be read for the results to be trustworthy."
        case .cancelled: "Import cancelled."
        }
    }

    // MARK: Analysis

    private func analyze(_ snapshot: ObservationSnapshot) async throws {
        let matcher = await knowledgeBase.matcher()
        let version = await knowledgeBase.activeVersion
        let stale = await knowledgeBase.isStale
        let overrides = await store.currentOverrides()

        let context = FindingEvaluationContext(
            index: AnalysisIndex(snapshot: snapshot, matcher: matcher),
            knowledgeBaseVersion: version,
            knowledgeBaseIsStale: stale,
            profile: profile,
            overrides: overrides,
            permissions: SelfReportedPermissionSet(),
            protection: protectionCoverage(),
            now: clock()
        )
        var result = engine.evaluate(context)
        if let previous = currentResult {
            result = result.withLifecycle(comparedTo: previous)
        }
        currentResult = result

        let stored = StoredSession(snapshot: snapshot, result: result)
        try await store.save(stored)
        sessions = await store.loadAll()
        updateComparison()
        await advisor.invalidateAll()
        explanations.removeAll()
    }

    public func reevaluate(session: StoredSession) async {
        try? await analyze(session.snapshot)
    }

    private func updateComparison() {
        guard sessions.count >= 2 else {
            comparison = nil
            return
        }
        comparison = ReportComparison(earlier: sessions[sessions.count - 2], later: sessions[sessions.count - 1])
    }

    private func protectionCoverage() -> ProtectionCoverage {
        ProtectionCoverage(
            urlFilterIsActive: protection.urlFilterState.isProtecting,
            urlFilterProfileName: protection.urlFilterProfile?.displayName,
            filterDatasetVersion: protection.filterDatasetVersion,
            safariBlockerIsActive: protection.safariExtensionState == .enabled,
            encryptedDNSIsActive: protection.dnsState == .active,
            osMajorVersion: osMajorVersion
        )
    }

    // MARK: Protection

    public func refreshProtectionState() async {
        let state = await urlFilter.currentState()
        protection.urlFilterState = state
    }

    public func enableProtection(profile: URLFilterProfile) async {
        do {
            try await urlFilter.enable(profile: profile)
            protection.urlFilterProfile = profile
        } catch {
            protection.urlFilterProfile = nil
        }
        await refreshProtectionState()
        await refreshInventory()
    }

    public func disableProtection() async {
        try? await urlFilter.disable()
        await refreshProtectionState()
        await refreshInventory()
    }

    // MARK: Advisor

    public func explain(_ finding: Finding) async {
        guard let result = currentResult else { return }
        let evidence = finding.evidenceIDs.compactMap { result.evidenceByID[$0] }
        let resolution = await advisor.explain(
            finding: finding,
            evidence: evidence,
            mode: advisorMode,
            osMajorVersion: osMajorVersion
        )
        if let resolution {
            explanations[finding.id] = resolution
        }
    }

    public func setAdvisorMode(_ mode: AdvisorMode) async {
        advisorMode = mode
        advisorAvailability = await advisor.availability(of: mode)
        explanations.removeAll()
        await advisor.invalidateAll()
    }

    // MARK: Trust Center

    public func refreshInventory() async {
        let version = await knowledgeBase.activeVersion
        let consents = await consent.activeConsents()
        let overrides = await store.currentOverrides()
        let bytes = await store.byteCount()
        let all = sessions

        inventory = TrustCenterInventory(
            sessionCount: all.count,
            observationCount: all.reduce(0) { $0 + $1.snapshot.networkObservations.count + $1.snapshot.sensorObservations.count },
            findingCount: all.reduce(0) { $0 + $1.findings.count },
            explanationCount: explanations.count,
            overrideCount: overrides.overrides.count,
            retainedRawFileCount: all.filter { $0.snapshot.session.rawCopyState == .encrypted }.count,
            storageBytes: bytes,
            protection: protection,
            activeConsents: consents,
            advisorModeDescription: advisorMode.displayName,
            knowledgeBaseVersion: version.datasetVersion,
            knowledgeBaseExpiresAt: version.expiresAt,
            filterDatasetVersion: protection.filterDatasetVersion,
            lastKnowledgeBaseContact: nil
        )
    }

    public func deleteEverything() async {
        _ = try? await store.delete(scope: .everything)
        await consent.deleteAll()
        await advisor.invalidateAll()
        sessions = []
        currentResult = nil
        comparison = nil
        explanations.removeAll()
        lastImport = nil
        phase = .needsOnboarding
        await refreshInventory()
    }

    public func deleteSession(_ id: UUID) async {
        _ = try? await store.delete(scope: .session(id))
        sessions = await store.loadAll()
        if let latest = sessions.last {
            await reevaluate(session: latest)
        } else {
            currentResult = nil
        }
        updateComparison()
        await refreshInventory()
    }

    // MARK: Derived views

    public var latestSession: StoredSession? { sessions.last }

    public var applications: [ApplicationSummary] {
        guard let session = latestSession, let result = currentResult else { return [] }
        let matcherFindings = Dictionary(grouping: result.findings, by: { $0.subject.key })
        return session.snapshot.applications.map { application in
            let network = session.snapshot.networkObservations.filter { $0.bundleID == application.bundleID }
            let sensors = session.snapshot.sensorObservations.filter { $0.bundleID == application.bundleID }
            let domains = Set(network.map(\.ownerKey.value))
            return ApplicationSummary(
                application: application,
                domainCount: domains.count,
                sensorTypes: Array(Set(sensors.map(\.sensorType))).sorted { $0.identifier < $1.identifier },
                findingCount: matcherFindings["app:\(application.bundleID.rawValue)"]?.count ?? 0,
                totalContacts: network.reduce(0) { $0 + ($1.hits ?? 0) }
            )
        }
        .sorted { ($0.findingCount, $0.totalContacts) > ($1.findingCount, $1.totalContacts) }
    }

    public struct ApplicationSummary: Identifiable, Sendable {
        public var id: String { application.bundleID.rawValue }
        public let application: ObservedApplication
        public let domainCount: Int
        public let sensorTypes: [SensorType]
        public let findingCount: Int
        public let totalContacts: Int
    }
}

#if canImport(Darwin)
extension AppModel {
    /// Imports a file chosen in the document picker.
    ///
    /// Security-scoped access is started for the import and stopped as soon as
    /// it finishes or fails, and no bookmark is kept (IMP-002).
    public func importSecurityScoped(url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        await importReport(at: url)
    }
}
#else
extension AppModel {
    public func importSecurityScoped(url: URL) async {
        await importReport(at: url)
    }
}
#endif
