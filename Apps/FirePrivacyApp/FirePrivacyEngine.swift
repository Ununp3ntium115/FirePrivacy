import Foundation
import FirePrivacyCore

enum EngineError: LocalizedError {
    case unavailable, noReport, consentRequired, staleOperation, invalidUpdate, missingConfiguration
    var errorDescription: String? {
        switch self {
        case .unavailable: "This feature is unavailable for this edition, device, or pending cleanup state."
        case .noReport: "Open a report before using this feature."
        case .consentRequired: "Review and approve this feature’s disclosure before continuing."
        case .staleOperation: "Your report or settings changed. Review a fresh preview and try again."
        case .invalidUpdate: "The update is incomplete, expired, or incompatible. The previous verified data has been preserved."
        case .missingConfiguration: "Provide a valid configuration and a trusted dataset for this feature."
        }
    }
}

struct StoredKnowledgeBase: Codable, Sendable {
    let manifest: Data
    let payload: Data
    let highWaterMark: KnowledgeBaseHighWaterMark
}

struct EnginePreferences: Codable, Sendable {
    var version = 1
    var profile = PrivacyProfile.balanced
    var permissionAudit = ManualPermissionAudit()
    var overrides = DomainOverrideSet()
    var acceptedFindingKeys: Set<String> = []
    var ignoredFindingKeys: Set<String> = []
    var advisorMode = AdvisorMode.offline
    var selfHostedConfiguration: SelfHostedAdvisorConfiguration?
    var dnsConfiguration: DNSResolverConfiguration?
    var pendingProtectionRemoval: Set<ConsentFeature> = []
    var includeOverallScore: Bool? = nil
}

struct PreparedEngineRequest: Sendable {
    let request: ApprovedNetworkRequest
    let preview: NetworkRequestPreview
    let advisorInput: AdvisorInput?
    let operationID: UUID
    let storageGeneration: UUID
}

private struct KnowledgeBaseDownload: Decodable {
    let manifest: Data?
    let payload: Data?
    let revocations: SignedKnowledgeBaseRevocations?
}

private struct StoredKnowledgeBaseRevocations: Codable, Sendable {
    let signed: SignedKnowledgeBaseRevocations
    let highWaterMark: KnowledgeBaseRevocationHighWaterMark
}

private struct StoredFilterDataset: Codable, Sendable {
    let signed: SignedFilterDataset
    let highestVersion: UInt64
    let acceptedDigest: String
}

private struct StoredFilterRevocations: Codable, Sendable {
    let signed: SignedFilterDataset
    let highestVersion: UInt64
    let manifestDigest: String
    let stickyRevocations: FilterRevocations
}

/// The app's integration boundary. Preparing a request never grants permission
/// or sends it; exact preview approval and current persisted consent are required.
@MainActor
final class FirePrivacyEngine {
    let store: EncryptedReportStore
    private(set) var gate: ApprovedNetworkGate
    private(set) var preferences = EnginePreferences()
    private(set) var consent = ConsentState()
    private(set) var knowledgeBase: VerifiedKnowledgeBase?
    private(set) var knowledgeBaseFailure = false
    private(set) var knowledgeBaseRevocations = KnowledgeBaseRevocations()
    private(set) var knowledgeBaseRevocationsCurrent = true
    private(set) var analysis: FindingAnalysis?
    private(set) var lifecycle: FindingLifecycleResult?
    private(set) var analysisHistory = AnalysisHistory()
    private(set) var latestAnalysisRevision: AnalysisHistoryRecord?
    private(set) var analysisHistoryCapacityExceeded = false
    private(set) var advisorResult: AdvisorResult?
    private(set) var comparison: ReportComparison?
    private(set) var weeklySummary: LocalWeeklySummary?
    private(set) var sessions: [ReportSessionDescriptor] = []
    private(set) var unavailableSessionIDs: Set<UUID> = []
    private(set) var pendingSystemCleanup: Set<ConsentFeature> = []
    private(set) var credentialCleanupRequired = false
    private(set) var retention = WorkspaceRetentionPolicy()
    private(set) var pendingStorageCleanupCount = 0
    private(set) var report: PrivacyReport?
    private(set) var protection: ProtectionSnapshot
    private var operationGeneration = UUID()
    private var didRestore = false
    private var isDeleting = false
    private let protectionService = ProtectionService()
    private let reminders = LocalReminderService()
    private let cleanupPlan: ProtectionCleanupPlan
    private let credentials: AdvisorCredentialStore
    private let credentialCleanupMarker: CredentialCleanupMarker
    private let datasetTrust: DatasetTrustConfiguration?
    private let transport: any ApprovedRequestTransport
    private let appVersion: String
    private let osVersion: String

    private func requireCurrent(_ operation: UUID, storageGeneration: UUID) async throws {
        let actual = await store.currentStorageGeneration()
        // Check the MainActor generation after suspension as deletion can begin
        // before the storage actor gets its own deletion call.
        guard !isDeleting, operation == operationGeneration, actual == storageGeneration else {
            throw EngineError.staleOperation
        }
    }

    init(store: EncryptedReportStore, transport: any ApprovedRequestTransport = ApprovedHTTPTransport(),
         cleanupPlan: ProtectionCleanupPlan = ProtectionCleanupPlan(),
         credentialStore: AdvisorCredentialStore = AdvisorCredentialStore(),
         credentialCleanupMarker: CredentialCleanupMarker = CredentialCleanupMarker()) {
        self.store = store
        self.transport = transport
        self.cleanupPlan = cleanupPlan
        credentials = credentialStore
        self.credentialCleanupMarker = credentialCleanupMarker
        datasetTrust = try? DatasetTrustConfiguration.load()
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        gate = ApprovedNetworkGate(appVersion: appVersion, osVersion: osVersion)
        func initial(_ component: ProtectionComponent) -> ProtectionComponentState {
            .init(component: component, phase: .disabled, detail: "Not enabled.")
        }
        protection = .init(safari: initial(.safari), encryptedDNS: initial(.encryptedDNS),
            systemURLFilter: .init(component: .systemURLFilter, phase: .unavailable,
                detail: "Requires the URL-filter edition, Apple approval and a registered PIR service."),
            managed: .init(component: .managed, phase: .unavailable,
                detail: "Requires the managed edition and an authorized supervised or MDM deployment."))
    }

