import Foundation
import SwiftUI
import FirePrivacyCore

struct AppNotice: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

struct SharedReport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json, csv, markdown
    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var report: PrivacyReport?
    @Published private(set) var isDemo = false
    @Published private(set) var hasSavedReport = false
    @Published private(set) var savedReportUnavailable = false
    @Published private(set) var isWorking = false
    @Published private(set) var workingMessage = ""
    @Published var showImporter = false
    @Published var showReplaceConfirmation = false
    @Published var notice: AppNotice?
    @Published var sharedReport: SharedReport?
    @Published private(set) var analysis: FindingAnalysis?
    @Published private(set) var sessions: [ReportSessionDescriptor] = []
    @Published private(set) var comparison: ReportComparison?
    @Published private(set) var weeklySummary: LocalWeeklySummary?
    @Published private(set) var preferences = EnginePreferences()
    @Published private(set) var consent = ConsentState()
    @Published private(set) var protection: ProtectionSnapshot
    @Published private(set) var advisorResult: AdvisorResult?
    @Published private(set) var networkEvents: [NetworkEvent] = []
    @Published private(set) var knowledgeBaseVersion: String?
    @Published private(set) var knowledgeBaseFailure = false
    @Published private(set) var pendingSystemCleanup: Set<ConsentFeature> = []
    @Published private(set) var unavailableSessionIDs: Set<UUID> = []
    @Published private(set) var keyRotationStatus = ReportKeyRotationStatus.idle
    @Published var retainEncryptedSourceForNextImport = false

    private let store: EncryptedReportStore
    let engine: FirePrivacyEngine
    private var didLoad = false
    private var pendingOpenedFile: URL?
    private var deferredOpenedFile: URL?

    init(store: EncryptedReportStore = EncryptedReportStore()) {
        self.store = store
        engine = FirePrivacyEngine(store: store)
        protection = engine.protection
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        beginWork("Opening your report")
        defer { finishWork() }
        do {
            try await Task.detached { try ReportFileIO.removeAllExportFiles() }.value
        } catch {
            notice = AppNotice(title: "Temporary export needs attention", message: "A temporary export could not be removed. You can retry by deleting app data in Settings.\n\n" + error.localizedDescription)
        }
        await readSavedReport()
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            await loadDemo()
        }
    }

    func restoreSavedReport() async {
        guard !isWorking else { return }
        beginWork("Opening your report")
        defer { finishWork() }
        await readSavedReport()
    }

    private func readSavedReport() async {
        do {
            _ = try await engine.restore()
            await syncEngine()
            hasSavedReport = !sessions.isEmpty
            savedReportUnavailable = false
            isDemo = false
        } catch {
            hasSavedReport = true
            savedReportUnavailable = true
            notice = AppNotice(title: "Report unavailable", message: "Your saved report could not be opened. Nothing was replaced. Unlock your device and try again. If this continues, you can delete the app’s saved data in Settings.\n\n" + error.localizedDescription)
        }
    }

    func requestImport() {
        guard !isWorking else { return }
        pendingOpenedFile = nil
        if hasSavedReport {
            showReplaceConfirmation = true
        } else {
            showImporter = true
        }
    }

    func confirmImport() {
        if let pendingOpenedFile {
            self.pendingOpenedFile = nil
            Task { await importReport(from: pendingOpenedFile) }
        } else {
            showImporter = true
        }
    }

    func openDocument(_ url: URL) {
        guard url.isFileURL else { return }
        if !didLoad || isWorking {
            deferredOpenedFile = url
            return
        }
        if hasSavedReport {
            pendingOpenedFile = url
            showReplaceConfirmation = true
        } else {
            Task { await importReport(from: url) }
        }
    }

    func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            await importReport(from: url)
        case .failure(let error):
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            notice = AppNotice(title: "File could not be opened", message: error.localizedDescription)
        }
    }

    private func importReport(from url: URL) async {
        guard !isWorking else { return }
        beginWork("Reading your report on this device")
        defer { finishWork() }
        do {
            let retainSource = retainEncryptedSourceForNextImport
            let imported = try await Task.detached(priority: .userInitiated) {
                let bytes = try ReportFileIO.readImportedData(from: url)
                return (try ReportImporter.parse(bytes, sourceFilename: url.lastPathComponent), retainSource ? bytes : nil)
            }.value
            // Selecting a Files document explicitly authorizes the disclosed local import.
            try await engine.grant(.localImport, scope: "local-import-v1")
            _ = try await engine.importReport(imported.0, source: imported.1)
            await syncEngine()
            isDemo = false
            hasSavedReport = true
            savedReportUnavailable = false
        } catch {
            notice = AppNotice(title: "Report was not imported", message: "The current report was kept.\n\n" + error.localizedDescription)
        }
    }

    func showDemo() {
        guard !isWorking else { return }
        Task { await loadDemo() }
    }

    private func loadDemo() async {
        do {
            try await engine.showSample()
            await syncEngine()
            isDemo = true
        } catch { showFailure("Sample could not be opened", error) }
    }

    func selectReport(_ id: UUID) async {
        guard !isWorking else { return }
        beginWork("Opening encrypted history")
        defer { finishWork() }
        do {
            _ = try await engine.selectReport(id)
            await syncEngine()
            isDemo = false
        } catch { showFailure("Report unavailable", error) }
    }

    func savePreferences(_ value: EnginePreferences) async {
        do { try await engine.savePreferences(value); await syncEngine() }
        catch { showFailure("Preference was not saved", error) }
    }

    func grantFeature(_ feature: ConsentFeature, scope: String,
                      disclosureVersion: String = ConsentDisclosure.currentVersion) async -> Bool {
        do {
            try await engine.grant(feature, scope: scope, disclosureVersion: disclosureVersion)
            await syncEngine()
            return true
        } catch { showFailure("Consent could not be saved", error); return false }
    }

    func revokeFeature(_ feature: ConsentFeature) async {
        do { try await engine.revoke(feature); await syncEngine() }
        catch { await syncEngine(); showFailure("Removal needs attention", error) }
    }

    func refreshProtection() async {
        await engine.refreshProtection()
        do { try await engine.rebuildAnalysis() } catch { showFailure("Analysis unavailable", error) }
        await syncEngine()
    }

    func assessLocally() async {
        beginWork("Preparing evidence-backed guidance")
        defer { finishWork() }
        do { _ = try await engine.assessLocally(); await syncEngine() }
        catch { showFailure("Advisor unavailable", error) }
    }

    private func performFeatureAction(_ message: String, action: () async throws -> Void) async {
        guard !isWorking else { return }
        beginWork(message)
        defer { finishWork() }
        do { try await action(); await syncEngine() }
        catch { await syncEngine(); showFailure("Action needs attention", error) }
    }

    func updateRetention(_ policy: WorkspaceRetentionPolicy) async {
        await performFeatureAction("Updating encrypted history") { try await engine.updateRetention(policy) }
    }

    func deleteReport(_ id: UUID) async {
        await performFeatureAction("Deleting this report") { try await engine.deleteReport(id) }
    }

    func rotateEncryptionKey() async {
        await performFeatureAction("Rotating the encryption key") { try await engine.rotateEncryptionKey() }
    }

    func retryStorageCleanup() async {
        await performFeatureAction("Finishing storage cleanup") { try await engine.retryStorageCleanup() }
    }

    func retrySystemCleanup() async {
        await performFeatureAction("Removing system protection") { try await engine.retrySystemCleanup() }
    }

    func scheduleReminder(weekday: Int, hour: Int, minute: Int) async {
        await performFeatureAction("Scheduling a local reminder") {
            try await engine.scheduleReminder(weekday: weekday, hour: hour, minute: minute)
        }
    }

    func prepareSelfHostedAssessment(bearerToken: String? = nil) async -> PreparedEngineRequest? {
        do { return try await engine.prepareSelfHostedAssessment(bearerToken: bearerToken) }
        catch { showFailure("Preview unavailable", error); return nil }
    }

    func prepareUpdate(endpoint: URL, purpose: NetworkPurpose, operatorRetention: String) async -> PreparedEngineRequest? {
        do { return try await engine.prepareUpdate(endpoint: endpoint, purpose: purpose, operatorRetention: operatorRetention) }
        catch { showFailure("Preview unavailable", error); return nil }
    }

    @discardableResult
    func sendPreparedRequest(_ prepared: PreparedEngineRequest) async -> Bool {
        guard !isWorking else { return false }
        beginWork("Sending your approved request")
        defer { finishWork() }
        do { _ = try await engine.send(prepared); await syncEngine(); return true }
        catch { await syncEngine(); showFailure("Request was not completed", error); return false }
    }

    func enableSafari(_ dataset: ValidatedFilterDataset) async {
        await performFeatureAction("Installing verified Safari rules") { try await engine.enableSafari(dataset) }
    }

    func enableDNS() async {
        await performFeatureAction("Installing your DNS configuration") { try await engine.enableDNS() }
    }

    @available(iOS 26.0, *)
    func enableURLFilter(_ dataset: ValidatedFilterDataset, authenticationToken: String) async {
        await performFeatureAction("Configuring private URL filtering") {
            try await engine.enableURLFilter(dataset, authenticationToken: authenticationToken)
        }
    }

    func enableManaged(_ dataset: ValidatedFilterDataset) async {
        await performFeatureAction("Configuring managed protection") { try await engine.enableManaged(dataset) }
    }

    func syncEngine() async {
        report = engine.report
        analysis = engine.analysis
        sessions = engine.sessions
        comparison = engine.comparison
        weeklySummary = engine.weeklySummary
        preferences = engine.preferences
        consent = engine.consent
        protection = engine.protection
        advisorResult = engine.advisorResult
        networkEvents = await engine.gate.ledger.snapshot()
        knowledgeBaseVersion = engine.knowledgeBase?.version
        knowledgeBaseFailure = engine.knowledgeBaseFailure
        pendingSystemCleanup = engine.pendingSystemCleanup
        unavailableSessionIDs = engine.unavailableSessionIDs
        do { keyRotationStatus = try await store.rotationStatus() }
        catch { showFailure("Storage status unavailable", error) }
        hasSavedReport = !sessions.isEmpty
    }

    private func showFailure(_ title: String, _ error: any Error) {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }

    func prepareExport(format: ExportFormat = .json, options: ReportExportOptions = .full) async {
        guard !isWorking, let report else { return }
        beginWork("Preparing your export")
        defer { finishWork() }
        let analysis = self.analysis
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let data: Data
                switch format {
                case .json: data = try ReportExporter.json(report: report, analysis: analysis, options: options)
                case .csv: data = ReportExporter.csv(report: report, options: options)
                case .markdown: data = ReportExporter.markdown(report: report, analysis: analysis, options: options)
                }
                return try ReportFileIO.makeExportFile(data: data, fileExtension: format.fileExtension)
            }.value
            sharedReport = SharedReport(url: url)
        } catch {
            notice = AppNotice(title: "Export could not be prepared", message: error.localizedDescription)
        }
    }

    func prepareDiagnostics() async {
        guard !isWorking else { return }
        beginWork("Preparing sanitized diagnostics")
        defer { finishWork() }
        do {
            let data = try await engine.diagnostics()
            sharedReport = SharedReport(url: try ReportFileIO.makeExportFile(data: data, fileExtension: "json"))
        } catch { showFailure("Diagnostics unavailable", error) }
    }

    func removeExport(_ url: URL) async {
        if sharedReport?.url == url { sharedReport = nil }
        do {
            try await Task.detached {
                try ReportFileIO.removeExportFile(at: url)
            }.value
        } catch {
            notice = AppNotice(title: "Temporary export could not be removed", message: "The temporary copy remains in this app’s protected storage. Try exporting again and closing the share sheet, or delete all app data.\n\n" + error.localizedDescription)
        }
    }

    func deleteAll() async {
        guard !isWorking else { return }
        beginWork("Deleting saved data")
        defer { finishWork() }
        do {
            if let sharedReport {
                try ReportFileIO.removeExportFile(at: sharedReport.url)
                self.sharedReport = nil
            }
            try await engine.deleteAll()
            await syncEngine()
            report = nil
            isDemo = false
            hasSavedReport = false
            savedReportUnavailable = false
            notice = nil
        } catch {
            // A partial storage failure is visible; do not claim complete deletion.
            await syncEngine()
            hasSavedReport = !sessions.isEmpty
            isDemo = report?.metadata?.isSyntheticDemo == true
            savedReportUnavailable = true
            notice = AppNotice(title: "Deletion needs attention", message: "Deletion did not finish. Try again after unlocking your device.\n\n" + error.localizedDescription)
        }
    }

    private func beginWork(_ message: String) {
        workingMessage = message
        isWorking = true
    }

    private func finishWork() {
        isWorking = false
        workingMessage = ""
        if let deferredOpenedFile {
            self.deferredOpenedFile = nil
            openDocument(deferredOpenedFile)
        }
    }
}
