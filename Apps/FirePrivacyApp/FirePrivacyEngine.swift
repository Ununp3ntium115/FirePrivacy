import Foundation
import FirePrivacyCore

enum EngineError: Error {
    case unavailable, noReport, consentRequired, staleOperation, invalidUpdate, missingConfiguration
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
}

struct PreparedEngineRequest: Sendable {
    let request: ApprovedNetworkRequest
    let preview: NetworkRequestPreview
    let advisorInput: AdvisorInput?
}

private struct KnowledgeBaseDownload: Decodable {
    let manifest: Data
    let payload: Data
}

private struct StoredFilterDataset: Codable, Sendable {
    let signed: SignedFilterDataset
    let highestVersion: UInt64
    let acceptedDigest: String
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
    private(set) var analysis: FindingAnalysis?
    private(set) var lifecycle: FindingLifecycleResult?
    private(set) var advisorResult: AdvisorResult?
    private(set) var comparison: ReportComparison?
    private(set) var weeklySummary: LocalWeeklySummary?
    private(set) var sessions: [ReportSessionDescriptor] = []
    private(set) var unavailableSessionIDs: Set<UUID> = []
    private(set) var pendingSystemCleanup: Set<ConsentFeature> = []
    private(set) var report: PrivacyReport?
    private(set) var protection: ProtectionSnapshot
    private var operationGeneration = UUID()
    private var didRestore = false
    private let protectionService = ProtectionService()
    private let reminders = LocalReminderService()
    private let cleanupPlan: ProtectionCleanupPlan
    private let transport: any ApprovedRequestTransport
    private let appVersion: String
    private let osVersion: String

