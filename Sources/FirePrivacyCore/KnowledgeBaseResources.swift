import Foundation

public enum KnowledgeBaseResources {
    public enum Failure: Error { case missingResource }
    public static let bootstrapKeyID = "fireprivacy-bootstrap-2026-10"
    public static let trustAnchors: [KnowledgeBaseTrustAnchor] = [
        .init(keyID: bootstrapKeyID,
              publicKey: Data([0x9a,0x0a,0x15,0x71,0x27,0x03,0x32,0x32,0x62,0x9d,0x48,0x51,0xb1,0xb6,0x48,0x40,
                              0x53,0xcd,0x91,0x23,0x06,0xf8,0x06,0x47,0x38,0x52,0xb7,0x99,0x9e,0x96,0xbe,0x5b]))
    ]
    static func resource(_ name: String, extension ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "KnowledgeBase")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }
    static var publicSuffixText: String? {
        guard let url = resource("public_suffix_list", extension: "dat"), let bytes = try? Data(contentsOf: url),
              ContentDigest.sha256(bytes) == "102b252c18b5f87f4c81f017e75282a82c18e00cd0c2e601b5b02a0f7a601f2c" else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    public static func loadBundled(appVersion: String = "1.0.0", now: Date = Date()) throws -> VerifiedKnowledgeBase {
        guard let manifest = resource("manifest", extension: "json"), let payload = resource("payload", extension: "json") else {
            throw Failure.missingResource
        }
        return try KnowledgeBaseVerifier(trustAnchors: trustAnchors).verify(
            manifestData: Data(contentsOf: manifest), payloadData: Data(contentsOf: payload), appVersion: appVersion, now: now
        )
    }
}
