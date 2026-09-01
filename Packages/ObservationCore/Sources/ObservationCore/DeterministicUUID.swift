import Foundation

/// Content-derived identifiers.
///
/// Fire Privacy must produce byte-identical machine-readable output for the same
/// input (DET-012), so record identifiers are derived from content rather than
/// generated randomly. The construction follows RFC 4122's name-based scheme
/// with SHA-256 in place of MD5/SHA-1, and sets the version and variant bits so
/// the value is a well-formed UUID.
public enum DeterministicUUID {
    public enum Namespace: String, Sendable {
        case importSession = "fireprivacy.import-session"
        case application = "fireprivacy.application"
        case networkObservation = "fireprivacy.network-observation"
        case sensorObservation = "fireprivacy.sensor-observation"
        case finding = "fireprivacy.finding"
        case evidence = "fireprivacy.evidence"
    }

    public static func make(namespace: Namespace, name: String) -> UUID {
        var hasher = FireHasher()
        hasher.update(namespace.rawValue)
        hasher.update("\u{1F}") // unit separator: names cannot collide across fields
        hasher.update(name)
        let digest = hasher.finalize()

        var bytes = Array(digest.bytes.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8: custom
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
