import Foundation
import ObservationCore

/// Each thing the user can separately agree to (§9.2).
///
/// Consent is unbundled by construction: there is no "accept all" value, so a
/// yes to importing a report cannot become a yes to a model or a network
/// configuration (ONB-003).
public enum ConsentType: String, Codable, Sendable, Hashable, CaseIterable {
    case localReportImport
    case keepEncryptedSourceFile
    case urlFilterInstallation
    case encryptedDNS
    case safariContentBlocker
    case onDeviceAI
    case privateCloudCompute
    case localModelEndpoint
    case diagnosticsExport
    case localNotifications
    case knowledgeBaseUpdates

    public var displayName: String {
        switch self {
        case .localReportImport: "Analyze a report on this iPhone"
        case .keepEncryptedSourceFile: "Keep an encrypted copy of the imported file"
        case .urlFilterInstallation: "Install the system URL filter"
        case .encryptedDNS: "Configure encrypted DNS"
        case .safariContentBlocker: "Turn on Safari content blocking"
        case .onDeviceAI: "Use Apple's on-device model for explanations"
        case .privateCloudCompute: "Use Apple Private Cloud Compute for explanations"
        case .localModelEndpoint: "Use a model endpoint you operate"
        case .diagnosticsExport: "Create a diagnostic bundle"
        case .localNotifications: "Send local reminders"
        case .knowledgeBaseUpdates: "Download knowledge-base updates"
        }
    }

    /// True when granting this causes data to leave the device.
    public var involvesDataLeavingDevice: Bool {
        switch self {
        case .privateCloudCompute, .localModelEndpoint, .diagnosticsExport: true
        case .knowledgeBaseUpdates: true // a request is made, though it carries no user data
        default: false
        }
    }

    /// Required for the app's core purpose. Only report import qualifies, and
    /// even that is optional: the demo works without it.
    public var isOptional: Bool { true }
}

/// Proof of what the user agreed to and when (ONB-006).
public struct ConsentReceipt: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(type.rawValue)|\(disclosureVersion)|\(Int(grantedAt.timeIntervalSince1970))" }
    public let type: ConsentType
    public let disclosureVersion: String
    public let grantedAt: Date
    public var revokedAt: Date?
    public let appVersion: String
    public let osVersion: String

    public init(
        type: ConsentType,
        disclosureVersion: String,
        grantedAt: Date,
        revokedAt: Date? = nil,
        appVersion: String,
        osVersion: String
    ) {
        self.type = type
        self.disclosureVersion = disclosureVersion
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
    }

    public var isActive: Bool { revokedAt == nil }
}

/// Versioned disclosure text. A change in wording changes the version, which
/// invalidates prior consent for that feature.
public struct Disclosure: Sendable, Hashable {
    public let type: ConsentType
    public let version: String
    public let title: String
    public let summary: String
    public let bullets: [String]
    /// What happens if the user says no. Never a dark pattern: saying no must
    /// always be a described, workable outcome.
    public let declineOutcome: String

    public init(type: ConsentType, version: String, title: String, summary: String, bullets: [String], declineOutcome: String) {
        self.type = type
        self.version = version
        self.title = title
        self.summary = summary
        self.bullets = bullets
        self.declineOutcome = declineOutcome
    }
}

/// Records and revokes consent. Receipts stay on the device unless the user
/// includes them in an export (ONB-006).
public actor ConsentStore {
    private var receipts: [ConsentReceipt]
    private let appVersion: String
    private let osVersion: String
    private let clock: @Sendable () -> Date

    public init(
        receipts: [ConsentReceipt] = [],
        appVersion: String,
        osVersion: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.receipts = receipts
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.clock = clock
    }

    public func grant(_ type: ConsentType, disclosureVersion: String) -> ConsentReceipt {
        revoke(type)
        let receipt = ConsentReceipt(
            type: type,
            disclosureVersion: disclosureVersion,
            grantedAt: clock(),
            appVersion: appVersion,
            osVersion: osVersion
        )
        receipts.append(receipt)
        return receipt
    }

    public func revoke(_ type: ConsentType) {
        let now = clock()
        receipts = receipts.map { receipt in
            guard receipt.type == type, receipt.isActive else { return receipt }
            var updated = receipt
            updated.revokedAt = now
            return updated
        }
    }

    /// True only for a currently-active grant of the *current* disclosure
    /// version: re-worded disclosures require asking again.
    public func hasActiveConsent(for type: ConsentType, disclosureVersion: String) -> Bool {
        receipts.contains { $0.type == type && $0.isActive && $0.disclosureVersion == disclosureVersion }
    }

    public func activeConsents() -> [ConsentType] {
        Array(Set(receipts.filter(\.isActive).map(\.type))).sorted { $0.rawValue < $1.rawValue }
    }

    public func allReceipts() -> [ConsentReceipt] {
        receipts.sorted { $0.grantedAt < $1.grantedAt }
    }

    public func deleteAll() {
        receipts.removeAll()
    }
}

