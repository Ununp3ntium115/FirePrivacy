import Foundation
import Security
import FirePrivacyCore

/// The app's only URLSession worker. A core-gate permit is mandatory and consumed
/// once, so constructing a request or an endpoint setting cannot open a connection.
actor ApprovedHTTPTransport: ApprovedRequestTransport {
    private var consumed: [UUID: Date] = [:]

    func send(_ request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit,
              maximumResponseBytes: Int) async throws -> ApprovedNetworkResponse {
        let now = Date()
        consumed = consumed.filter { $0.value > now }
        guard permit.authorizes(request, at: now), consumed[permit.id] == nil else {
            throw ApprovedNetworkError.approvalInvalidOrConsumed
        }
        guard maximumResponseBytes > 0,
              maximumResponseBytes <= request.purpose.maximumResponseBytes else {
            throw ApprovedNetworkError.responseTooLarge
        }
        consumed[permit.id] = permit.expiresAt
        try Task.checkCancellation()
        let worker = ApprovedHTTPWorker(request: request, permit: permit,
                                        maximumResponseBytes: maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try await worker.start()
        } onCancel: { worker.cancel() }
    }
}

/// The lock serializes starting/cancelling, delegate callbacks, and continuation
/// completion. No imported values, authorization token, response text, or URL are logged.
private final class ApprovedHTTPWorker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let approvedRequest: ApprovedNetworkRequest
    private let permit: NetworkTransmissionPermit
    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApprovedNetworkResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var cancelled = false
    private var responseBody = Data()
    private var statusCode: Int?
    private var contentType: String?

    init(request: ApprovedNetworkRequest, permit: NetworkTransmissionPermit, maximumResponseBytes: Int) {
        approvedRequest = request
        self.permit = permit
        self.maximumResponseBytes = maximumResponseBytes
    }

    func start() async throws -> ApprovedNetworkResponse {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled || finished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            guard permit.authorizes(approvedRequest) else {
                finished = true
                lock.unlock()
                continuation.resume(throwing: ApprovedNetworkError.approvalExpired)
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCredentialStorage = nil
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
            var outgoing = URLRequest(url: approvedRequest.endpoint,
                                      cachePolicy: .reloadIgnoringLocalCacheData,
                                      timeoutInterval: 30)
            outgoing.httpMethod = approvedRequest.method.rawValue
            if !approvedRequest.body.isEmpty { outgoing.httpBody = approvedRequest.body }
            outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
            outgoing.setValue("FirePrivacy", forHTTPHeaderField: "User-Agent")
            if approvedRequest.method == .post {
                outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let token = approvedRequest.bearerToken {
                outgoing.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: outgoing)
            self.session = session
            self.task = task
            // Cancellation obtains the same lock: a cancelled worker cannot resume later.
            task.resume()
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ApprovedNetworkError.httpStatus(response.statusCode)))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock()
        let noLongerAuthorized = finished || cancelled || !permit.authorizes(approvedRequest)
        lock.unlock()
        guard !noLongerAuthorized,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let expectedHost = approvedRequest.endpoint.host,
              challenge.protectionSpace.host.lowercased() == expectedHost.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(ApprovedNetworkError.untrustedServer))
            return
        }
        // Keep normal platform trust, validity-date and hostname checks. A pin adds
        // an extra restriction; it never makes an invalid/self-signed chain trusted.
        let policy = SecPolicyCreateSSL(true, expectedHost as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(ApprovedNetworkError.untrustedServer))
            return
        }
        if let expectedPin = approvedRequest.certificateSHA256 {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  ContentDigest.sha256(SecCertificateCopyData(leaf) as Data) == expectedPin else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                finish(.failure(ApprovedNetworkError.untrustedServer))
                return
            }
        }
        lock.lock()
        let mayContinue = !finished && !cancelled && permit.authorizes(approvedRequest)
        lock.unlock()
        if mayContinue { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(ApprovedNetworkError.unexpectedResponse))
            return
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(ApprovedNetworkError.httpStatus(http.statusCode)))
            return
        }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            completionHandler(.cancel)
            finish(.failure(ApprovedNetworkError.responseTooLarge))
            return
        }
        lock.lock()
        let mayContinue = !finished && !cancelled
        if mayContinue {
            statusCode = http.statusCode
            contentType = http.mimeType.map { String($0.prefix(200)) }
        }
        lock.unlock()
        completionHandler(mayContinue ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished && !cancelled else { lock.unlock(); return }
        guard data.count <= maximumResponseBytes - responseBody.count else {
            lock.unlock()
            finish(.failure(ApprovedNetworkError.responseTooLarge))
            return
        }
        responseBody.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(ApprovedNetworkError.unexpectedResponse)) }
            return
        }
        lock.lock()
        let response = statusCode.map { ApprovedNetworkResponse(statusCode: $0, body: responseBody, contentType: contentType) }
        lock.unlock()
        if let response { finish(.success(response)) }
        else { finish(.failure(ApprovedNetworkError.unexpectedResponse)) }
    }

    private func finish(_ result: Result<ApprovedNetworkResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        let task = task
        self.task = nil
        responseBody.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
