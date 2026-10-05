import Foundation
import NetworkExtension
import FirePrivacyCore

@main
final class URLFilterControlProvider: NEURLFilterControlProvider {
    required init() {}
    func start() async throws { _ = try ProtectionArtifactStore().validatedURLFilter() }
    func stop(reason: NEProviderStopReason) async throws {}

    func fetchPrefilter(existingPrefilterTag: String?) async throws -> NEURLFilterPrefilter? {
        let dataset = try ProtectionArtifactStore().validatedURLFilter()
        let manifest = dataset.manifest
        let tag = "\(manifest.version)-\(manifest.payloadSHA256)"
        if existingPrefilterTag == tag { return nil }
        guard let bits = manifest.bitCount, let hashes = manifest.hashCount, let seed = manifest.murmurSeed else {
            throw FilterDatasetError.incompatibleBloomFilter
        }
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("validated-url-prefilter-" + manifest.payloadSHA256)
        try dataset.payload.write(to: location, options: [.atomic])
        return NEURLFilterPrefilter(data: .temporaryFilepath(location), tag: tag,
                                   bitCount: bits, hashCount: hashes, murmurSeed: seed)
    }
}
