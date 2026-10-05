import Foundation

/// Closed purposes prevent an arbitrary request from borrowing another feature's consent.
public enum NetworkPurpose: String, Codable, CaseIterable, Sendable, Hashable {
    case knowledgeBaseUpdate
    case filterListUpdate
    case selfHostedAdvisor
    case encryptedDNS
    case systemURLFilterLookup
    case shareExport
    case openPolicyOrSupport

    public var appCreatesRequest: Bool {
        switch self {
        case .knowledgeBaseUpdate, .filterListUpdate, .selfHostedAdvisor: true
        case .encryptedDNS, .systemURLFilterLookup, .shareExport, .openPolicyOrSupport: false
        }
    }

    public var requiredConsent: ConsentFeature? {
        switch self {
        case .knowledgeBaseUpdate: .knowledgeBaseUpdates
        case .filterListUpdate: .filterDatasetUpdates
        case .selfHostedAdvisor: .selfHostedAdvisor
        case .encryptedDNS: .encryptedDNS
        case .systemURLFilterLookup: .systemURLFiltering
        case .shareExport, .openPolicyOrSupport: nil
        }
    }

    public var title: String {
        switch self {
        case .knowledgeBaseUpdate: "Knowledge-base update"
        case .filterListUpdate: "Filter-list update"
        case .selfHostedAdvisor: "Your model endpoint"
        case .encryptedDNS: "Encrypted DNS"
        case .systemURLFilterLookup: "System URL-filter lookup"
        case .shareExport: "Share export"
        case .openPolicyOrSupport: "Open policy or support"
        }
    }

    public var maximumResponseBytes: Int {
        self == .selfHostedAdvisor ? 65_536 : 8_388_608
    }
}

public struct NetworkDisclosure: Codable, Equatable, Sendable, Identifiable {
    public var id: NetworkPurpose { purpose }
    public let purpose: NetworkPurpose
    public let destination: String
    public let payloadDescription: String
    public let connectionMetadataDescription: String
    public let retentionDescription: String
    public let triggerDescription: String
    public let performedBy: String
}

public enum NetworkCatalogue {
    public static let unknownRetention = "The endpoint operator controls retention. Fire Privacy cannot verify its logging, storage, or model-training settings."

    public static func disclosure(for request: ApprovedNetworkRequest) -> NetworkDisclosure {
        NetworkDisclosure(
            purpose: request.purpose, destination: request.endpoint.absoluteString,
            payloadDescription: request.body.isEmpty
                ? "This request has no body and includes no report, app identifiers, domains, or notes in a payload. Configured authentication and connection metadata still reach the destination."
                : "The exact structured payload shown in the request preview is sent. Fields: \(request.payloadFields.joined(separator: ", ")). Review the complete payload before sending.",
            connectionMetadataDescription: "The destination receives connection metadata such as the network address and request timing. Authentication is included only when you configured it.",
            retentionDescription: request.retentionDisclosure,
            triggerDescription: "Only after current feature consent and approval of this exact request.",
            performedBy: "Fire Privacy"
        )
    }

    public static func encryptedDNS(resolver: String, operatorName: String,
                                    retention: String = unknownRetention) -> NetworkDisclosure {
        NetworkDisclosure(
            purpose: .encryptedDNS, destination: resolver,
            payloadDescription: "DNS query names leave the device and are processed by \(operatorName). Encryption protects the connection; the resolver can read the queried names. Imported reports are not sent.",
            connectionMetadataDescription: "The resolver can receive network addresses and query timing. Coverage depends on the system configuration and each app's resolver.",
            retentionDescription: retention,
            triggerDescription: "After separate consent and enabling the DNS configuration in Settings.",
            performedBy: "iOS or iPadOS"
        )
    }

    public static func systemURLFilter(service: String,
                                       retention: String = unknownRetention) -> NetworkDisclosure {
        NetworkDisclosure(
            purpose: .systemURLFilterLookup, destination: service,
            payloadDescription: "The system uses the configured private lookup service. Fire Privacy does not receive the browsing URL through this API. Coverage is limited to participating networking APIs.",
            connectionMetadataDescription: "Relay and service operators have their own connection-metadata handling; their verified configuration and policies determine the privacy guarantees.",
            retentionDescription: retention,
            triggerDescription: "While the system confirms the separately authorized URL filter is running.",
            performedBy: "iOS or iPadOS"
        )
    }
}

public enum NetworkEventPhase: String, Codable, Sendable {
    case started
    case completed
    case denied
    case cancelled
    case failed
}

/// No URL path/query, header, report identifier, payload, server error text, or model text.
public struct NetworkEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let purpose: NetworkPurpose
    public let host: String
    public let occurredAt: Date
    public let phase: NetworkEventPhase
    public let requestByteCount: Int
    public let responseByteCount: Int?
    public let statusCode: Int?

    public init(operationID: UUID, purpose: NetworkPurpose, host: String,
                occurredAt: Date, phase: NetworkEventPhase, requestByteCount: Int,
                responseByteCount: Int? = nil, statusCode: Int? = nil) {
        id = UUID()
        self.operationID = operationID
        self.purpose = purpose
        self.host = host
        self.occurredAt = occurredAt
        self.phase = phase
        self.requestByteCount = requestByteCount
        self.responseByteCount = responseByteCount
        self.statusCode = statusCode
    }
}

/// Local, bounded inventory. It is never uploaded automatically or used as telemetry.
public actor NetworkEventLedger {
    private var events: [NetworkEvent]
    private let capacity: Int
    private var generation = UUID()
    public init(events: [NetworkEvent] = [], capacity: Int = 200) {
        self.capacity = max(1, min(capacity, 1_000))
        self.events = Array(events.suffix(self.capacity))
    }
    public func currentGeneration() -> UUID { generation }
    public func record(_ event: NetworkEvent, generation: UUID? = nil) {
        if let generation, generation != self.generation { return }
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }
    public func snapshot() -> [NetworkEvent] { events }
    public func deleteAll() { generation = UUID(); events.removeAll() }
}
