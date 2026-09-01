import Foundation
import ObservationCore
import ObservationStore
import ProtectionKit
import ConsentKit
import ReportKit

/// A network destination Fire Privacy itself may contact, and why (TRU-005).
///
/// The ledger is written by hand and checked against the binary by the privacy
/// regression suite. Its purpose is that a user can read one screen and know
/// every reason this app would ever open a connection.
public struct NetworkLedgerEntry: Sendable, Hashable, Identifiable {
    public enum Trigger: String, Sendable, Hashable {
        case never
        case userInitiated
        case scheduledWithConsent
    }

    public var id: String { purpose }
    public let purpose: String
    public let destination: String
    public let trigger: Trigger
    public let carriesUserData: Bool
    public let detail: String

    public init(purpose: String, destination: String, trigger: Trigger, carriesUserData: Bool, detail: String) {
        self.purpose = purpose
        self.destination = destination
        self.trigger = trigger
        self.carriesUserData = carriesUserData
        self.detail = detail
    }
}

public enum NetworkLedger {
    /// The complete list for this release. Importing, analyzing, exporting and
    /// deleting make no network request at all (IMP-010).
    public static let entries: [NetworkLedgerEntry] = [
        NetworkLedgerEntry(
            purpose: "Import and analysis",
            destination: "None",
            trigger: .never,
            carriesUserData: false,
            detail: "Reading your report, matching domains, building findings, exporting and deleting all happen on this iPhone with no connection."
        ),
        NetworkLedgerEntry(
            purpose: "Knowledge-base update",
            destination: "Fire Privacy dataset distribution",
            trigger: .scheduledWithConsent,
            carriesUserData: false,
            detail: "Downloads a signed list of domain classifications. The request contains no information about you, your apps or your report. Off unless you turn it on."
        ),
        NetworkLedgerEntry(
            purpose: "Filter list update",
            destination: "Fire Privacy dataset distribution",
            trigger: .scheduledWithConsent,
            carriesUserData: false,
            detail: "Downloads the signed prefilter used by the system URL filter. Only when protection is on."
        ),
        NetworkLedgerEntry(
            purpose: "System URL filter lookups",
            destination: "Fire Privacy lookup service, through Apple's relay",
            trigger: .scheduledWithConsent,
            carriesUserData: false,
            detail: "iOS performs these checks, not Fire Privacy. Fire Privacy does not receive the addresses you request, and the service cannot see which entry was checked."
        ),
        NetworkLedgerEntry(
            purpose: "Your own model endpoint",
            destination: "The host you configured",
            trigger: .userInitiated,
            carriesUserData: true,
            detail: "Only if you set one up. Sends the structured summary you previewed — never your raw report."
        ),
        NetworkLedgerEntry(
            purpose: "Sharing an export",
            destination: "Wherever you send it",
            trigger: .userInitiated,
            carriesUserData: true,
            detail: "Fire Privacy hands the file to the system share sheet. It never uploads anything itself."
        ),
    ]
}

/// What Fire Privacy currently holds and what is switched on (TRU-001).
public struct TrustCenterInventory: Sendable {
    public let sessionCount: Int
    public let observationCount: Int
    public let findingCount: Int
    public let explanationCount: Int
    public let overrideCount: Int
    public let retainedRawFileCount: Int
    public let storageBytes: Int
    public let protection: ProtectionState
    public let activeConsents: [ConsentType]
    public let advisorModeDescription: String
    public let knowledgeBaseVersion: String
    public let knowledgeBaseExpiresAt: Date?
    public let filterDatasetVersion: String?
    public let lastKnowledgeBaseContact: Date?

