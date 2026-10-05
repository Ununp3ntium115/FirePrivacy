import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("Fire Privacy requires CryptoKit or the vetted Swift Crypto backend.")
#endif

/// Content-derived identities describe source bytes, not an inferred privacy risk.
public enum ContentDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An RFC 9562 version-8 UUID derived from a namespaced SHA-256 digest.
    /// Callers include their versioned namespace and all identity components.
    public static func stableID(_ namespaceAndValue: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(namespaceAndValue.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
