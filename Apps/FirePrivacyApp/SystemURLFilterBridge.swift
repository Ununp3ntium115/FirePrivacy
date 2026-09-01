import Foundation
import ProtectionKit
#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// The one file that touches `NEURLFilterManager`.
///
/// Fire Privacy ships with the filter reported unavailable until the capability
/// and Apple's relay approval are in place (URLF-001, Gate 0). The Protection
/// screen then states plainly that the feature is not available on this build
/// rather than offering a switch that cannot work.
///
/// TODO(Gate 3): implement `save`/`loadState` against `NEURLFilterManager` once
/// the entitlement is granted, and record the verification in
/// `Documentation/ADR`.
struct SystemURLFilterBridge: URLFilterSystemBridge {
    func systemAvailability() async -> URLFilterAvailability {
        #if canImport(NetworkExtension)
        if #available(iOS 26, *) {
            return .entitlementMissing
        }
        return .unsupportedOSVersion(required: 26)
        #else
        return .unsupportedOSVersion(required: 26)
        #endif
    }

    func loadState() async -> URLFilterState {
        let availability = await systemAvailability()
        return availability.isAvailable ? .available : .unsupported
    }

    func save(configuration: URLFilterConfiguration) async throws {
        throw URLFilterError.unavailable("The URL filter capability is not present in this build.")
    }

    func removeConfiguration() async throws {}
}
