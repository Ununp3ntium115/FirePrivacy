import Foundation

public enum NetworkHTTPMethod: String, Codable, Sendable { case get = "GET", post = "POST" }

public enum ApprovedNetworkError: Error, Equatable, Sendable {
    case undeclaredPurpose
    case insecureOrInvalidEndpoint
    case invalidCertificatePin
    case invalidAuthentication
    case invalidRequestBody
    case invalidDisclosure
    case contextMismatch
    case consentRequired
    case approvalExpired
    case approvalInvalidOrConsumed
    case cancelled
    case responseTooLarge
    case httpStatus(Int)
    case untrustedServer
    case unexpectedResponse
}

/// Immutable bytes and destination. Creating this value does not open a connection.
public struct ApprovedNetworkRequest: Sendable, Equatable {
    public let purpose: NetworkPurpose
    public let endpoint: URL
    public let method: NetworkHTTPMethod
    public let body: Data
    public let disclosureVersion: String
    public let reportIdentity: String?
    public let configurationIdentity: String
    public let payloadFields: [String]
    public let retentionDisclosure: String
    public let certificateSHA256: String?
    /// Never persisted in a preview or event ledger. Store endpoint secrets in Keychain.
    public let bearerToken: String?

    public init(purpose: NetworkPurpose, endpoint: URL, method: NetworkHTTPMethod = .post,
                body: Data, disclosureVersion: String, reportIdentity: String?,
                configurationIdentity: String, payloadFields: [String], retentionDisclosure: String,
                certificateSHA256: String? = nil, bearerToken: String? = nil) throws {
        guard purpose.appCreatesRequest else { throw ApprovedNetworkError.undeclaredPurpose }
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host,
              !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, components.query == nil,
              (components.port == nil || (1...65_535).contains(components.port!)),
              endpoint.absoluteString.utf8.count <= 2_048 else {
            throw ApprovedNetworkError.insecureOrInvalidEndpoint
        }
        if let certificateSHA256 {
            guard certificateSHA256.utf8.count == 64,
                  certificateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw ApprovedNetworkError.invalidCertificatePin
            }
        }
        if let bearerToken {
            guard !bearerToken.isEmpty, bearerToken.utf8.count <= 8_192,
                  bearerToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ApprovedNetworkError.invalidAuthentication
            }
        }
        guard body.count <= 262_144, String(data: body, encoding: .utf8) != nil else {
            throw ApprovedNetworkError.invalidRequestBody
        }
        switch purpose {
        case .knowledgeBaseUpdate, .filterListUpdate:
            guard method == .get && body.isEmpty && reportIdentity == nil && payloadFields.isEmpty else {
                throw ApprovedNetworkError.invalidRequestBody
            }
        case .selfHostedAdvisor:
            guard method == .post && !body.isEmpty && reportIdentity != nil && !payloadFields.isEmpty,
                  (try? JSONSerialization.jsonObject(with: body)) != nil else {
                throw ApprovedNetworkError.invalidRequestBody
            }
        default: throw ApprovedNetworkError.undeclaredPurpose
        }
        guard ConsentState.isBoundedIdentity(disclosureVersion, limit: 120),
              ConsentState.isBoundedIdentity(configurationIdentity, limit: 256),
              reportIdentity.map({ ConsentState.isBoundedIdentity($0, limit: 256) }) ?? true,
              ConsentState.isBoundedIdentity(retentionDisclosure, limit: 2_000),
              payloadFields.count <= 64,
              payloadFields.allSatisfy({ ConsentState.isBoundedIdentity($0, limit: 120) }) else {
            throw ApprovedNetworkError.invalidDisclosure
        }
        self.purpose = purpose
        self.endpoint = endpoint
        self.method = method
        self.body = body
        self.disclosureVersion = disclosureVersion
        self.reportIdentity = reportIdentity
        self.configurationIdentity = configurationIdentity
        self.payloadFields = payloadFields
        self.retentionDisclosure = retentionDisclosure
        self.certificateSHA256 = certificateSHA256?.lowercased()
        self.bearerToken = bearerToken
    }

    var fingerprint: String {
        // Length-prefixed components prevent ambiguous concatenation. The bearer value
        // is represented only by its digest; it never enters display/logging fields.
        let components = [purpose.rawValue, endpoint.absoluteString, method.rawValue,
                          ContentDigest.sha256(body), disclosureVersion,
                          reportIdentity ?? "", configurationIdentity,
                          certificateSHA256 ?? "", bearerToken.map { ContentDigest.sha256(Data($0.utf8)) } ?? "",
                          retentionDisclosure] + payloadFields
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        return ContentDigest.sha256(Data(framed.utf8))
    }
}

