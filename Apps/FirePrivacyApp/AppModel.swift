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

    private let store: EncryptedReportStore
    private var didLoad = false
    private var pendingOpenedFile: URL?
    private var deferredOpenedFile: URL?

    init(store: EncryptedReportStore = EncryptedReportStore()) {
        self.store = store
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            try await Task.detached { try ReportFileIO.removeAllExportFiles() }.value
        } catch {
            notice = AppNotice(title: "Temporary export needs attention", message: "A temporary export could not be removed. You can retry by deleting app data in Settings.\n\n" + error.localizedDescription)
        }
        await restoreSavedReport()
        if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo() }
    }

    func restoreSavedReport() async {
        guard !isWorking else { return }
        beginWork("Opening your report")
        defer { finishWork() }
        do {
            report = try await store.load()
            hasSavedReport = report != nil
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
            let imported = try await Task.detached(priority: .userInitiated) {
                let bytes = try ReportFileIO.readImportedData(from: url)
                return try ReportImporter.parse(bytes)
            }.value
            // Publish only after the encrypted replacement has been saved successfully.
            try await store.save(imported)
            report = imported
            isDemo = false
            hasSavedReport = true
            savedReportUnavailable = false
        } catch {
            notice = AppNotice(title: "Report was not imported", message: "The current report was kept.\n\n" + error.localizedDescription)
        }
    }

    func showDemo() {
        guard !isWorking else { return }
        report = .demo
        isDemo = true
    }

    func prepareExport() async {
        guard !isWorking, let report else { return }
        beginWork("Preparing your export")
        defer { finishWork() }
        let isSyntheticDemo = isDemo
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ReportFileIO.makeExportFile(for: report, isSyntheticDemo: isSyntheticDemo)
            }.value
            sharedReport = SharedReport(url: url)
        } catch {
            notice = AppNotice(title: "Export could not be prepared", message: error.localizedDescription)
        }
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
            try await store.deleteAll()
            report = nil
            isDemo = false
            hasSavedReport = false
            savedReportUnavailable = false
        } catch {
            // A partial storage failure is visible; do not claim complete deletion.
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