    var datasetTrustConfigurationFailure: Bool { datasetTrust == nil }
    var knowledgeTrustKeyIDs: [String] { datasetTrust?.verifierAnchors.map(\.keyID) ?? [] }
    var filterTrustKeyIDs: [String] { datasetTrust?.publicFilterKeys.keys.sorted() ?? [] }

    private func requireDatasetTrust() throws -> DatasetTrustConfiguration {
        guard let datasetTrust else { throw EngineError.invalidUpdate }
        return datasetTrust
    }

    func restore() async throws -> EncryptedWorkspaceSnapshot {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        let workspace = try await store.loadWorkspace()
        guard operation == operationGeneration else { throw EngineError.staleOperation }
        let storageGeneration = await store.currentStorageGeneration()
        if !didRestore {
            credentialCleanupRequired = try await credentialCleanupMarker.isRequired()
            if credentialCleanupRequired { try? await retryCredentialCleanup() }
            else {
                let generation = await credentials.currentGeneration()
                try await credentials.resumeAfterDeletion(expectedGeneration: generation)
            }
            pendingSystemCleanup = try await cleanupPlan.load()
            if !pendingSystemCleanup.isEmpty {
                // A previous user-requested removal survives deletion of private data.
                try? await retrySystemCleanup()
            }
            var nextPreferences = EnginePreferences()
            if let saved = try await store.loadFeatureState(EnginePreferences.self, key: "preferences") {
                guard saved.version == 1, saved.acceptedFindingKeys.count <= 10_000,
                      saved.ignoredFindingKeys.count <= 10_000, saved.overrides.sorted.count <= 10_000 else {
                    throw ReportStoreError.invalidReport
                }
                try saved.selfHostedConfiguration?.validate()
                try saved.dnsConfiguration?.validate()
                nextPreferences = saved
            }
            let nextConsent = try await store.loadFeatureState(ConsentState.self, key: "consent") ?? ConsentState()
            let events = try await store.loadFeatureState([NetworkEvent].self, key: "network-events") ?? []
            var nextRevocations = KnowledgeBaseRevocations()
            var nextRevocationsCurrent = true
            var nextKnowledge: VerifiedKnowledgeBase?
            var nextKnowledgeFailure = false
            if let saved = try await store.loadFeatureState(StoredKnowledgeBaseRevocations.self, key: "kb-revocations") {
                nextRevocations = saved.highWaterMark.revocations
                do {
                    _ = try KnowledgeBaseRevocationVerifier(trustAnchors: requireDatasetTrust().verifierAnchors).verify(saved.signed,
                        highWaterMark: saved.highWaterMark, restoringCurrent: true)
                } catch KnowledgeBaseRevocationVerifier.Failure.expired {
                    nextRevocationsCurrent = false
                }
            }
            if let saved = try await store.loadFeatureState(StoredKnowledgeBase.self, key: "knowledge-base") {
                do {
                    nextKnowledge = try knowledgeVerifier(nextRevocations).verify(
                        manifestData: saved.manifest, payloadData: saved.payload, appVersion: appVersion,
                        highWaterMark: saved.highWaterMark, restoringCurrent: true)
                } catch {
                    // Never replace a rejected downloaded version with an older bundled version.
                    nextKnowledgeFailure = true
                }
            } else {
                do {
                    let bundled = try KnowledgeBaseResources.loadBundled(appVersion: appVersion)
                    guard !nextRevocations.revokes(bundled.manifest) else { throw KnowledgeBaseVerifier.Failure.revoked }
                    nextKnowledge = bundled
                }
                catch { nextKnowledgeFailure = true }
            }
            await gate.cancelAllRequests()
            guard operation == operationGeneration,
                  await store.currentStorageGeneration() == storageGeneration else { throw EngineError.staleOperation }
            preferences = nextPreferences
            preferences.pendingProtectionRemoval = pendingSystemCleanup
            consent = nextConsent
            knowledgeBase = nextKnowledge
            knowledgeBaseFailure = nextKnowledgeFailure
            knowledgeBaseRevocations = nextRevocations
            knowledgeBaseRevocationsCurrent = nextRevocationsCurrent
            gate = ApprovedNetworkGate(consent: nextConsent, appVersion: appVersion, osVersion: osVersion,
                                       ledger: NetworkEventLedger(events: events))
            didRestore = true
        }
        guard operation == operationGeneration,
              await store.currentStorageGeneration() == storageGeneration else { throw EngineError.staleOperation }
        try await adopt(workspace)
        return workspace
    }

    func importReport(_ value: PrivacyReport, source: Data? = nil) async throws -> EncryptedWorkspaceSnapshot {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        let authorization = try await gate.authorizeFeature(.localImport, scopeIdentity: "local-import-v1")
        guard await gate.validateAuthorization(authorization) else { throw EngineError.consentRequired }
        if source != nil {
            let raw = try await gate.authorizeFeature(.retainEncryptedSource, scopeIdentity: "encrypted-source-v1")
            guard await gate.validateAuthorization(raw) else { throw EngineError.consentRequired }
        }
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        let workspace = try await store.appendSession(value, encryptedSource: source, expectedGeneration: storageGeneration)
        guard operation == operationGeneration else { throw EngineError.staleOperation }
        try await adopt(workspace)
        return workspace
    }

