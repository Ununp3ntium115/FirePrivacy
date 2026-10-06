import Foundation
import XCTest
@testable import FirePrivacyCore

final class ConsentNetworkTests: XCTestCase, @unchecked Sendable {
    private func makeRequest(endpoint: String = "https://model.example.test/api/chat",
                         body: String = "{\"count\":3}", configuration: String = "config-a",
                         report: String = "report-a", version: String = ConsentDisclosure.currentVersion,
                         token: String? = nil, pin: String? = nil) throws -> ApprovedNetworkRequest {
        try ApprovedNetworkRequest(purpose: .selfHostedAdvisor, endpoint: URL(string: endpoint)!,
                                   body: Data(body.utf8), disclosureVersion: version,
                                   reportIdentity: report, configurationIdentity: configuration,
                                   payloadFields: ["count"], retentionDisclosure: NetworkCatalogue.unknownRetention,
                                   certificateSHA256: pin, bearerToken: token)
    }

    private func makeGate(clock: TestClock = TestClock()) -> ApprovedNetworkGate {
        ApprovedNetworkGate(reportIdentity: "report-a", configurationIdentity: "config-a",
                            clock: { clock.now() })
    }

    private func approval(for request: ApprovedNetworkRequest, gate: ApprovedNetworkGate,
                          lifetime: TimeInterval = 60) async throws -> NetworkApproval {
        _ = try await gate.grantConsent(feature: .selfHostedAdvisor)
        let preview = try await gate.preview(request)
        return try await gate.approve(preview, lifetime: lifetime)
    }

    func testConsentIsUnbundledVersionedAndRevocable() throws {
        var state = ConsentState()
        let first = try state.grant(.selfHostedAdvisor, disclosureVersion: "v1", at: Date(),
                                    appVersion: "1", osVersion: "26")
        XCTAssertNotNil(state.activeReceipt(for: .selfHostedAdvisor, disclosureVersion: "v1", scopeIdentity: nil))
        XCTAssertNil(state.activeReceipt(for: .knowledgeBaseUpdates, disclosureVersion: "v1", scopeIdentity: nil))
        XCTAssertNil(state.activeReceipt(for: .selfHostedAdvisor, disclosureVersion: "v2", scopeIdentity: nil))
        _ = try state.grant(.selfHostedAdvisor, disclosureVersion: "v2", at: Date(), appVersion: "1", osVersion: "26")
        XCTAssertFalse(state.receipts.first { $0.id == first.id }!.isActive)
        try state.revoke(.selfHostedAdvisor, at: Date())
        XCTAssertNil(state.activeReceipt(for: .selfHostedAdvisor, disclosureVersion: "v2", scopeIdentity: nil))
        XCTAssertEqual(state.generation, 3)
    }