public struct NetworkRequestPreview: Sendable, Equatable {
    public let id: UUID
    public let disclosure: NetworkDisclosure
    public let payloadUTF8: String
    public let payloadSHA256: String
    public let certificateSHA256: String?
    public let authenticationDescription: String
    public let reportIdentity: String?
    public let configurationIdentity: String
    public let disclosureVersion: String
    let fingerprint: String
    let generation: UInt64
    let createdAt: Date
}

public struct NetworkApproval: Sendable, Equatable {
    public let id: UUID
    public let expiresAt: Date
    let previewID: UUID
    let fingerprint: String
    let generation: UInt64
}

public struct ApprovedNetworkResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data
    public let contentType: String?
    public init(statusCode: Int, body: Data, contentType: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }
}

/// Constructible only inside the core gate; the native worker also consumes it once.
public struct NetworkTransmissionPermit: Sendable, Equatable {
    public let id: UUID
    public let expiresAt: Date
    let fingerprint: String
    init(approval: NetworkApproval) {
        id = approval.id
        expiresAt = approval.expiresAt
        fingerprint = approval.fingerprint
    }
    public func authorizes(_ request: ApprovedNetworkRequest, at date: Date = Date()) -> Bool {
        date < expiresAt && fingerprint == request.fingerprint
    }
}

public protocol ApprovedRequestTransport: Sendable {
    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse
}

