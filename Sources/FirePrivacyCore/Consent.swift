import Foundation

/// Permissions are separate; local report analysis never implies networking consent.
public enum ConsentFeature: String, Codable, CaseIterable, Sendable, Hashable {
    case localImport
    case knowledgeBaseUpdates
    case filterDatasetUpdates
    case selfHostedAdvisor
    case onDeviceAdvisor
    case safariProtection
    case encryptedDNS
    case urlProtection
    case managedProtection
    case diagnosticsExport
    case retainEncryptedSource
    case localReminders
    case privateCloudCompute

    public static let safariContentBlocking = ConsentFeature.safariProtection
    public static let systemURLFiltering = ConsentFeature.urlProtection
    public static let diagnosticExport = ConsentFeature.diagnosticsExport
    public static let localNotifications = ConsentFeature.localReminders
}

public struct ConsentDisclosure: Codable, Equatable, Sendable {
    public static let currentVersion = "fireprivacy-consent/2"
    public let feature: ConsentFeature
    public let version: String
    public let title: String
    public let summary: String
    public let dataDescription: String
    public let destinationDescription: String
    public let retentionDescription: String
    public let declineOutcome: String

    public init(feature: ConsentFeature, version: String = Self.currentVersion,
                title: String, summary: String, dataDescription: String,
                destinationDescription: String, retentionDescription: String,
                declineOutcome: String) {
        self.feature = feature
        self.version = version
        self.title = title
        self.summary = summary
        self.dataDescription = dataDescription
        self.destinationDescription = destinationDescription
        self.retentionDescription = retentionDescription
        self.declineOutcome = declineOutcome
    }
}

public struct ConsentReceipt: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let feature: ConsentFeature
    public let disclosureVersion: String
    public let scopeIdentity: String?
    public let grantedAt: Date
    public private(set) var revokedAt: Date?
    public let appVersion: String
    public let osVersion: String
    public var isActive: Bool { revokedAt == nil }

    init(feature: ConsentFeature, disclosureVersion: String, scopeIdentity: String?,
         grantedAt: Date, appVersion: String, osVersion: String) {
        self.id = UUID()
        self.feature = feature
        self.disclosureVersion = disclosureVersion
        self.scopeIdentity = scopeIdentity
        self.grantedAt = grantedAt
        self.revokedAt = nil
        self.appVersion = appVersion
        self.osVersion = osVersion
    }

    mutating func revoke(at date: Date) {
        if revokedAt == nil { revokedAt = date }
    }
}

public enum ConsentError: Error, Equatable, Sendable {
    case invalidDisclosureVersion
    case invalidScopeIdentity
    case generationExhausted
    case notGranted(ConsentFeature)
}

/// Persist this snapshot only in the app's protected, encrypted private storage.
/// The network gate owns its mutable copy and invalidates approvals on changes.
public struct ConsentState: Codable, Equatable, Sendable {
    public private(set) var receipts: [ConsentReceipt]
    public private(set) var generation: UInt64

    public init(receipts: [ConsentReceipt] = [], generation: UInt64 = 0) {
        self.receipts = receipts
        self.generation = generation
    }

    public func activeReceipt(for feature: ConsentFeature, disclosureVersion: String,
                              scopeIdentity: String?) -> ConsentReceipt? {
        receipts.last {
            $0.feature == feature && $0.isActive &&
            $0.disclosureVersion == disclosureVersion && $0.scopeIdentity == scopeIdentity
        }
    }

    public mutating func grant(_ feature: ConsentFeature, disclosureVersion: String,
                               scopeIdentity: String? = nil, at date: Date,
                               appVersion: String, osVersion: String) throws -> ConsentReceipt {
        guard Self.isBoundedIdentity(disclosureVersion, limit: 120) else {
            throw ConsentError.invalidDisclosureVersion
        }
        if let scopeIdentity, !Self.isBoundedIdentity(scopeIdentity, limit: 256) {
            throw ConsentError.invalidScopeIdentity
        }
        try advanceGeneration()
        for index in receipts.indices where receipts[index].feature == feature {
            receipts[index].revoke(at: date)
        }
        let receipt = ConsentReceipt(feature: feature, disclosureVersion: disclosureVersion,
                                     scopeIdentity: scopeIdentity, grantedAt: date,
                                     appVersion: appVersion, osVersion: osVersion)
        receipts.append(receipt)
        return receipt
    }

    public mutating func revoke(_ feature: ConsentFeature, at date: Date) throws {
        try advanceGeneration()
        for index in receipts.indices where receipts[index].feature == feature {
            receipts[index].revoke(at: date)
        }
    }

    public mutating func revokeAll(at date: Date) throws {
        try advanceGeneration()
        for index in receipts.indices { receipts[index].revoke(at: date) }
    }

    public mutating func deleteAll() throws {
        try advanceGeneration()
        receipts.removeAll()
    }

    mutating func invalidateAuthorizations() throws { try advanceGeneration() }

    private mutating func advanceGeneration() throws {
        guard generation < UInt64.max else { throw ConsentError.generationExhausted }
        generation += 1
    }

    static func isBoundedIdentity(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// A short-lived authority snapshot, created only by the gate, not a UI toggle.
public struct ConsentAuthorization: Sendable, Equatable {
    public let feature: ConsentFeature
    public let receiptID: UUID
    public let generation: UInt64
    public let disclosureVersion: String
    public let scopeIdentity: String?
    init(receipt: ConsentReceipt, generation: UInt64) {
        feature = receipt.feature
        receiptID = receipt.id
        self.generation = generation
        disclosureVersion = receipt.disclosureVersion
        scopeIdentity = receipt.scopeIdentity
    }
}

public protocol ConsentAuthorizationChecking: Sendable {
    func validateAuthorization(_ authorization: ConsentAuthorization) async -> Bool
}