    func selectReport(_ id: UUID) async throws -> EncryptedWorkspaceSnapshot {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        let workspace = try await store.selectSession(id, expectedGeneration: storageGeneration)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await adopt(workspace)
        return workspace
    }

    func showSample() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        report = .demo
        try await rebuildAnalysis()
    }

    private func adopt(_ workspace: EncryptedWorkspaceSnapshot) async throws {
        let operation = operationGeneration
        sessions = workspace.sessions
        retention = workspace.retention
        pendingStorageCleanupCount = workspace.pendingCleanupCount
        report = workspace.selectedReport
        try await rebuildAnalysis()
        guard operation == operationGeneration else { throw EngineError.staleOperation }
        var snapshots: [PrivacyReport] = []
        unavailableSessionIDs = []
        for session in sessions {
            do { snapshots.append(try await store.reportSession(session.id)) }
            catch { unavailableSessionIDs.insert(session.id) }
            guard operation == operationGeneration else { throw EngineError.staleOperation }
        }
        weeklySummary = WeeklySummaryBuilder.build(reports: snapshots)
        if let current = report,
           let previous = snapshots.filter({ $0.id != current.id && $0.importedAt <= current.importedAt })
                .max(by: { $0.importedAt < $1.importedAt }) {
            comparison = ReportComparator.compare(earlier: previous, later: current)
        } else { comparison = nil }
    }

    func rebuildAnalysis() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        let previous = analysis
        let snapshot = try await store.loadFeatureSnapshot(AnalysisHistory.self, key: "analysis-history")
        var history = snapshot.value ?? AnalysisHistory()
        history.retain(reportIDs: Set(sessions.map(\.id)))
        guard let report else {
            if history != snapshot.value, snapshot.value != nil {
                try await requireCurrent(operation, storageGeneration: storageGeneration)
                try await store.saveFeatureState(history, key: "analysis-history", expectedGeneration: storageGeneration,
                    expectedCurrent: snapshot.precondition)
            }
            try await requireCurrent(operation, storageGeneration: storageGeneration)
            analysis = nil; lifecycle = nil; advisorResult = nil
            latestAnalysisRevision = nil; analysisHistory = history; analysisHistoryCapacityExceeded = false
            try await gate.updateContext(reportIdentity: nil, configurationIdentity: "local-only-v1")
            return
        }
        let reviewed = knowledgeBase.map { DomainMatcher(snapshot: $0).findingContexts(for: report) } ?? []
        let context = FindingContext(profile: preferences.profile,
            permissionAudit: preferences.permissionAudit, reviewedDomains: reviewed, domainOverrides: preferences.overrides,
            protection: .init(urlFilterAvailable: protection.systemURLFilter.phase != .unavailable,
                urlFilterActive: protection.systemURLFilter.isActive,
                safariBlockerAvailable: protection.safari.phase != .unavailable, safariBlockerActive: protection.safari.isActive),
            includeOverallScore: preferences.includeOverallScore == true)
        let current = VersionedFindingEngine.evaluate(report: report, context: context)
        var revision: AnalysisHistoryRecord?
        var capacityExceeded = false
        if report.metadata?.isSyntheticDemo != true, sessions.contains(where: { $0.id == report.id }) {
            // The latest earlier imported session is an explicit comparison
            // baseline. A report's own existing revision always takes precedence.
            let baseline = sessions.filter { $0.id != report.id && $0.importedAt <= report.importedAt }
                .max(by: { $0.importedAt < $1.importedAt })?.id
            do {
                revision = try history.record(report: report, analysis: current, context: context,
                    knowledgeBaseVersion: knowledgeBase?.version, acceptedKeys: preferences.acceptedFindingKeys,
                    ignoredKeys: preferences.ignoredFindingKeys, baselineReportID: baseline)
            } catch AnalysisHistoryError.oversizedRecord { capacityExceeded = true }
            catch AnalysisHistoryError.oversizedHistory { capacityExceeded = true }
        }
        if history != snapshot.value, snapshot.value != nil || !history.records.isEmpty {
            try await requireCurrent(operation, storageGeneration: storageGeneration)
            try await store.saveFeatureState(history, key: "analysis-history", expectedGeneration: storageGeneration,
                expectedCurrent: snapshot.precondition)
        }
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        analysis = current
        analysisHistory = history
        latestAnalysisRevision = revision
        analysisHistoryCapacityExceeded = capacityExceeded
        let fallbackBaseline = history.latest(for: report.id)?.analysis
            ?? (previous?.reportID == report.id && sessions.contains(where: { $0.id == report.id }) ? previous : nil)
        lifecycle = revision?.lifecycle ?? FindingLifecycle.compare(previous: fallbackBaseline, current: current,
            acceptedKeys: preferences.acceptedFindingKeys, ignoredKeys: preferences.ignoredFindingKeys)
        advisorResult = nil
        try await gate.updateContext(reportIdentity: AdvisorInput.identity(for: current),
            configurationIdentity: preferences.selfHostedConfiguration?.identity ?? "local-only-v1")
        try await requireCurrent(operation, storageGeneration: storageGeneration)
    }

    /// This method is invoked only after the user accepts the feature disclosure.
    func grant(_ feature: ConsentFeature, scope: String,
               disclosureVersion: String = ConsentDisclosure.currentVersion) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        guard feature != .privateCloudCompute else { throw EngineError.unavailable }
        guard !pendingSystemCleanup.contains(feature) else { throw EngineError.unavailable }
        let storageGeneration = await store.currentStorageGeneration()
        _ = try await gate.grantConsent(feature: feature, disclosureVersion: disclosureVersion, scopeIdentity: scope)
        do { try await persistConsent(storageGeneration: storageGeneration) }
        catch { try? await gate.revokeConsent(feature); throw error }
    }

    func revoke(_ feature: ConsentFeature) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        var storageGeneration = await store.currentStorageGeneration()
        try await gate.revokeConsent(feature)
        let protectionFeatures: Set<ConsentFeature> = [.safariProtection, .encryptedDNS, .urlProtection, .managedProtection]
        var removalError: (any Error)?
        if protectionFeatures.contains(feature) {
            preferences.pendingProtectionRemoval.insert(feature)
            pendingSystemCleanup.insert(feature)
            do { try await cleanupPlan.save(pendingSystemCleanup) } catch { removalError = error }
        }
        do {
            switch feature {
            case .safariProtection: try await protectionService.removeSafari()
            case .encryptedDNS: try await protectionService.removeDNS()
            case .urlProtection:
                if #available(iOS 26.0, *) { try await URLFilterService().remove() }
            case .managedProtection: try await ManagedProtectionService().remove()
            case .localReminders: await reminders.removeAll()
            case .retainEncryptedSource:
                let workspace = try await store.removeRetainedSources(expectedGeneration: storageGeneration)
                guard operation == operationGeneration else { throw EngineError.staleOperation }
                storageGeneration = await store.currentStorageGeneration()
                try await adopt(workspace)
            case .onDeviceAdvisor, .selfHostedAdvisor: advisorResult = nil
            default: break
            }
            pendingSystemCleanup.remove(feature)
            preferences.pendingProtectionRemoval.remove(feature)
            try await cleanupPlan.save(pendingSystemCleanup)
        } catch { removalError = error }
        do {
            try await persistConsent(storageGeneration: storageGeneration)
        } catch { removalError = error }
        await refreshProtection()
        if let removalError { throw removalError }
    }

    private func persistConsent(storageGeneration: UUID) async throws {
        for attempt in 0..<3 {
            let previous = try await store.loadFeatureSnapshot(ConsentState.self, key: "consent")
            let current = await gate.consentSnapshot()
            consent = current
            do {
                try await store.saveFeatureState(current, key: "consent", expectedGeneration: storageGeneration,
                    expectedCurrent: previous.precondition)
                return
            } catch ReportStoreError.preconditionFailed {
                if attempt == 2 { throw ReportStoreError.preconditionFailed }
            }
        }
    }

    func savePreferences(_ value: EnginePreferences) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        guard value.version == 1, value.overrides.sorted.count <= 10_000,
              value.acceptedFindingKeys.count <= 10_000, value.ignoredFindingKeys.count <= 10_000 else {
            throw ReportStoreError.invalidReport
        }
        try value.selfHostedConfiguration?.validate()
        try value.dnsConfiguration?.validate()
        operationGeneration = UUID()
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        let previous = try await store.loadFeatureSnapshot(EnginePreferences.self, key: "preferences")
        await gate.cancelAllRequests()
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await store.saveFeatureState(value, key: "preferences", expectedGeneration: storageGeneration,
            expectedCurrent: previous.precondition)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        preferences = value
        try await rebuildAnalysis()
    }

    func updateRetention(_ value: WorkspaceRetentionPolicy) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        let workspace = try await store.updateRetention(value, expectedGeneration: storageGeneration)
        guard operation == operationGeneration else { throw EngineError.staleOperation }
        try await adopt(workspace)
    }

    func deleteReport(_ id: UUID) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        await gate.cancelAllRequests()
        let storageGeneration = await store.currentStorageGeneration()
        let workspace = try await store.deleteSession(id, expectedGeneration: storageGeneration)
        guard operation == operationGeneration else { throw EngineError.staleOperation }
        try await adopt(workspace)
    }

    func assessLocally() async throws -> AdvisorResult {
        guard !isDeleting else { throw EngineError.staleOperation }
        guard let analysis else { throw EngineError.noReport }
        let generation = operationGeneration
        let input = try AdvisorInput.make(analysis: analysis)
        var preferred: (any PrivacyAdvisor)?
        var authorization: ConsentAuthorization?
        if preferences.advisorMode == .appleOnDevice {
            authorization = try await gate.authorizeFeature(.onDeviceAdvisor, scopeIdentity: "system-language-model-v1")
            preferred = SystemLanguageModelAdvisor()
        }
        let result = try await AdvisorCoordinator.assess(input, preferred: preferred)
        guard generation == operationGeneration else { throw EngineError.staleOperation }
        if let authorization, !(await gate.validateAuthorization(authorization)) { throw EngineError.staleOperation }
        advisorResult = result
        return result
    }

    func prepareSelfHostedAssessment(bearerToken: String? = nil) async throws -> PreparedEngineRequest {
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        guard let analysis else { throw EngineError.noReport }
        guard let configuration = preferences.selfHostedConfiguration else { throw EngineError.missingConfiguration }
        guard didRestore, !credentialCleanupRequired else { throw EngineError.unavailable }
        let credentialGeneration = await credentials.currentGeneration()
        let token: String?
        if let bearerToken { token = bearerToken }
        else { token = try await credentials.token(for: configuration, expectedGeneration: credentialGeneration) }
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        let input = try AdvisorInput.make(analysis: analysis)
        let request = try SelfHostedAdvisor.prepare(input: input, configuration: configuration, bearerToken: token)
        try await gate.updateContext(reportIdentity: request.reportIdentity, configurationIdentity: request.configurationIdentity)
        let preview = try await gate.preview(request)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        return PreparedEngineRequest(request: request, preview: preview, advisorInput: input,
            operationID: operation, storageGeneration: storageGeneration)
    }

    func prepareUpdate(endpoint: URL, purpose: NetworkPurpose, operatorRetention: String) async throws -> PreparedEngineRequest {
        let operation = operationGeneration
        let storageGeneration = await store.currentStorageGeneration()
        guard purpose == .knowledgeBaseUpdate || purpose == .filterListUpdate else { throw EngineError.invalidUpdate }
        let identity = ContentDigest.sha256(Data((purpose.rawValue + "\n" + endpoint.absoluteString + "\n" + operatorRetention).utf8))
        let request = try ApprovedNetworkRequest(purpose: purpose, endpoint: endpoint, method: .get,
            body: Data(), disclosureVersion: ConsentDisclosure.currentVersion, reportIdentity: nil, configurationIdentity: identity,
            payloadFields: [],
            retentionDisclosure: operatorRetention)
        let reportIdentity = try analysis.map { try AdvisorInput.identity(for: $0) }
        try await gate.updateContext(reportIdentity: reportIdentity,
                                     configurationIdentity: identity)
        let preview = try await gate.preview(request)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        return PreparedEngineRequest(request: request, preview: preview, advisorInput: nil,
            operationID: operation, storageGeneration: storageGeneration)
    }

    /// Called by the explicit send action after the exact preview has been shown.
    func send(_ prepared: PreparedEngineRequest) async throws -> ApprovedNetworkResponse {
        let generation = operationGeneration
        guard generation == prepared.operationID else { throw EngineError.staleOperation }
        try await requireCurrent(generation, storageGeneration: prepared.storageGeneration)
        // A new consent receipt invalidates the old preview token. Refresh that
        // token while proving the exact visible request and disclosure are unchanged.
        let preview = try await gate.preview(prepared.request)
        guard preview.disclosure == prepared.preview.disclosure,
              preview.payloadUTF8 == prepared.preview.payloadUTF8,
              preview.payloadSHA256 == prepared.preview.payloadSHA256,
              preview.reportIdentity == prepared.preview.reportIdentity,
              preview.configurationIdentity == prepared.preview.configurationIdentity,
              preview.certificateSHA256 == prepared.preview.certificateSHA256,
              preview.authenticationDescription == prepared.preview.authenticationDescription else {
            throw EngineError.staleOperation
        }
        let approval = try await gate.approve(preview)
        do {
            let response = try await gate.execute(prepared.request, approval: approval, using: transport)
            try await requireCurrent(generation, storageGeneration: prepared.storageGeneration)
            if let input = prepared.advisorInput {
                let checked = try SelfHostedAdvisor.decode(response: response, for: input)
                // Rendered text remains authored from evidence; the model supplies order/style only.
                _ = try AdvisorRenderer.explanations(assessment: checked, analysis: try requireAnalysis())
                advisorResult = AdvisorResult(assessment: checked, mode: .selfHosted, fallback: nil)
            } else if prepared.request.purpose == .knowledgeBaseUpdate {
                let download = try JSONDecoder().decode(KnowledgeBaseDownload.self, from: response.body)
                guard download.revocations != nil || (download.manifest != nil && download.payload != nil),
                      (download.manifest == nil) == (download.payload == nil) else { throw EngineError.invalidUpdate }
                if let revocations = download.revocations {
                    try await installKnowledgeBaseRevocations(revocations, expectedGeneration: prepared.storageGeneration)
                }
                if let manifest = download.manifest, let payload = download.payload {
                    try await installKnowledgeBase(manifest: manifest, payload: payload,
                        expectedGeneration: prepared.storageGeneration)
                }
            } else if prepared.request.purpose == .filterListUpdate {
                let signed = try JSONDecoder().decode(SignedFilterDataset.self, from: response.body)
                _ = try await installFilterDataset(signed, expectedGeneration: prepared.storageGeneration)
            }
            try await store.saveFeatureState(await gate.ledger.snapshot(), key: "network-events",
                expectedGeneration: prepared.storageGeneration)
            return response
        } catch {
            if generation == operationGeneration {
                try? await store.saveFeatureState(await gate.ledger.snapshot(), key: "network-events",
                    expectedGeneration: prepared.storageGeneration)
            }
            throw error
        }
    }

    func filterDataset(_ kind: FilterPayloadKind) async throws -> ValidatedFilterDataset {
        guard kind != .revocationsV1 else { throw EngineError.invalidUpdate }
        let key = "filter-" + kind.rawValue.lowercased()
        let revoked = try await filterRevocations(kind)
        if let saved = try await store.loadFeatureState(StoredFilterDataset.self, key: key) {
            return try FilterDatasetVerifier.verify(saved.signed, trustedKeys: requireDatasetTrust().publicFilterKeys,
                highestAcceptedVersion: saved.highestVersion, revocations: revoked?.document.revocations ?? .init())
        }
        guard kind == .safariDomainsV1 else { throw EngineError.missingConfiguration }
        let starter = try BundledProtectionDataset.safariStarter()
        return try FilterDatasetVerifier.verify(starter.signedDataset, trustedKeys: requireDatasetTrust().publicFilterKeys,
            revocations: revoked?.document.revocations ?? .init())
    }

    func installFilterDataset(_ signed: SignedFilterDataset, expectedGeneration: UUID? = nil) async throws -> ValidatedFilterDataset {
        let operation = operationGeneration
        let storageGeneration: UUID
        if let expectedGeneration { storageGeneration = expectedGeneration }
        else { storageGeneration = await store.currentStorageGeneration() }
        if signed.manifest.kind == .revocationsV1 {
            let doc = try JSONDecoder().decode(FilterRevocationDocument.self, from: signed.payload)
            try doc.validate()
            let key = "filter-revocations-" + doc.targetKind.rawValue.lowercased()
            let snapshot = try await store.loadFeatureSnapshot(StoredFilterRevocations.self, key: key)
            let previous = snapshot.value
            let verified = try FilterDatasetVerifier.verifyRevocationList(signed, trustedKeys: requireDatasetTrust().publicFilterKeys,
                highestAcceptedVersion: previous?.highestVersion ?? 0,
                previousRevocations: previous?.stickyRevocations ?? .init())
            let revocationDigest = try verified.manifestDigest
            if let previous, verified.version == previous.highestVersion,
               revocationDigest != previous.manifestDigest { throw FilterDatasetError.rollback }
            if let previous, revocationDigest == previous.manifestDigest {
                // Rechecking a current publisher release must not remove active
                // protection again. Identity covers the entire signed manifest.
                return try FilterDatasetVerifier.verify(signed, trustedKeys: requireDatasetTrust().publicFilterKeys)
            }
            try await requireCurrent(operation, storageGeneration: storageGeneration)
            try await store.saveFeatureState(StoredFilterRevocations(signed: signed,
                highestVersion: verified.version, manifestDigest: revocationDigest,
                stickyRevocations: verified.document.revocations), key: key,
                expectedGeneration: storageGeneration, expectedCurrent: snapshot.precondition)
            try await requireCurrent(operation, storageGeneration: storageGeneration)
            let feature: ConsentFeature
            switch doc.targetKind {
            case .safariDomainsV1: feature = .safariProtection
            case .appleURLBloomV1: feature = .urlProtection
            case .managedRulesV1: feature = .managedProtection
            case .revocationsV1: throw EngineError.invalidUpdate
            }
            if consent.receipts.contains(where: { $0.feature == feature && $0.isActive }) {
                pendingSystemCleanup.insert(feature)
                try await cleanupPlan.save(pendingSystemCleanup)
                try await gate.revokeConsent(feature)
                try await persistConsent(storageGeneration: storageGeneration)
            }
            var applyError: (any Error)?
            if pendingSystemCleanup.contains(feature) {
                do { try protectionService.applyRevocations(verified) } catch { applyError = error }
            }
            // Applying an authenticated revocation update removes installed rules;
            // reactivation requires an explicit choice with the current dataset.
            do { try await retrySystemCleanup() } catch { applyError = error }
            await refreshProtection()
            if let applyError { throw applyError }
            return try FilterDatasetVerifier.verify(signed, trustedKeys: requireDatasetTrust().publicFilterKeys)
        }
        let key = "filter-" + signed.manifest.kind.rawValue.lowercased()
        let snapshot = try await store.loadFeatureSnapshot(StoredFilterDataset.self, key: key)
        let existing = snapshot.value
        let manifestDigest = ContentDigest.sha256(try signed.manifest.signedRepresentation())
        if let existing, signed.manifest.version == existing.signed.manifest.version,
           manifestDigest != existing.acceptedDigest { throw FilterDatasetError.rollback }
        let minimum = existing?.highestVersion ?? (signed.manifest.kind == .safariDomainsV1 ? 1 : 0)
        let revoked = try await filterRevocations(signed.manifest.kind)
        let verified = try FilterDatasetVerifier.verify(signed, trustedKeys: requireDatasetTrust().publicFilterKeys,
            highestAcceptedVersion: minimum, revocations: revoked?.document.revocations ?? .init())
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await store.saveFeatureState(StoredFilterDataset(signed: signed,
            highestVersion: max(minimum, signed.manifest.version), acceptedDigest: manifestDigest), key: key,
            expectedGeneration: storageGeneration, expectedCurrent: snapshot.precondition)
        return verified
    }

    private func filterRevocations(_ kind: FilterPayloadKind) async throws -> ValidatedFilterRevocationList? {
        let key = "filter-revocations-" + kind.rawValue.lowercased()
        guard let saved = try await store.loadFeatureState(StoredFilterRevocations.self, key: key) else { return nil }
        return try FilterDatasetVerifier.verifyRevocationList(saved.signed, trustedKeys: requireDatasetTrust().publicFilterKeys,
            highestAcceptedVersion: saved.highestVersion, previousRevocations: saved.stickyRevocations)
    }

    private func requireAnalysis() throws -> FindingAnalysis {
        guard let analysis else { throw EngineError.noReport }; return analysis
    }

    func installKnowledgeBase(manifest: Data, payload: Data, expectedGeneration: UUID? = nil) async throws {
        let operation = operationGeneration
        let storageGeneration: UUID
        if let expectedGeneration { storageGeneration = expectedGeneration }
        else { storageGeneration = await store.currentStorageGeneration() }
        let snapshot = try await store.loadFeatureSnapshot(StoredKnowledgeBase.self, key: "knowledge-base")
        let previous = snapshot.value
        guard knowledgeBaseRevocationsCurrent else { throw EngineError.invalidUpdate }
        if let previous, previous.manifest == manifest, previous.payload == payload {
            _ = try knowledgeVerifier().verify(manifestData: manifest, payloadData: payload,
                appVersion: appVersion, highWaterMark: previous.highWaterMark, restoringCurrent: true)
            try await requireCurrent(operation, storageGeneration: storageGeneration)
            return
        }
        let verified = try knowledgeVerifier().verify(
            manifestData: manifest, payloadData: payload, appVersion: appVersion,
            highWaterMark: previous?.highWaterMark ?? knowledgeBase?.highWaterMark)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await store.saveFeatureState(StoredKnowledgeBase(manifest: manifest, payload: payload,
            highWaterMark: verified.highWaterMark), key: "knowledge-base",
            expectedGeneration: storageGeneration, expectedCurrent: snapshot.precondition)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        guard !knowledgeBaseRevocations.revokes(verified.manifest) else { throw KnowledgeBaseVerifier.Failure.revoked }
        knowledgeBase = verified; knowledgeBaseFailure = false
        operationGeneration = UUID()
        try await rebuildAnalysis()
    }

    private func knowledgeVerifier(_ revocations: KnowledgeBaseRevocations? = nil) throws -> KnowledgeBaseVerifier {
        let current = revocations ?? knowledgeBaseRevocations
        return KnowledgeBaseVerifier(trustAnchors: try requireDatasetTrust().verifierAnchors,
            revokedVersions: current.revokedVersions, revokedKeyIDs: current.revokedKeyIDs,
            revokedPayloadDigests: current.revokedPayloadDigests)
    }

    func installKnowledgeBaseRevocations(_ signed: SignedKnowledgeBaseRevocations,
                                         expectedGeneration: UUID? = nil) async throws {
        let operation = operationGeneration
        let storageGeneration: UUID
        if let expectedGeneration { storageGeneration = expectedGeneration }
        else { storageGeneration = await store.currentStorageGeneration() }
        let previous = try await store.loadFeatureSnapshot(StoredKnowledgeBaseRevocations.self, key: "kb-revocations")
        if let current = previous.value, current.signed == signed {
            _ = try KnowledgeBaseRevocationVerifier(trustAnchors: requireDatasetTrust().verifierAnchors).verify(signed,
                highWaterMark: current.highWaterMark, restoringCurrent: true)
            try await requireCurrent(operation, storageGeneration: storageGeneration)
            return
        }
        let verified = try KnowledgeBaseRevocationVerifier(trustAnchors: requireDatasetTrust().verifierAnchors).verify(signed, highWaterMark: previous.value?.highWaterMark)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await store.saveFeatureState(StoredKnowledgeBaseRevocations(signed: signed, highWaterMark: verified.highWaterMark),
            key: "kb-revocations", expectedGeneration: storageGeneration, expectedCurrent: previous.precondition)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        knowledgeBaseRevocations = verified.revocations
        knowledgeBaseRevocationsCurrent = true
        if let knowledgeBase, verified.revocations.revokes(knowledgeBase.manifest) {
            self.knowledgeBase = nil
            knowledgeBaseFailure = true
        }
        operationGeneration = UUID()
        try await rebuildAnalysis()
    }

    func enableSafari(_ dataset: ValidatedFilterDataset) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        let allowed = preferences.overrides.sorted.filter { $0.disposition == .localAllow }.map { $0.host.value }
        let blocked = preferences.overrides.sorted.filter { $0.disposition == .localBlockRequest }.map { $0.host.value }
        let configuration = try dataset.safariConfiguration(allowedDomains: allowed, userBlockedDomains: blocked)
        let authorization = try await gate.authorizeFeature(.safariProtection, scopeIdentity: configuration.scopeIdentity)
        protection.safari = try await protectionService.enableSafari(dataset: dataset, allowedDomains: allowed,
            userBlockedDomains: blocked,
            revocationList: filterRevocations(.safariDomainsV1),
            authorization: authorization, checker: gate)
        try await rebuildAnalysis()
    }

    func enableDNS() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        guard let configuration = preferences.dnsConfiguration else { throw EngineError.missingConfiguration }
        let authorization = try await gate.authorizeFeature(.encryptedDNS, scopeIdentity: configuration.scopeIdentity)
        protection.encryptedDNS = try await protectionService.enableDNS(configuration: configuration,
            authorization: authorization, checker: gate)
    }

    @available(iOS 26.0, *)
    func enableURLFilter(_ dataset: ValidatedFilterDataset, authenticationToken: String) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        let identifier = (Bundle.main.bundleIdentifier ?? "") + ".URLFilterControl"
        let configuration = try dataset.urlConfiguration(controlProviderBundleIdentifier: identifier)
        let authorization = try await gate.authorizeFeature(.urlProtection, scopeIdentity: configuration.scopeIdentity)
        protection.systemURLFilter = try await URLFilterService().enable(dataset: dataset,
            authenticationToken: authenticationToken, revocationList: filterRevocations(.appleURLBloomV1),
            authorization: authorization, checker: gate)
        try await rebuildAnalysis()
    }

    func enableManaged(_ dataset: ValidatedFilterDataset) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        let policy = try JSONDecoder().decode(ManagedPolicy.self, from: dataset.payload)
        let authorization = try await gate.authorizeFeature(.managedProtection, scopeIdentity: policy.scopeIdentity)
        protection.managed = try await ManagedProtectionService().enable(dataset: dataset,
            authorization: authorization, revocationList: filterRevocations(.managedRulesV1), checker: gate)
    }

    func refreshProtection() async {
        guard !isDeleting else { return }
        let operation = operationGeneration
        var current = protection
        current.safari = await protectionService.safariState()
        current.encryptedDNS = await protectionService.dnsState(expected: preferences.dnsConfiguration)
        let edition = Bundle.main.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String ?? "consumer"
        if edition == "url-filter", #available(iOS 26.0, *) { current.systemURLFilter = await URLFilterService().state() }
        if edition == "managed" { current.managed = await ManagedProtectionService().state() }
        guard !isDeleting, operation == operationGeneration else { return }
        protection = current
    }

    func scheduleReminder(weekday: Int, hour: Int, minute: Int) async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        let authorization = try await gate.authorizeFeature(.localReminders, scopeIdentity: "weekly-local-reminder-v1")
        try await reminders.schedule(weekday: weekday, hour: hour, minute: minute, authorization: authorization, checker: gate)
    }

    /// Saving the token is a separate explicit action from configuring an endpoint
    /// or preparing/sending a request. Its account is the exact configuration.
    func retainAdvisorCredential(_ token: String) async throws {
        guard let configuration = preferences.selfHostedConfiguration else { throw EngineError.missingConfiguration }
        guard !isDeleting, didRestore, !credentialCleanupRequired else { throw EngineError.unavailable }
        operationGeneration = UUID()
        let operation = operationGeneration
        await gate.cancelAllRequests()
        let storageGeneration = await store.currentStorageGeneration()
        let credentialGeneration = await credentials.currentGeneration()
        try await credentials.resumeAfterDeletion(expectedGeneration: credentialGeneration)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await credentials.retain(token, for: configuration, expectedGeneration: credentialGeneration)
        try await requireCurrent(operation, storageGeneration: storageGeneration)
    }

    /// Clear every saved advisor credential, including credentials for a previous
    /// endpoint configuration that can no longer be selected in preferences.
    func forgetAdvisorCredentials() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        await gate.cancelAllRequests()
        credentialCleanupRequired = true
        try await credentialCleanupMarker.setRequired(true)
        try await retryCredentialCleanup()
    }

    func retryCredentialCleanup() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        try await removeCredentials(resumeAfter: true)
    }

    private func removeCredentials(resumeAfter: Bool) async throws {
        try await credentials.disableAndEraseAll()
        try await credentialCleanupMarker.setRequired(false)
        if resumeAfter {
            let generation = await credentials.currentGeneration()
            try await credentials.resumeAfterDeletion(expectedGeneration: generation)
        }
        credentialCleanupRequired = false
    }

    func rotateEncryptionKey() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        let operation = operationGeneration
        await gate.cancelAllRequests()
        let storageGeneration = await store.currentStorageGeneration()
        try await requireCurrent(operation, storageGeneration: storageGeneration)
        try await store.rotateKey(expectedGeneration: storageGeneration)
        guard operation == operationGeneration else { throw EngineError.staleOperation }
        didRestore = false
        _ = try await restore()
    }

    func retryStorageCleanup() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        operationGeneration = UUID()
        await gate.cancelAllRequests()
        let storageGeneration = await store.currentStorageGeneration()
        try await store.retryKeyRotationCleanup(expectedGeneration: storageGeneration)
        didRestore = false
        _ = try await restore()
    }

    func diagnostics() async throws -> Data {
        guard !isDeleting else { throw EngineError.staleOperation }
        let authorization = try await gate.authorizeFeature(.diagnosticsExport, scopeIdentity: "sanitized-diagnostics-v1")
        guard await gate.validateAuthorization(authorization) else { throw EngineError.consentRequired }
        var reports: [PrivacyReport] = []
        for session in sessions { reports.append(try await store.reportSession(session.id)) }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return try DiagnosticsBuilder.json(DiagnosticsBuilder.build(reports: reports, appVersion: appVersion,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"))
    }

    /// Revoke/cancel before destroying storage. OS removal failures remain visible
    /// and retryable rather than reporting that filtering has been disabled.
    func deleteAll() async throws {
        guard !isDeleting else { throw EngineError.staleOperation }
        isDeleting = true
        defer { isDeleting = false }
        operationGeneration = UUID()
        let activeFeatures = Set(consent.receipts.filter(\.isActive).map(\.feature))
            .union(preferences.pendingProtectionRemoval)
            .union(try await cleanupPlan.load())
        let protectionFeatures: Set<ConsentFeature> = [.safariProtection, .encryptedDNS, .urlProtection, .managedProtection]
        pendingSystemCleanup = activeFeatures.intersection(protectionFeatures)
        // Commit a nonsensitive durable removal plan before destroying its private origin.
        try await cleanupPlan.save(pendingSystemCleanup)
        try await credentialCleanupMarker.setRequired(true)
        credentialCleanupRequired = true
        try await gate.deleteAll()
        consent = await gate.consentSnapshot()
        await reminders.removeAll()
        var failure: (any Error)?
        do { try await removeCredentials(resumeAfter: false) } catch { failure = error }
        do { try await retrySystemCleanup() } catch { failure = error }
        try await store.deleteAll()
        report = nil; sessions = []; preferences = EnginePreferences(); consent = ConsentState()
        knowledgeBase = nil; analysis = nil; lifecycle = nil; advisorResult = nil
        analysisHistory = AnalysisHistory(); latestAnalysisRevision = nil; analysisHistoryCapacityExceeded = false
        knowledgeBaseFailure = false
        knowledgeBaseRevocations = KnowledgeBaseRevocations(); knowledgeBaseRevocationsCurrent = true
        comparison = nil; weeklySummary = nil; didRestore = false
        retention = WorkspaceRetentionPolicy(); pendingStorageCleanupCount = 0
        unavailableSessionIDs = []
        if let failure { throw failure }
    }

    func retrySystemCleanup() async throws {
        var features = try await cleanupPlan.load()
        var failure: (any Error)?
        let edition = Bundle.main.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String ?? "consumer"
        for feature in features {
            do {
                switch feature {
                case .safariProtection: try await protectionService.removeSafari()
                case .encryptedDNS: try await protectionService.removeDNS()
                case .urlProtection:
                    guard edition == "url-filter" else { throw EngineError.unavailable }
                    if #available(iOS 26.0, *) { try await URLFilterService().remove() }
                    else { throw EngineError.unavailable }
                case .managedProtection:
                    guard edition == "managed" else { throw EngineError.unavailable }
                    try await ManagedProtectionService().remove()
                default: throw EngineError.unavailable
                }
                features.remove(feature)
            } catch { failure = error }
        }
        pendingSystemCleanup = features
        try await cleanupPlan.save(features)
        if let failure { throw failure }
    }
}