/// All app-created requests pass through this actor. Revoking consent, changing a
/// report/configuration, or cancelling a request invalidates its one-use authority.
public actor ApprovedNetworkGate: ConsentAuthorizationChecking {
    private var consent: ConsentState
    private var reportIdentity: String?
    private var configurationIdentity: String
    private var previews: [UUID: NetworkRequestPreview] = [:]
    private var approvals: [UUID: NetworkApproval] = [:]
    private var inFlight: [UUID: Task<ApprovedNetworkResponse, Error>] = [:]
    private var activeOperations: Set<UUID> = []
    private var cancelledOperations: Set<UUID> = []
    private let clock: @Sendable () -> Date
    private let appVersion: String
    private let osVersion: String
    public let ledger: NetworkEventLedger

    public init(consent: ConsentState = ConsentState(), reportIdentity: String? = nil,
                configurationIdentity: String = "configuration-1", appVersion: String = "1.0",
                osVersion: String = "unknown", ledger: NetworkEventLedger = NetworkEventLedger(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.consent = consent
        self.reportIdentity = reportIdentity
        self.configurationIdentity = configurationIdentity
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.ledger = ledger
        self.clock = clock
    }

    public func grantConsent(feature: ConsentFeature,
                             disclosureVersion: String = ConsentDisclosure.currentVersion,
                             scopeIdentity: String? = nil) throws -> ConsentReceipt {
        let receipt = try consent.grant(feature, disclosureVersion: disclosureVersion,
                                        scopeIdentity: scopeIdentity ?? configurationIdentity,
                                        at: clock(), appVersion: appVersion, osVersion: osVersion)
        invalidatePending()
        return receipt
    }

    public func revokeConsent(_ feature: ConsentFeature) throws {
        try consent.revoke(feature, at: clock())
        invalidatePending()
    }

    public func revokeAllConsent() throws {
        try consent.revokeAll(at: clock())
        invalidatePending()
    }

    public func consentSnapshot() -> ConsentState { consent }

    public func updateContext(reportIdentity: String?, configurationIdentity: String) throws {
        guard ConsentState.isBoundedIdentity(configurationIdentity, limit: 256),
              reportIdentity.map({ ConsentState.isBoundedIdentity($0, limit: 256) }) ?? true else {
            throw ApprovedNetworkError.contextMismatch
        }
        guard self.reportIdentity != reportIdentity || self.configurationIdentity != configurationIdentity else { return }
        try consent.invalidateAuthorizations()
        self.reportIdentity = reportIdentity
        self.configurationIdentity = configurationIdentity
        invalidatePending()
    }

    public func authorizeFeature(_ feature: ConsentFeature,
                                 disclosureVersion: String = ConsentDisclosure.currentVersion,
                                 scopeIdentity: String? = nil) throws -> ConsentAuthorization {
        guard let receipt = consent.activeReceipt(for: feature, disclosureVersion: disclosureVersion,
                                                   scopeIdentity: scopeIdentity ?? configurationIdentity) else {
            throw ConsentError.notGranted(feature)
        }
        return ConsentAuthorization(receipt: receipt, generation: consent.generation)
    }

    public func validateAuthorization(_ authorization: ConsentAuthorization) -> Bool {
        authorization.generation == consent.generation &&
        consent.activeReceipt(for: authorization.feature, disclosureVersion: authorization.disclosureVersion,
                              scopeIdentity: authorization.scopeIdentity)?.id == authorization.receiptID
    }

    public func preview(_ request: ApprovedNetworkRequest) throws -> NetworkRequestPreview {
        try validateRequestContext(request)
        // Bounded pending previews; they cannot be replayed across generation changes.
        if previews.count >= 20 { previews.removeAll(); approvals.removeAll() }
        let preview = NetworkRequestPreview(
            id: UUID(), disclosure: NetworkCatalogue.disclosure(for: request),
            payloadUTF8: String(decoding: request.body, as: UTF8.self),
            payloadSHA256: ContentDigest.sha256(request.body),
            certificateSHA256: request.certificateSHA256,
            authenticationDescription: request.bearerToken == nil ? "No authentication token" : "Configured bearer authentication; token value is not displayed",
            reportIdentity: request.reportIdentity, configurationIdentity: request.configurationIdentity,
            disclosureVersion: request.disclosureVersion,
            fingerprint: request.fingerprint, generation: consent.generation, createdAt: clock())
        previews[preview.id] = preview
        return preview
    }

    public func approve(_ preview: NetworkRequestPreview, lifetime: TimeInterval = 60) throws -> NetworkApproval {
        guard let stored = previews.removeValue(forKey: preview.id), stored == preview,
              preview.generation == consent.generation else {
            throw ApprovedNetworkError.approvalInvalidOrConsumed
        }
        guard clock().timeIntervalSince(preview.createdAt) >= 0,
              clock().timeIntervalSince(preview.createdAt) <= 300,
              lifetime.isFinite, lifetime > 0, lifetime <= 120 else {
            throw ApprovedNetworkError.approvalExpired
        }
        guard let feature = preview.disclosure.purpose.requiredConsent,
              consent.activeReceipt(for: feature, disclosureVersion: preview.disclosureVersion,
                                    scopeIdentity: preview.configurationIdentity) != nil else {
            throw ApprovedNetworkError.consentRequired
        }
        let approval = NetworkApproval(id: UUID(), expiresAt: clock().addingTimeInterval(lifetime),
                                       previewID: preview.id, fingerprint: preview.fingerprint,
                                       generation: consent.generation)
        approvals[approval.id] = approval
        return approval
    }

    public func cancel(_ approval: NetworkApproval) {
        approvals.removeValue(forKey: approval.id)
        if activeOperations.contains(approval.id) { cancelledOperations.insert(approval.id) }
        inFlight.removeValue(forKey: approval.id)?.cancel()
    }

    public func cancelAllRequests() { invalidatePending() }

    public func execute(_ request: ApprovedNetworkRequest, approval: NetworkApproval,
                        using transport: any ApprovedRequestTransport) async throws -> ApprovedNetworkResponse {
        let host = request.endpoint.host ?? ""
        let ledgerGeneration = await ledger.currentGeneration()
        do {
            try Task.checkCancellation()
            try validate(approval, request: request)
            guard approvals.removeValue(forKey: approval.id) == approval else {
                throw ApprovedNetworkError.approvalInvalidOrConsumed
            }
            activeOperations.insert(approval.id)
        } catch {
            await record(request, id: approval.id, phase: .denied, generation: ledgerGeneration)
            throw error
        }
        await record(request, id: approval.id, phase: .started, generation: ledgerGeneration)
        do {
            // Recording suspends the actor; recheck immediately before creating work.
            try validate(approval, request: request)
            let operation = Task {
                try Task.checkCancellation()
                return try await transport.send(request, permit: NetworkTransmissionPermit(approval: approval),
                                                maximumResponseBytes: request.purpose.maximumResponseBytes)
            }
            inFlight[approval.id] = operation
            let response = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            inFlight.removeValue(forKey: approval.id)
            guard !operation.isCancelled else { throw ApprovedNetworkError.cancelled }
            try Task.checkCancellation()
            try validate(approval, request: request)
            guard response.body.count <= request.purpose.maximumResponseBytes else { throw ApprovedNetworkError.responseTooLarge }
            guard (200...299).contains(response.statusCode) else { throw ApprovedNetworkError.httpStatus(response.statusCode) }
            await ledger.record(NetworkEvent(operationID: approval.id, purpose: request.purpose,
                                             host: host, occurredAt: clock(), phase: .completed,
                                             requestByteCount: request.body.count,
                                             responseByteCount: response.body.count,
                                             statusCode: response.statusCode), generation: ledgerGeneration)
            try validate(approval, request: request)
            activeOperations.remove(approval.id)
            cancelledOperations.remove(approval.id)
            return response
        } catch {
            inFlight.removeValue(forKey: approval.id)?.cancel()
            let cancelled = error is CancellationError || error as? ApprovedNetworkError == .cancelled ||
                approval.generation != consent.generation
            await record(request, id: approval.id, phase: cancelled ? .cancelled : .failed, generation: ledgerGeneration)
            activeOperations.remove(approval.id)
            cancelledOperations.remove(approval.id)
            if cancelled { throw ApprovedNetworkError.cancelled }
            throw error
        }
    }

    public func deleteAll() async throws {
        try consent.deleteAll()
        invalidatePending()
        reportIdentity = nil
        await ledger.deleteAll()
    }

    private func validateRequestContext(_ request: ApprovedNetworkRequest) throws {
        guard request.purpose.appCreatesRequest else { throw ApprovedNetworkError.undeclaredPurpose }
        guard request.configurationIdentity == configurationIdentity,
              request.purpose != .selfHostedAdvisor || request.reportIdentity == reportIdentity else {
            throw ApprovedNetworkError.contextMismatch
        }
    }

    private func validate(_ approval: NetworkApproval, request: ApprovedNetworkRequest) throws {
        try validateRequestContext(request)
        guard !cancelledOperations.contains(approval.id) else { throw ApprovedNetworkError.cancelled }
        guard approval.generation == consent.generation, approval.fingerprint == request.fingerprint else {
            throw ApprovedNetworkError.approvalInvalidOrConsumed
        }
        guard clock() < approval.expiresAt else { throw ApprovedNetworkError.approvalExpired }
        guard let feature = request.purpose.requiredConsent,
              consent.activeReceipt(for: feature, disclosureVersion: request.disclosureVersion,
                                    scopeIdentity: request.configurationIdentity) != nil else {
            throw ApprovedNetworkError.consentRequired
        }
    }

    private func invalidatePending() {
        previews.removeAll()
        approvals.removeAll()
        cancelledOperations.formUnion(activeOperations)
        for operation in inFlight.values { operation.cancel() }
        inFlight.removeAll()
    }

    private func record(_ request: ApprovedNetworkRequest, id: UUID, phase: NetworkEventPhase, generation: UUID) async {
        await ledger.record(NetworkEvent(operationID: id, purpose: request.purpose,
                                         host: request.endpoint.host ?? "", occurredAt: clock(),
                                         phase: phase, requestByteCount: request.body.count), generation: generation)
    }
}