    public init(
        sessionCount: Int,
        observationCount: Int,
        findingCount: Int,
        explanationCount: Int,
        overrideCount: Int,
        retainedRawFileCount: Int,
        storageBytes: Int,
        protection: ProtectionState,
        activeConsents: [ConsentType],
        advisorModeDescription: String,
        knowledgeBaseVersion: String,
        knowledgeBaseExpiresAt: Date?,
        filterDatasetVersion: String?,
        lastKnowledgeBaseContact: Date?
    ) {
        self.sessionCount = sessionCount
        self.observationCount = observationCount
        self.findingCount = findingCount
        self.explanationCount = explanationCount
        self.overrideCount = overrideCount
        self.retainedRawFileCount = retainedRawFileCount
        self.storageBytes = storageBytes
        self.protection = protection
        self.activeConsents = activeConsents
        self.advisorModeDescription = advisorModeDescription
        self.knowledgeBaseVersion = knowledgeBaseVersion
        self.knowledgeBaseExpiresAt = knowledgeBaseExpiresAt
        self.filterDatasetVersion = filterDatasetVersion
        self.lastKnowledgeBaseContact = lastKnowledgeBaseContact
    }

    /// The plain statement at the top of the Trust Center.
    public var headline: String {
        if sessionCount == 0 {
            return "Fire Privacy is holding nothing from your device."
        }
        return "Fire Privacy is holding \(observationCount) observations from \(sessionCount) import\(sessionCount == 1 ? "" : "s"), on this iPhone only."
    }
}

/// A user-generated diagnostic bundle (§19.2).
///
/// Created only on request, listed file by file before it is shared, and free of
/// raw observations unless the user separately opts to include them.
public struct DiagnosticBundle: Sendable {
    public struct File: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let contents: String
        public let description: String
    }

    public let files: [File]
    public let generatedAt: Date

    public init(files: [File], generatedAt: Date) {
        self.files = files
        self.generatedAt = generatedAt
    }

    public static func make(
        inventory: TrustCenterInventory,
        appVersion: String,
        osVersion: String,
        deviceFamily: String,
        errorCodes: [String],
        localMetrics: [String: String],
        includeFindingIDs: [String],
        generatedAt: Date
    ) -> DiagnosticBundle {
        var manifestLines = [
            "Fire Privacy diagnostic bundle",
            "generated: \(ISO8601DateFormatter().string(from: generatedAt))",
            "app: \(appVersion)",
            "os: \(osVersion)",
            "device family: \(deviceFamily)",
            "",
            "This bundle contains no domains, no bundle identifiers, no notes and no report contents.",
        ]
        if !includeFindingIDs.isEmpty {
            manifestLines.append("It includes \(includeFindingIDs.count) finding identifiers you selected.")
        }

        let state = [
            "url_filter_state: \(inventory.protection.urlFilterState.rawValue)",
            "url_filter_profile: \(inventory.protection.urlFilterProfile?.rawValue ?? "none")",
            "dns_state: \(inventory.protection.dnsState.rawValue)",
            "safari_state: \(inventory.protection.safariExtensionState.rawValue)",
            "managed_state: \(inventory.protection.managedFilterState.rawValue)",
            "knowledge_base: \(inventory.knowledgeBaseVersion)",
            "filter_dataset: \(inventory.filterDatasetVersion ?? "none")",
            "advisor_mode: \(inventory.advisorModeDescription)",
            "sessions: \(inventory.sessionCount)",
            "observations: \(inventory.observationCount)",
            "findings: \(inventory.findingCount)",
        ].joined(separator: "\n")

        var files = [
            File(name: "manifest.txt", contents: manifestLines.joined(separator: "\n"), description: "What this bundle is and what it contains."),
            File(name: "feature-state.txt", contents: state, description: "Which features are on, and which versions are installed."),
            File(name: "error-codes.txt", contents: errorCodes.joined(separator: "\n"), description: "Error codes only — no messages, no identifiers."),
            File(
                name: "local-metrics.txt",
                contents: localMetrics.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
                description: "Durations and counts measured on this device."
            ),
        ]
        if !includeFindingIDs.isEmpty {
            files.append(File(
                name: "finding-ids.txt",
                contents: includeFindingIDs.joined(separator: "\n"),
                description: "The finding identifiers you chose to include."
            ))
        }
        return DiagnosticBundle(files: files, generatedAt: generatedAt)
    }
}