    func testConsentSnapshotRoundTripsRevocationGeneration() throws {
        var state = ConsentState()
        _ = try state.grant(.encryptedDNS, disclosureVersion: "v1", scopeIdentity: "resolver-a",
                            at: Date(), appVersion: "1", osVersion: "26")
        try state.revoke(.encryptedDNS, at: Date())
        let copy = try JSONDecoder().decode(ConsentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(copy, state)
        XCTAssertEqual(copy.generation, 2)
        XCTAssertTrue(copy.receipts.allSatisfy { !$0.isActive })
    }

    func testInvalidReceiptIdentifiersAreRejected() throws {
        var state = ConsentState()
        XCTAssertThrowsError(try state.grant(.selfHostedAdvisor, disclosureVersion: "bad\nversion",
                                            at: Date(), appVersion: "1", osVersion: "26"))
        XCTAssertThrowsError(try state.grant(.selfHostedAdvisor, disclosureVersion: "v1", scopeIdentity: "",
                                            at: Date(), appVersion: "1", osVersion: "26"))
        XCTAssertEqual(state.generation, 0)
    }

    func testNoRequestWithoutExplicitCurrentConsent() async throws {
        let gate = makeGate()
        let preview = try await gate.preview(makeRequest())
        do {
            _ = try await gate.approve(preview)
            XCTFail("Endpoint entry alone must not authorize transmission")
        } catch { XCTAssertEqual(error as? ApprovedNetworkError, .consentRequired) }
    }

    func testPreviewDisplaysExactlyApprovedBodyAndDestinationWithoutToken() async throws {
        let gate = makeGate()
        let request = try makeRequest(body: "{\"count\":3,\"label\":\"plain text\"}", token: "secret-token")
        let preview = try await gate.preview(request)
        XCTAssertEqual(preview.payloadUTF8, String(data: request.body, encoding: .utf8))
        XCTAssertEqual(preview.payloadSHA256, ContentDigest.sha256(request.body))
        XCTAssertEqual(preview.disclosure.destination, request.endpoint.absoluteString)
        XCTAssertFalse(preview.authenticationDescription.contains("secret-token"))
        XCTAssertTrue(preview.disclosure.connectionMetadataDescription.contains("network address"))
    }

    func testApprovalIsSingleUse() async throws {
        let gate = makeGate(), transport = RecordingTransport()
        let request = try makeRequest()
        let approval = try await approval(for: request, gate: gate)
        let response = try await gate.execute(request, approval: approval, using: transport)
        XCTAssertEqual(response.statusCode, 200)
        do {
            _ = try await gate.execute(request, approval: approval, using: transport)
            XCTFail("A second send needs another preview approval")
        } catch { XCTAssertEqual(error as? ApprovedNetworkError, .approvalInvalidOrConsumed) }
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testPayloadEndpointAndCredentialMutationsCannotReuseApproval() async throws {
        for changed in [try makeRequest(body: "{\"count\":4}"),
                        try makeRequest(endpoint: "https://different.example.test/api/chat"),
                        try makeRequest(token: "new-token"),
                        try makeRequest(pin: String(repeating: "a", count: 64))] {
            let gate = makeGate(), transport = RecordingTransport()
            let original = try makeRequest()
            let approval = try await approval(for: original, gate: gate)
            do {
                _ = try await gate.execute(changed, approval: approval, using: transport)
                XCTFail("Approval must bind all destination and transmitted-byte settings")
            } catch { XCTAssertEqual(error as? ApprovedNetworkError, .approvalInvalidOrConsumed) }
            let calls = await transport.callCount()
            XCTAssertEqual(calls, 0)
        }
    }

    func testChangedReportOrConfigurationInvalidatesPendingApproval() async throws {
        for changedReport in [true, false] {
            let gate = makeGate(), transport = RecordingTransport()
            let request = try makeRequest(), approval = try await approval(for: request, gate: gate)
            try await gate.updateContext(reportIdentity: changedReport ? "report-b" : "report-a",
                                         configurationIdentity: changedReport ? "config-a" : "config-b")
            do {
                _ = try await gate.execute(request, approval: approval, using: transport)
                XCTFail("Stale preview cannot send")
            } catch { XCTAssertTrue(error is ApprovedNetworkError) }
            let calls = await transport.callCount()
            XCTAssertEqual(calls, 0)
        }
    }

    func testRevocationBeforeSendNeverCallsTransport() async throws {
        let gate = makeGate(), transport = RecordingTransport()
        let request = try makeRequest(), approval = try await approval(for: request, gate: gate)
        try await gate.revokeConsent(.selfHostedAdvisor)
        do {
            _ = try await gate.execute(request, approval: approval, using: transport)
            XCTFail("Revocation must deny pending send")
        } catch { XCTAssertTrue(error is ApprovedNetworkError) }
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testRevocationDuringInFlightWorkDiscardsLateResponse() async throws {
        let gate = makeGate(), transport = PausedTransport()
        let request = try makeRequest(), approval = try await approval(for: request, gate: gate)
        let operation = Task { try await gate.execute(request, approval: approval, using: transport) }
        await transport.waitUntilStarted()
        try await gate.revokeConsent(.selfHostedAdvisor)
        // The fake transport intentionally ignores cancellation, like a late completion.
        await transport.complete()
        do {
            _ = try await operation.value
            XCTFail("A revoked generation's output cannot be published")
        } catch { XCTAssertEqual(error as? ApprovedNetworkError, .cancelled) }
    }

    func testCancellationDiscardsLateResponseEvenWithoutConsentChange() async throws {
        let gate = makeGate(), transport = PausedTransport()
        let request = try makeRequest(), approval = try await approval(for: request, gate: gate)
        let operation = Task { try await gate.execute(request, approval: approval, using: transport) }
        await transport.waitUntilStarted()
        await gate.cancel(approval)
        await transport.complete()
        do { _ = try await operation.value; XCTFail("Cancelled output must be rejected") }
        catch { XCTAssertEqual(error as? ApprovedNetworkError, .cancelled) }
    }

    func testExpiredApprovalNeverCallsTransport() async throws {
        let clock = TestClock(), gate = makeGate(clock: clock), transport = RecordingTransport()
        let request = try makeRequest(), approval = try await approval(for: request, gate: gate, lifetime: 1)
        clock.advance(2)
        do { _ = try await gate.execute(request, approval: approval, using: transport); XCTFail("Expired approval") }
        catch { XCTAssertEqual(error as? ApprovedNetworkError, .approvalExpired) }
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testChangedDisclosureVersionRequiresNewFeatureConsent() async throws {
        let gate = makeGate()
        _ = try await gate.grantConsent(feature: .selfHostedAdvisor, disclosureVersion: "v1")
        let preview = try await gate.preview(makeRequest(version: "v2"))
        do { _ = try await gate.approve(preview); XCTFail("Old disclosure consent is insufficient") }
        catch { XCTAssertEqual(error as? ApprovedNetworkError, .consentRequired) }
    }

    func testInsecureEndpointsRedirectSurfacesAndMalformedHeadersAreRejected() throws {
        for endpoint in ["http://model.example.test/api/chat", "https://user:password@model.example.test/api/chat",
                         "https://model.example.test/api/chat?token=secret", "https://model.example.test/api/chat#fragment"] {
            XCTAssertThrowsError(try makeRequest(endpoint: endpoint))
        }
        XCTAssertThrowsError(try makeRequest(token: "secret\r\nX-Leak: value"))
        XCTAssertThrowsError(try makeRequest(pin: "not-a-sha256-digest"))
    }

    func testUndeclaredAppRequestsAndDatasetPayloadsAreDenied() throws {
        XCTAssertThrowsError(try ApprovedNetworkRequest(purpose: .encryptedDNS,
                                                        endpoint: URL(string: "https://resolver.example.test")!,
                                                        body: Data(), disclosureVersion: "v1", reportIdentity: nil,
                                                        configurationIdentity: "config-a", payloadFields: [],
                                                        retentionDisclosure: "Unknown"))
        XCTAssertThrowsError(try ApprovedNetworkRequest(purpose: .knowledgeBaseUpdate,
                                                        endpoint: URL(string: "https://data.example.test/latest")!,
                                                        method: .get, body: Data("private-report".utf8),
                                                        disclosureVersion: "v1", reportIdentity: nil,
                                                        configurationIdentity: "config-a", payloadFields: [],
                                                        retentionDisclosure: "Unknown"))
    }

    func testFilterUpdateDoesNotBorrowKnowledgeBaseConsent() async throws {
        let gate = makeGate()
        _ = try await gate.grantConsent(feature: .knowledgeBaseUpdates)
        let request = try ApprovedNetworkRequest(purpose: .filterListUpdate,
                                                 endpoint: URL(string: "https://data.example.test/filter")!,
                                                 method: .get, body: Data(), disclosureVersion: ConsentDisclosure.currentVersion,
                                                 reportIdentity: nil, configurationIdentity: "config-a",
                                                 payloadFields: [], retentionDisclosure: "Unknown")
        let preview = try await gate.preview(request)
        do { _ = try await gate.approve(preview); XCTFail("Consents are separate") }
        catch { XCTAssertEqual(error as? ApprovedNetworkError, .consentRequired) }
    }

    func testOversizedResponseAndHTTPFailureDoNotPublishSuccess() async throws {
        for response in [ApprovedNetworkResponse(statusCode: 200, body: Data(repeating: 0, count: 65_537)),
                         ApprovedNetworkResponse(statusCode: 302, body: Data())] {
            let gate = makeGate(), transport = RecordingTransport(response: response)
            let request = try makeRequest(), approval = try await approval(for: request, gate: gate)
            do { _ = try await gate.execute(request, approval: approval, using: transport); XCTFail("Invalid response") }
            catch { XCTAssertTrue(error is ApprovedNetworkError) }
            let events = await gate.ledger.snapshot()
            XCTAssertFalse(events.contains { $0.phase == .completed })
        }
    }

    func testTypedOSAuthorizationExpiresOnRevocationOrContextChange() async throws {
        let gate = makeGate()
        _ = try await gate.grantConsent(feature: .encryptedDNS)
        let authorization = try await gate.authorizeFeature(.encryptedDNS)
        let initiallyValid = await gate.validateAuthorization(authorization)
        XCTAssertTrue(initiallyValid)
        try await gate.revokeConsent(.encryptedDNS)
        let laterValid = await gate.validateAuthorization(authorization)
        XCTAssertFalse(laterValid)
    }

    func testLedgerRecordsMetadataWithoutPrivatePayloadOrCredential() async throws {
        let gate = makeGate(), transport = RecordingTransport()
        let request = try makeRequest(body: "{\"count\":3,\"secret\":\"private-payload\"}", token: "secret-token")
        let approval = try await approval(for: request, gate: gate)
        _ = try await gate.execute(request, approval: approval, using: transport)
        let events = await gate.ledger.snapshot()
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(text.contains("private-payload"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertFalse(text.contains("/api/chat"))
        XCTAssertTrue(text.contains("model.example.test"))
        XCTAssertEqual(events.map(\.phase), [.started, .completed])
    }

    func testLedgerIsBoundedAndDeleteAllClearsReceiptsEventsAndRequests() async throws {
        let ledger = NetworkEventLedger(capacity: 2)
        for phase in [NetworkEventPhase.started, .completed, .denied] {
            await ledger.record(NetworkEvent(operationID: UUID(), purpose: .knowledgeBaseUpdate, host: "data.example.test",
                                              occurredAt: Date(), phase: phase, requestByteCount: 0))
        }
        let events = await ledger.snapshot()
        XCTAssertEqual(events.map(\.phase), [.completed, .denied])
        let gate = ApprovedNetworkGate(reportIdentity: "report-a", configurationIdentity: "config-a", ledger: ledger)
        _ = try await gate.grantConsent(feature: .selfHostedAdvisor)
        try await gate.deleteAll()
        let state = await gate.consentSnapshot(), emptyEvents = await ledger.snapshot()
        XCTAssertTrue(state.receipts.isEmpty)
        XCTAssertTrue(emptyEvents.isEmpty)
    }

    func testDNSDisclosureNamesResolverQueriesAndRetentionWithoutClaimingAnonymity() {
        let disclosure = NetworkCatalogue.encryptedDNS(resolver: "https://resolver.example.test/dns-query",
                                                       operatorName: "User's resolver")
        XCTAssertTrue(disclosure.payloadDescription.contains("DNS query names leave the device"))
        XCTAssertTrue(disclosure.payloadDescription.contains("resolver can read"))
        XCTAssertTrue(disclosure.connectionMetadataDescription.contains("network addresses"))
        XCTAssertEqual(disclosure.retentionDescription, NetworkCatalogue.unknownRetention)
    }

    func testDeleteAllCannotBeUndoneByLateNetworkCompletionEvents() async throws {
        let gate = makeGate(), transport = PausedTransport()
        let request = try makeRequest()
        let approval = try await approval(for: request, gate: gate)
        let operation = Task { try await gate.execute(request, approval: approval, using: transport) }
        await transport.waitUntilStarted()
        try await gate.deleteAll()
        await transport.complete()
        do { _ = try await operation.value; XCTFail("Deleted request generation cannot return") }
        catch { XCTAssertEqual(error as? ApprovedNetworkError, .cancelled) }
        let events = await gate.ledger.snapshot()
        XCTAssertTrue(events.isEmpty, "Late callbacks cannot recreate deleted network history")
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}

private actor RecordingTransport: ApprovedRequestTransport {
    private var calls = 0
    private let response: ApprovedNetworkResponse
    init(response: ApprovedNetworkResponse = ApprovedNetworkResponse(statusCode: 200, body: Data("{}".utf8))) {
        self.response = response
    }
    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse {
        calls += 1
        return response
    }
    func callCount() -> Int { calls }
}

/// Intentionally non-cooperating: the gate must reject late cancelled output itself.
private actor PausedTransport: ApprovedRequestTransport {
    private var responseContinuation: CheckedContinuation<ApprovedNetworkResponse, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { responseContinuation = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startedContinuation = $0 } }
    }
    func complete() {
        responseContinuation?.resume(returning: ApprovedNetworkResponse(statusCode: 200, body: Data("{}".utf8)))
        responseContinuation = nil
    }
}