/// The disclosures shipped with this release.
public enum DisclosureCatalog {
    public static let version = "disclosure-1.0.0"

    public static let localReportImport = Disclosure(
        type: .localReportImport,
        version: version,
        title: "Analyzing your report stays on this iPhone",
        summary: "You choose a file you exported from Settings. Fire Privacy reads it here and keeps the results here.",
        bullets: [
            "No account, no sign-in, no upload.",
            "The file you picked is not modified and not copied unless you ask.",
            "Results, findings and notes are stored encrypted on this device.",
            "You can delete everything in one action at any time.",
        ],
        declineOutcome: "You can still explore the demo report and read what Fire Privacy can and cannot see."
    )

    public static let onDeviceAI = Disclosure(
        type: .onDeviceAI,
        version: version,
        title: "Plain-language explanations, generated on this iPhone",
        summary: "Apple's on-device model rewrites a finding in plainer words. The finding itself is decided by Fire Privacy's rules, not by the model.",
        bullets: [
            "The model runs on this iPhone. Nothing is sent anywhere.",
            "It receives a short structured summary, never your raw report.",
            "Anything it writes is checked against the finding before you see it.",
            "Turning this off changes wording only. No detection is lost.",
        ],
        declineOutcome: "Explanations are assembled from the finding itself, which works offline and on every device."
    )

    public static let urlFilter = Disclosure(
        type: .urlFilterInstallation,
        version: version,
        title: "Let iOS block known tracking destinations",
        summary: "iOS checks requests against Fire Privacy's list. Fire Privacy does not receive the addresses you request.",
        bullets: [
            "The check happens in iOS, using Apple's privacy-preserving lookup.",
            "If a check cannot complete, the request is allowed rather than blocked.",
            "Coverage depends on how each app makes its requests.",
            "You can pause or remove protection at any time, including from Settings.",
        ],
        declineOutcome: "Nothing changes on your device. Analysis and guidance work exactly the same."
    )

    public static let privateCloudCompute = Disclosure(
        type: .privateCloudCompute,
        version: version,
        title: "Server-side processing on Apple's Private Cloud Compute",
        summary: "This sends the structured summary of a finding to Apple's Private Cloud Compute. It is server-side processing, not on-device processing.",
        bullets: [
            "This is not on-device processing, and Fire Privacy will not describe it as such.",
            "Only the structured summary is sent — never your raw report.",
            "You choose it explicitly each time it is turned on.",
            "It is unavailable until Apple ships the feature in a production release.",
        ],
        declineOutcome: "The on-device model or the deterministic explanation is used instead."
    )

    public static let localModelEndpoint = Disclosure(
        type: .localModelEndpoint,
        version: version,
        title: "Send summaries to a model you run yourself",
        summary: "Fire Privacy can send the structured summary of a finding to a machine you operate, such as a model server on your own network.",
        bullets: [
            "You choose the host, and you approve its certificate.",
            "You see the exact fields that will leave this iPhone before anything is sent.",
            "There is no automatic fallback to any public cloud service.",
            "Your raw report is never sent in this release.",
        ],
        declineOutcome: "Explanations continue to be produced on this iPhone."
    )

    public static let all: [Disclosure] = [
        localReportImport, onDeviceAI, urlFilter, privateCloudCompute, localModelEndpoint,
    ]

    public static func disclosure(for type: ConsentType) -> Disclosure? {
        all.first { $0.type == type }
    }
}
