import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A 32-byte SHA-256 digest.
///
/// Digests are used throughout Fire Privacy for *evidence linkage* — every
/// normalized observation carries the hash of the source line it came from, so a
/// finding can be traced back to the exact bytes the user imported without
/// retaining those bytes (§10.2 IMP-007).
public struct FireDigest: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 32

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// Trusted initializer for values whose length is guaranteed by construction.
    init(unchecked bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Lowercase hexadecimal representation. Stable across platforms and releases.
    public var hexString: String {
        var out = ""
        out.reserveCapacity(Self.byteCount * 2)
        for byte in bytes {
            out.append(Self.hexDigits[Int(byte >> 4)])
            out.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    /// Short form used in user-facing evidence chips. Never used for equality.
    public var shortHexString: String { String(hexString.prefix(16)) }

    public var description: String { hexString }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let parsed = Self(hexString: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a SHA-256 hex digest")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    public init?(hexString: String) {
        guard hexString.count == Self.byteCount * 2 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        var high: UInt8?
        for character in hexString {
            guard let value = character.hexDigitValue, value >= 0, value < 16 else { return nil }
            let nibble = UInt8(value)
            if let stored = high {
                bytes.append((stored << 4) | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { return nil }
        self.init(bytes: bytes)
    }
}

/// Incremental SHA-256.
///
/// On Apple platforms this delegates to CryptoKit; elsewhere (Linux CI, which
/// runs the deterministic golden tests) it uses `PortableSHA256`. Both produce
/// identical digests, so a finding ID computed in CI matches one computed on a
/// device.
public struct FireHasher: Sendable {
    #if canImport(CryptoKit)
    private var backing = CryptoKit.SHA256()
    #else
    private var backing = PortableSHA256()
    #endif

    public init() {}

    public mutating func update(_ bytes: some Sequence<UInt8>) {
        #if canImport(CryptoKit)
        backing.update(data: Data(bytes))
        #else
        backing.update(bytes)
        #endif
    }

    public mutating func update(_ string: String) {
        update(Array(string.utf8))
    }

    public mutating func finalize() -> FireDigest {
        #if canImport(CryptoKit)
        return FireDigest(bytes: Array(backing.finalize())) ?? .zero
        #else
        return backing.finalize()
        #endif
    }

    /// One-shot convenience.
    public static func hash(_ bytes: some Sequence<UInt8>) -> FireDigest {
        var stream = FireHasher()
        stream.update(bytes)
        return stream.finalize()
    }

    public static func hash(_ string: String) -> FireDigest {
        hash(Array(string.utf8))
    }
}

extension FireDigest {
    /// Fallback used only where a digest is structurally guaranteed, so the
    /// hashing path contains no force unwrap (§16.4).
    static let zero = FireDigest(unchecked: [UInt8](repeating: 0, count: FireDigest.byteCount))
}

/// A dependency-free SHA-256 (FIPS 180-4) used off Apple platforms and as the
/// reference implementation in tests.
public struct PortableSHA256: Sendable {
    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    public init() { buffer.reserveCapacity(64) }

    public mutating func update(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            buffer.append(byte)
            byteCount &+= 1
            if buffer.count == 64 {
                compress(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }

    public mutating func finalize() -> FireDigest {
        let bitCount = byteCount &* 8
        var padding: [UInt8] = [0x80]
        let remainder = Int((byteCount &+ 1) % 64)
        padding.append(contentsOf: [UInt8](repeating: 0, count: (56 - remainder + 64) % 64))
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        update(padding)

        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in state {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return FireDigest(unchecked: out)
    }

    private mutating func compress(_ block: [UInt8]) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let offset = index * 4
            schedule[index] = (UInt32(block[offset]) << 24)
                | (UInt32(block[offset + 1]) << 16)
                | (UInt32(block[offset + 2]) << 8)
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let previous15 = schedule[index - 15]
            let previous2 = schedule[index - 2]
            let s0 = Self.rotateRight(previous15, 7) ^ Self.rotateRight(previous15, 18) ^ (previous15 >> 3)
            let s1 = Self.rotateRight(previous2, 17) ^ Self.rotateRight(previous2, 19) ^ (previous2 >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in 0..<64 {
            let sigma1 = Self.rotateRight(e, 6) ^ Self.rotateRight(e, 11) ^ Self.rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sigma1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
            let sigma0 = Self.rotateRight(a, 2) ^ Self.rotateRight(a, 13) ^ Self.rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sigma0 &+ majority

            h = g; g = f; f = e
            e = d &+ temp1
            d = c; c = b; b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
