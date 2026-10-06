import Foundation

/// Distribution notices are read from packaged resources, never fetched at runtime.
public struct BundledLegalNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let componentDescription: String
    public let licenseReference: String
    public let sourceReference: String
    public let resourceOrigin: String
    public let text: String
}

public enum BundledLegalNotices {
    public enum Failure: Error, Equatable, Sendable {
        case missingResource, unreadableResource, oversizedResource, invalidEncoding
    }
    public static let maximumNoticeBytes = 64 * 1_024

    public static func load() throws -> [BundledLegalNotice] {
        [
            try notice(id: "public-suffix-list", title: "Public Suffix List · Mozilla Public License 2.0",
                componentDescription: "The bundled Public Suffix List retains its upstream notices and is distributed under Mozilla Public License 2.0.",
                licenseReference: "https://mozilla.org/MPL/2.0/",
                sourceReference: "https://raw.githubusercontent.com/publicsuffix/list/6cd82aff889e3d64e5e03bc5c1f43da1934a960a/public_suffix_list.dat",
                name: "PSL-LICENSE", subdirectory: "KnowledgeBase"),
            try notice(id: "apple-url-filter-sample", title: "Apple URL-filter sample code license",
                componentDescription: "Apple’s MIT-form copyright, permission and warranty notice for URL-filter sample compatibility portions is reproduced verbatim below.",
                licenseReference: "https://opensource.org/license/mit",
                sourceReference: "https://developer.apple.com/documentation/NetworkExtension/filtering-traffic-by-url",
                name: "APPLE-URLFILTER-LICENSE", subdirectory: "ThirdParty")
        ]
    }

    private static func notice(id: String, title: String, componentDescription: String,
                               licenseReference: String, sourceReference: String,
                               name: String, subdirectory: String) throws -> BundledLegalNotice {
        // SwiftPM can preserve or flatten processed resource directories depending on the host.
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: subdirectory)
            ?? Bundle.module.url(forResource: name, withExtension: "txt") else { throw Failure.missingResource }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw Failure.unreadableResource }
        guard size <= maximumNoticeBytes else { throw Failure.oversizedResource }
        let bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty, bytes.count <= maximumNoticeBytes else { throw Failure.oversizedResource }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalidEncoding }
        return BundledLegalNotice(id: id, title: title, componentDescription: componentDescription,
            licenseReference: licenseReference, sourceReference: sourceReference,
            resourceOrigin: "FirePrivacyCore/Resources/" + subdirectory + "/" + name + ".txt", text: text)
    }
}