    init(store: EncryptedReportStore, transport: any ApprovedRequestTransport = ApprovedHTTPTransport(),
         cleanupPlan: ProtectionCleanupPlan = ProtectionCleanupPlan()) {
        self.store = store
        self.transport = transport
        self.cleanupPlan = cleanupPlan
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

    func restore() async throws -> EncryptedWorkspaceSnapshot {
        if !didRestore {
            pendingSystemCleanup = try await cleanupPlan.load()
            if !pendingSystemCleanup.isEmpty {
                // A previous user-requested removal survives deletion of private data.
                try? await retrySystemCleanup()
            }
            if let saved = try await store.loadFeatureState(EnginePreferences.self, key: "preferences") {
                guard saved.version == 1, saved.acceptedFindingKeys.count <= 10_000,
                      saved.ignoredFindingKeys.count <= 10_000, saved.overrides.sorted.count <= 10_000 else {
                    throw ReportStoreError.invalidReport
                }
                try saved.selfHostedConfiguration?.validate()
                try saved.dnsConfiguration?.validate()
                preferences = saved
            }
            consent = try await store.loadFeatureState(ConsentState.self, key: "consent") ?? ConsentState()
            let events = try await store.loadFeatureState([NetworkEvent].self, key: "network-events") ?? []
            await gate.cancelAllRequests()
            gate = ApprovedNetworkGate(consent: consent, appVersion: appVersion, osVersion: osVersion,
                                       ledger: NetworkEventLedger(events: events))
            if let saved = try await store.loadFeatureState(StoredKnowledgeBase.self, key: "knowledge-base") {
                do {
                    knowledgeBase = try KnowledgeBaseVerifier(trustAnchors: KnowledgeBaseResources.trustAnchors).verify(
                        manifestData: saved.manifest, payloadData: saved.payload, appVersion: appVersion,
                        highWaterMark: saved.highWaterMark, restoringCurrent: true)
                } catch {
                    // Never replace a rejected downloaded version with an older bundled version.
                    knowledgeBaseFailure = true
                }
            } else {
                do { knowledgeBase = try KnowledgeBaseResources.loadBundled(appVersion: appVersion) }
                catch { knowledgeBaseFailure = true }
            }
            didRestore = true
        }
        let workspace = try await store.loadWorkspace()
        try await adopt(workspace)
        return workspace
    }

    func importReport(_ value: PrivacyReport, source: Data? = nil) async throws -> EncryptedWorkspaceSnapshot {
        let authorization = try await gate.authorizeFeature(.localImport, scopeIdentity: "local-import-v1")
        guard await gate.validateAuthorization(authorization) else { throw EngineError.consentRequired }
        if source != nil {
            let raw = try await gate.authorizeFeature(.retainEncryptedSource, scopeIdentity: "encrypted-source-v1")
            guard await gate.validateAuthorization(raw) else { throw EngineError.consentRequired }
        }
        let workspace = try await store.appendSession(value, encryptedSource: source)
        try await adopt(workspace)
        return workspace
    }

    func selectReport(_ id: UUID) async throws -> EncryptedWorkspaceSnapshot {
        let workspace = try await store.selectSession(id)
        try await adopt(workspace)
        return workspace
    }

    func showSample() async throws {
        operationGeneration = UUID()
        report = .demo
        try await rebuildAnalysis()
    }

    private func adopt(_ workspace: EncryptedWorkspaceSnapshot) async throws {
        operationGeneration = UUID()
        sessions = workspace.sessions
        report = workspace.selectedReport
        try await rebuildAnalysis()
        var snapshots: [PrivacyReport] = []
        unavailableSessionIDs = []
        for session in sessions {
            do { snapshots.append(try await store.reportSession(session.id)) }
            catch { unavailableSessionIDs.insert(session.id) }
        }
        weeklySummary = WeeklySummaryBuilder.build(reports: snapshots)
        if let current = report,
           let previous = snapshots.filter({ $0.id != current.id && $0.importedAt <= current.importedAt })
                .max(by: { $0.importedAt < $1.importedAt }) {
            comparison = ReportComparator.compare(earlier: previous, later: current)
        } else { comparison = nil }
    }

    func rebuildAnalysis() async throws {
        let previous = analysis
        guard let report else {
            analysis = nil; lifecycle = nil; advisorResult = nil
            try await gate.updateContext(reportIdentity: nil, configurationIdentity: "local-only-v1")
            return
        }
        let reviewed = knowledgeBase.map { DomainMatcher(snapshot: $0).findingContexts(for: report) } ?? []
        let current = VersionedFindingEngine.evaluate(report: report, context: .init(profile: preferences.profile,
            permissionAudit: preferences.permissionAudit, reviewedDomains: reviewed, domainOverrides: preferences.overrides,
            protection: .init(urlFilterAvailable: protection.systemURLFilter.phase != .unavailable,
                urlFilterActive: protection.systemURLFilter.isActive,
                safariBlockerAvailable: protection.safari.phase != .unavailable, safariBlockerActive: protection.safari.isActive)))
        analysis = current
        lifecycle = FindingLifecycle.compare(previous: previous, current: current,
            acceptedKeys: preferences.acceptedFindingKeys, ignoredKeys: preferences.ignoredFindingKeys)
        advisorResult = nil
        try await gate.updateContext(reportIdentity: AdvisorInput.identity(for: current),
            configurationIdentity: preferences.selfHostedConfiguration?.identity ?? "local-only-v1")
    }

    /// This method is invoked only after the user accepts the feature disclosure.
    func grant(_ feature: ConsentFeature, scope: String,
               disclosureVersion: String = ConsentDisclosure.currentVersion) async throws {
        guard feature != .privateCloudCompute else { throw EngineError.unavailable }
        guard !pendingSystemCleanup.contains(feature) else { throw EngineError.unavailable }
        _ = try await gate.grantConsent(feature: feature, disclosureVersion: disclosureVersion, scopeIdentity: scope)
        do { try await persistConsent() }
        catch { try? await gate.revokeConsent(feature); throw error }
    }

    func revoke(_ feature: ConsentFeature) async throws {
        operationGeneration = UUID()
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
            case .retainEncryptedSource: try await adopt(store.removeRetainedSources())
            case .onDeviceAdvisor, .selfHostedAdvisor: advisorResult = nil
            default: break
            }
            pendingSystemCleanup.remove(feature)
            preferences.pendingProtectionRemoval.remove(feature)
            try await cleanupPlan.save(pendingSystemCleanup)
        } catch { removalError = error }
        do {
            try await persistConsent()
            try await store.saveFeatureState(preferences, key: "preferences")
        } catch { removalError = error }
        await refreshProtection()
        if let removalError { throw removalError }
    }

    private func persistConsent() async throws {
        let snapshot = await gate.consentSnapshot()
        consent = snapshot
        try await store.saveFeatureState(snapshot, key: "consent")
    }

    func savePreferences(_ value: EnginePreferences) async throws {
        guard value.version == 1, value.overrides.sorted.count <= 10_000,
              value.acceptedFindingKeys.count <= 10_000, value.ignoredFindingKeys.count <= 10_000 else {
            throw ReportStoreError.invalidReport
        }
        try value.selfHostedConfiguration?.validate()
        try value.dnsConfiguration?.validate()
        operationGeneration = UUID()
        await gate.cancelAllRequests()
        try await store.saveFeatureState(value, key: "preferences")
        preferences = value
        try await rebuildAnalysis()
    }

    func updateRetention(_ value: WorkspaceRetentionPolicy) async throws {
        try await adopt(store.updateRetention(value))
    }

    func deleteReport(_ id: UUID) async throws {
        operationGeneration = UUID()
        await gate.cancelAllRequests()
        try await adopt(store.deleteSession(id))
    }

    func assessLocally() async throws -> AdvisorResult {
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
        guard let analysis else { throw EngineError.noReport }
        guard let configuration = preferences.selfHostedConfiguration else { throw EngineError.missingConfiguration }
        let input = try AdvisorInput.make(analysis: analysis)
        let request = try SelfHostedAdvisor.prepare(input: input, configuration: configuration, bearerToken: bearerToken)
        try await gate.updateContext(reportIdentity: request.reportIdentity, configurationIdentity: request.configurationIdentity)
        return PreparedEngineRequest(request: request, preview: try await gate.preview(request), advisorInput: input)
    }

    func prepareUpdate(endpoint: URL, purpose: NetworkPurpose, operatorRetention: String) async throws -> PreparedEngineRequest {
        guard purpose == .knowledgeBaseUpdate || purpose == .filterListUpdate else { throw EngineError.invalidUpdate }
        let identity = ContentDigest.sha256(Data((purpose.rawValue + "\n" + endpoint.absoluteString + "\n" + operatorRetention).utf8))
        let request = try ApprovedNetworkRequest(purpose: purpose, endpoint: endpoint, method: .get,
            body: Data(), disclosureVersion: ConsentDisclosure.currentVersion, reportIdentity: nil, configurationIdentity: identity,
            payloadFields: [],
            retentionDisclosure: operatorRetention)
        let reportIdentity = try analysis.map { try AdvisorInput.identity(for: $0) }
        try await gate.updateContext(reportIdentity: reportIdentity,
                                     configurationIdentity: identity)
        return PreparedEngineRequest(request: request, preview: try await gate.preview(request), advisorInput: nil)
    }

    /// Called by the explicit send action after the exact preview has been shown.
    func send(_ prepared: PreparedEngineRequest) async throws -> ApprovedNetworkResponse {
        let generation = operationGeneration
        let approval = try await gate.approve(prepared.preview)
        do {
            let response = try await gate.execute(prepared.request, approval: approval, using: transport)
            guard generation == operationGeneration else { throw EngineError.staleOperation }
            if let input = prepared.advisorInput {
                let checked = try SelfHostedAdvisor.decode(response: response, for: input)
                // Rendered text remains authored from evidence; the model supplies order/style only.
                _ = try AdvisorRenderer.explanations(assessment: checked, analysis: try requireAnalysis())
                advisorResult = AdvisorResult(assessment: checked, mode: .selfHosted, fallback: nil)
            } else if prepared.request.purpose == .knowledgeBaseUpdate {
                let download = try JSONDecoder().decode(KnowledgeBaseDownload.self, from: response.body)
                try await installKnowledgeBase(manifest: download.manifest, payload: download.payload)
            } else if prepared.request.purpose == .filterListUpdate {
                let signed = try JSONDecoder().decode(SignedFilterDataset.self, from: response.body)
                _ = try await installFilterDataset(signed)
            }
            try await store.saveFeatureState(await gate.ledger.snapshot(), key: "network-events")
            return response
        } catch {
            if generation == operationGeneration {
                try? await store.saveFeatureState(await gate.ledger.snapshot(), key: "network-events")
            }
            throw error
        }
    }

    func filterDataset(_ kind: FilterPayloadKind) async throws -> ValidatedFilterDataset {
        let key = "filter-" + kind.rawValue.lowercased()
        if let saved = try await store.loadFeatureState(StoredFilterDataset.self, key: key) {
            return try FilterDatasetVerifier.verify(saved.signed, trustedKeys: BundledProtectionDataset.trustedKeys(),
                highestAcceptedVersion: saved.highestVersion)
        }
        guard kind == .safariDomainsV1 else { throw EngineError.missingConfiguration }
        return try BundledProtectionDataset.safariStarter()
    }

    func installFilterDataset(_ signed: SignedFilterDataset) async throws -> ValidatedFilterDataset {
        let key = "filter-" + signed.manifest.kind.rawValue.lowercased()
        let existing = try await store.loadFeatureState(StoredFilterDataset.self, key: key)
        let manifestDigest = ContentDigest.sha256(try signed.manifest.signedRepresentation())
        if let existing, signed.manifest.version == existing.signed.manifest.version,
           manifestDigest != existing.acceptedDigest { throw FilterDatasetError.rollback }
        let minimum = existing?.highestVersion ?? (signed.manifest.kind == .safariDomainsV1 ? 1 : 0)
        let verified = try FilterDatasetVerifier.verify(signed, trustedKeys: BundledProtectionDataset.trustedKeys(),
            highestAcceptedVersion: minimum)
        try await store.saveFeatureState(StoredFilterDataset(signed: signed,
            highestVersion: max(minimum, signed.manifest.version), acceptedDigest: manifestDigest), key: key)
        return verified
    }

    private func requireAnalysis() throws -> FindingAnalysis {
        guard let analysis else { throw EngineError.noReport }; return analysis
    }

    func installKnowledgeBase(manifest: Data, payload: Data) async throws {
        let previous = try await store.loadFeatureState(StoredKnowledgeBase.self, key: "knowledge-base")
        let verified = try KnowledgeBaseVerifier(trustAnchors: KnowledgeBaseResources.trustAnchors).verify(
            manifestData: manifest, payloadData: payload, appVersion: appVersion,
            highWaterMark: previous?.highWaterMark ?? knowledgeBase?.highWaterMark)
        try await store.saveFeatureState(StoredKnowledgeBase(manifest: manifest, payload: payload,
            highWaterMark: verified.highWaterMark), key: "knowledge-base")
        knowledgeBase = verified; knowledgeBaseFailure = false
        operationGeneration = UUID()
        try await rebuildAnalysis()
    }

    func enableSafari(_ dataset: ValidatedFilterDataset) async throws {
        let allowed = preferences.overrides.sorted.filter { $0.disposition == .localAllow }.map { $0.host.value }
        let configuration = try dataset.safariConfiguration(allowedDomains: allowed)
        let authorization = try await gate.authorizeFeature(.safariProtection, scopeIdentity: configuration.scopeIdentity)
        protection.safari = try await protectionService.enableSafari(dataset: dataset, allowedDomains: allowed,
            authorization: authorization, checker: gate)
        try await rebuildAnalysis()
    }

    func enableDNS() async throws {
        guard let configuration = preferences.dnsConfiguration else { throw EngineError.missingConfiguration }
        let authorization = try await gate.authorizeFeature(.encryptedDNS, scopeIdentity: configuration.scopeIdentity)
        protection.encryptedDNS = try await protectionService.enableDNS(configuration: configuration,
            authorization: authorization, checker: gate)
    }

    @available(iOS 26.0, *)
    func enableURLFilter(_ dataset: ValidatedFilterDataset, authenticationToken: String) async throws {
        let identifier = (Bundle.main.bundleIdentifier ?? "") + ".URLFilterControl"
        let configuration = try dataset.urlConfiguration(controlProviderBundleIdentifier: identifier)
        let authorization = try await gate.authorizeFeature(.urlProtection, scopeIdentity: configuration.scopeIdentity)
        protection.systemURLFilter = try await URLFilterService().enable(dataset: dataset,
            authenticationToken: authenticationToken, authorization: authorization, checker: gate)
        try await rebuildAnalysis()
    }

    func enableManaged(_ dataset: ValidatedFilterDataset) async throws {
        let policy = try JSONDecoder().decode(ManagedPolicy.self, from: dataset.payload)
        let authorization = try await gate.authorizeFeature(.managedProtection, scopeIdentity: policy.scopeIdentity)
        protection.managed = try await ManagedProtectionService().enable(dataset: dataset, authorization: authorization, checker: gate)
    }

    func refreshProtection() async {
        protection.safari = await protectionService.safariState()
        protection.encryptedDNS = await protectionService.dnsState(expected: preferences.dnsConfiguration)
        let edition = Bundle.main.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String ?? "consumer"
        if edition == "url-filter", #available(iOS 26.0, *) { protection.systemURLFilter = await URLFilterService().state() }
        if edition == "managed" { protection.managed = await ManagedProtectionService().state() }
    }

    func scheduleReminder(weekday: Int, hour: Int, minute: Int) async throws {
        let authorization = try await gate.authorizeFeature(.localReminders, scopeIdentity: "weekly-local-reminder-v1")
        try await reminders.schedule(weekday: weekday, hour: hour, minute: minute, authorization: authorization, checker: gate)
    }

    func diagnostics() async throws -> Data {
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
        operationGeneration = UUID()
        let activeFeatures = Set(consent.receipts.filter(\.isActive).map(\.feature))
            .union(preferences.pendingProtectionRemoval)
            .union(try await cleanupPlan.load())
        let protectionFeatures: Set<ConsentFeature> = [.safariProtection, .encryptedDNS, .urlProtection, .managedProtection]
        pendingSystemCleanup = activeFeatures.intersection(protectionFeatures)
        // Commit a nonsensitive durable removal plan before destroying its private origin.
        try await cleanupPlan.save(pendingSystemCleanup)
        try await gate.deleteAll()
        await reminders.removeAll()
        var failure: (any Error)?
        do { try await retrySystemCleanup() } catch { failure = error }
        try await store.deleteAll()
        report = nil; sessions = []; preferences = EnginePreferences(); consent = ConsentState()
        knowledgeBase = nil; analysis = nil; lifecycle = nil; advisorResult = nil
        comparison = nil; weeklySummary = nil; didRestore = false
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
