import Foundation
import ObservationCore

/// Configuration for a model endpoint the user runs themselves (AI-010).
///
/// Fire Privacy assumes nothing about Ollama being present on iOS — it is not
/// (§3.7, ADR-009). This is a connection to a machine the user chose, and every
/// field that would leave the iPhone is previewed before anything is sent.
public struct LocalEndpointConfiguration: Codable, Sendable, Hashable {
    public enum Scheme: String, Codable, Sendable, Hashable {
        case https
        /// Permitted only in a developer build, on a user-selected local
        /// network, and always with a visible warning.
        case http
    }

    public let scheme: Scheme
    public let host: String
    public let port: Int
    public let modelName: String
    /// SHA-256 of the server certificate the user approved. A change requires
    /// re-approval (AI-010).
    public let pinnedCertificateDigest: FireDigest?
    public let usesMutualTLS: Bool
    /// Set when the host is not a private-network address, which triggers the
    /// additional "Internet model" warning.
    public let isRemoteHost: Bool

    public init(
        scheme: Scheme,
        host: String,
        port: Int,
        modelName: String,
        pinnedCertificateDigest: FireDigest?,
        usesMutualTLS: Bool,
        isRemoteHost: Bool
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.modelName = modelName
        self.pinnedCertificateDigest = pinnedCertificateDigest
        self.usesMutualTLS = usesMutualTLS
        self.isRemoteHost = isRemoteHost
    }

    public enum ConfigurationProblem: String, Sendable, Hashable {
        case plainHTTPInProductionBuild
        case missingCertificatePin
        case remoteHostWithoutAcknowledgement
    }

    /// Reasons this configuration must not be used, given the build type.
    public func problems(isDeveloperBuild: Bool, remoteHostAcknowledged: Bool) -> [ConfigurationProblem] {
        var problems: [ConfigurationProblem] = []
        if scheme == .http, !isDeveloperBuild { problems.append(.plainHTTPInProductionBuild) }
        if scheme == .https, pinnedCertificateDigest == nil { problems.append(.missingCertificatePin) }
        if isRemoteHost, !remoteHostAcknowledged { problems.append(.remoteHostWithoutAcknowledgement) }
        return problems
    }

    /// Exactly what the user is shown before the first request (AI-010).
    public func disclosure(fieldNames: [String]) -> String {
        let destination = "\(scheme.rawValue)://\(host):\(port)"
        let transport = scheme == .https
            ? (usesMutualTLS ? "an encrypted, mutually authenticated connection" : "an encrypted connection")
            : "an unencrypted connection"
        return """
        Fire Privacy will send a structured summary of this finding to \(destination) over \(transport).

        These fields leave this iPhone: \(fieldNames.joined(separator: ", ")).

        Your imported report, raw domains and any notes you wrote are not included.
        """
    }
}

/// The transport for a user-operated endpoint. Left abstract here so that this
/// package contains no networking code at all; the app supplies an
/// implementation only if the user configures an endpoint.
public protocol LocalEndpointTransport: Sendable {
    func send(system: String, input: AdvisoryInput, configuration: LocalEndpointConfiguration) async throws -> AdvisoryCandidate
}

/// A user-operated endpoint, wired through `LocalEndpointTransport`.
public struct LocalEndpointAdvisor: PrivacyAdvisor {
    public let mode: AdvisorMode = .userLocalEndpoint

    private let configuration: LocalEndpointConfiguration?
    private let transport: (any LocalEndpointTransport)?
    private let isDeveloperBuild: Bool
    private let remoteHostAcknowledged: Bool

    public init(
        configuration: LocalEndpointConfiguration?,
        transport: (any LocalEndpointTransport)?,
        isDeveloperBuild: Bool = false,
        remoteHostAcknowledged: Bool = false
    ) {
        self.configuration = configuration
        self.transport = transport
        self.isDeveloperBuild = isDeveloperBuild
        self.remoteHostAcknowledged = remoteHostAcknowledged
    }

    public func availability() async -> AdvisorAvailability {
        guard let configuration, transport != nil else { return .notConfigured }
        let problems = configuration.problems(
            isDeveloperBuild: isDeveloperBuild,
            remoteHostAcknowledged: remoteHostAcknowledged
        )
        return problems.isEmpty ? .available : .notConfigured
    }

    public func explain(_ input: AdvisoryInput) async throws -> AdvisoryOutput {
        guard let configuration, let transport else {
            throw AdvisorError.unavailable("No endpoint is configured.")
        }
        let problems = configuration.problems(
            isDeveloperBuild: isDeveloperBuild,
            remoteHostAcknowledged: remoteHostAcknowledged
        )
        guard problems.isEmpty else {
            throw AdvisorError.unavailable(problems.map(\.rawValue).joined(separator: ", "))
        }
        let candidate = try await transport.send(system: AdvisoryPrompt.system, input: input, configuration: configuration)
        return AdvisoryOutput(
            findingID: input.findingID,
            headline: candidate.headline,
            explanation: candidate.explanation,
            whyItMatters: candidate.whyItMatters,
            uncertainty: candidate.uncertainty,
            evidenceIDs: candidate.evidenceIDs,
            actionIDs: candidate.actionIDs,
            noActionExplanation: candidate.noActionExplanation,
            mode: mode
        )
    }
}
