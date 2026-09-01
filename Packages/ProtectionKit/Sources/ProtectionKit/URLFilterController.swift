import Foundation
import ObservationCore

/// Drives the system URL filter through a bridge, and keeps the app's idea of
/// the state in step with the system's.
///
/// Every failure path lands in a state the UI can name (URLF-008). There is no
/// path that leaves the UI claiming protection is active when it is not — that
/// is the single most important property of this type.
public actor URLFilterController: URLFiltering {
    private let bridge: any URLFilterSystemBridge
    private let makeConfiguration: @Sendable (URLFilterProfile) -> URLFilterConfiguration
    private var state: URLFilterState = .unsupported
    private var lastVerified: Date?
    private var datasetVersion: String?
    private let clock: @Sendable () -> Date

    public init(
        bridge: any URLFilterSystemBridge,
        makeConfiguration: @escaping @Sendable (URLFilterProfile) -> URLFilterConfiguration,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.makeConfiguration = makeConfiguration
        self.clock = clock
    }

    public func availability() async -> URLFilterAvailability {
        await bridge.systemAvailability()
    }

    public func currentState() async -> URLFilterState {
        state = await bridge.loadState()
        return state
    }

    public func enable(profile: URLFilterProfile) async throws {
        guard profile.isSelectable else { throw URLFilterError.profileNotSelectable }
        let availability = await bridge.systemAvailability()
        guard availability.isAvailable else {
            state = availability == .unsupportedOSVersion(required: 26) ? .unsupported : .available
            throw URLFilterError.unavailable(availability.explanation)
        }

        state = .enabling
        do {
            try await bridge.save(configuration: makeConfiguration(profile))
        } catch {
            // The save failed, so nothing is filtering. Say so.
            state = .available
            throw URLFilterError.saveFailed(String(describing: error))
        }
        state = await bridge.loadState()
        lastVerified = clock()
    }

    public func disable() async throws {
        do {
            try await bridge.removeConfiguration()
        } catch {
            state = await bridge.loadState()
            throw URLFilterError.removeFailed(String(describing: error))
        }
        state = .disabled
    }

    public func refreshDataset() async throws {
        guard state.isProtecting || state == .staleDataset || state == .updatePending else { return }
        state = .updatePending
        state = await bridge.loadState()
        lastVerified = clock()
    }

    public func snapshot(profile: URLFilterProfile?) -> ProtectionState {
        ProtectionState(
            urlFilterState: state,
            urlFilterProfile: profile,
            filterDatasetVersion: datasetVersion,
            filterLastVerified: lastVerified
        )
    }

    public func recordDataset(version: String, verifiedAt: Date) {
        datasetVersion = version
        lastVerified = verifiedAt
    }
}

/// The bridge used when the capability is not present in this build, so the
/// consumer app has a working Protection screen that honestly says "not
/// available" rather than a screen that pretends.
public struct UnavailableURLFilterBridge: URLFilterSystemBridge {
    private let reason: URLFilterAvailability

    public init(reason: URLFilterAvailability = .entitlementMissing) {
        self.reason = reason
    }

    public func systemAvailability() async -> URLFilterAvailability { reason }
    public func loadState() async -> URLFilterState { .unsupported }
    public func save(configuration: URLFilterConfiguration) async throws {
        throw URLFilterError.unavailable(reason.explanation)
    }
    public func removeConfiguration() async throws {}
}
