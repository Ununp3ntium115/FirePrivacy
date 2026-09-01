import Foundation

/// A parsed JSON value.
///
/// Fire Privacy parses report lines with its own parser rather than
/// `JSONSerialization` so that the limits in IMP-003/IMP-004 are enforced *while
/// parsing*: nesting depth, string length, duplicate keys and invalid UTF-8 are
/// all structural decisions, and a line that violates them is quarantined with a
/// reason instead of being partially believed.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        default: nil
        }
    }

    /// Integer value, accepting the numeric spellings seen in real exports
    /// (`3`, `3.0`, `"3"`). Returns `nil` rather than rounding a real fraction.
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.isFinite, value == value.rounded(), value >= Double(Int.min), value <= Double(Int.max) else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespaces))
        case .bool, .null, .array, .object:
            return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let value): value
        default: nil
        }
    }

    /// Reads the first present key from `keys`, so the decoder tolerates the
    /// several spellings Apple and re-emitting tools have used.
    public func first(of keys: [String]) -> JSONValue? {
        guard let object = objectValue else { return nil }
        for key in keys {
            if let value = object[key], value != .null { return value }
        }
        return nil
    }
}

/// A JSON parser with explicit structural limits.
public struct JSONParser: Sendable {
    public struct Options: Sendable {
        public var maximumDepth: Int
        public var maximumStringBytes: Int

        public init(maximumDepth: Int, maximumStringBytes: Int) {
            self.maximumDepth = maximumDepth
            self.maximumStringBytes = maximumStringBytes
        }

        public init(limits: ImportLimits) {
            self.init(maximumDepth: limits.maximumNestingDepth, maximumStringBytes: limits.maximumStringFieldBytes)
        }
    }

    public struct Output: Sendable {
        public let value: JSONValue
        /// Number of string fields that hit the length limit and were truncated.
        public let truncatedFieldCount: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case empty
        case unexpectedEnd
        case unexpectedByte(offset: Int)
        case depthExceeded
        case invalidNumber
        case invalidEscape
        case invalidUTF8
        case duplicateKey
        case trailingData(offset: Int)
    }

    private let options: Options
    private let bytes: [UInt8]
    private var index = 0
    private var truncatedFieldCount = 0

    private init(bytes: [UInt8], options: Options) {
        self.bytes = bytes
        self.options = options
    }

    public static func parse(_ bytes: [UInt8], options: Options) throws -> Output {
        var parser = JSONParser(bytes: bytes, options: options)
        return try parser.run()
    }

    private mutating func run() throws -> Output {
        skipWhitespace()
        guard index < bytes.count else { throw Failure.empty }
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw Failure.trailingData(offset: index) }
        return Output(value: value, truncatedFieldCount: truncatedFieldCount)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= options.maximumDepth else { throw Failure.depthExceeded }
        skipWhitespace()
        guard index < bytes.count else { throw Failure.unexpectedEnd }

        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count else { throw Failure.unexpectedEnd }
        for (offset, byte) in expected.enumerated() where bytes[index + offset] != byte {
            throw Failure.unexpectedByte(offset: index + offset)
        }
        index += expected.count
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1 // {
        var result: [String: JSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(result)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw index < bytes.count ? Failure.unexpectedByte(offset: index) : Failure.unexpectedEnd
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw index < bytes.count ? Failure.unexpectedByte(offset: index) : Failure.unexpectedEnd
            }
            index += 1
            let value = try parseValue(depth: depth + 1)
            // A duplicate key means the line is ambiguous. Ambiguous evidence is
            // quarantined rather than resolved by a guess.
            guard result.updateValue(value, forKey: key) == nil else { throw Failure.duplicateKey }
            skipWhitespace()
            guard index < bytes.count else { throw Failure.unexpectedEnd }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(result)
            default: throw Failure.unexpectedByte(offset: index)
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1 // [
        var result: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(result)
        }
        while true {
            let value = try parseValue(depth: depth + 1)
            result.append(value)
            skipWhitespace()
            guard index < bytes.count else { throw Failure.unexpectedEnd }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(result)
            default: throw Failure.unexpectedByte(offset: index)
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var scalars: [UInt8] = []
        var truncated = false

        while true {
            guard index < bytes.count else { throw Failure.unexpectedEnd }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let text = String(bytes: scalars, encoding: .utf8) else { throw Failure.invalidUTF8 }
                if truncated { truncatedFieldCount += 1 }
                return text
            case UInt8(ascii: "\\"):
                index += 1
                try appendEscape(into: &scalars, truncated: &truncated)
            case 0x00...0x1F:
                // Raw control characters are not legal inside a JSON string.
                throw Failure.unexpectedByte(offset: index)
            default:
                index += 1
                append(byte, into: &scalars, truncated: &truncated)
            }
        }
    }

    private mutating func append(_ byte: UInt8, into scalars: inout [UInt8], truncated: inout Bool) {
        if scalars.count >= options.maximumStringBytes {
            truncated = true
            return
        }
        scalars.append(byte)
    }

    private mutating func appendEscape(into scalars: inout [UInt8], truncated: inout Bool) throws {
        guard index < bytes.count else { throw Failure.unexpectedEnd }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""): append(UInt8(ascii: "\""), into: &scalars, truncated: &truncated)
        case UInt8(ascii: "\\"): append(UInt8(ascii: "\\"), into: &scalars, truncated: &truncated)
        case UInt8(ascii: "/"): append(UInt8(ascii: "/"), into: &scalars, truncated: &truncated)
        case UInt8(ascii: "b"): append(0x08, into: &scalars, truncated: &truncated)
        case UInt8(ascii: "f"): append(0x0C, into: &scalars, truncated: &truncated)
        case UInt8(ascii: "n"): append(0x0A, into: &scalars, truncated: &truncated)
        case UInt8(ascii: "r"): append(0x0D, into: &scalars, truncated: &truncated)
        case UInt8(ascii: "t"): append(0x09, into: &scalars, truncated: &truncated)
        case UInt8(ascii: "u"):
            let scalar = try parseUnicodeEscape()
            for byte in Array(String(Character(scalar)).utf8) {
                append(byte, into: &scalars, truncated: &truncated)
            }
        default:
            throw Failure.invalidEscape
        }
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try readHex4()
        if first >= 0xD800, first <= 0xDBFF {
            // High surrogate: a low surrogate must follow.
            guard index + 1 < bytes.count,
                  bytes[index] == UInt8(ascii: "\\"),
                  bytes[index + 1] == UInt8(ascii: "u")
            else { throw Failure.invalidEscape }
            index += 2
            let second = try readHex4()
            guard second >= 0xDC00, second <= 0xDFFF else { throw Failure.invalidEscape }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { throw Failure.invalidEscape }
            return scalar
        }
        guard let scalar = Unicode.Scalar(first) else { throw Failure.invalidEscape }
        return scalar
    }

    private mutating func readHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw Failure.unexpectedEnd }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: throw Failure.invalidEscape
            }
            value = value << 4 | digit
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        var isInteger = true
        var sawDigit = false
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                sawDigit = true
                index += 1
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                isInteger = false
                index += 1
            default:
                guard sawDigit else { throw Failure.invalidNumber }
                return try makeNumber(from: start, isInteger: isInteger)
            }
        }
        guard sawDigit else { throw Failure.invalidNumber }
        return try makeNumber(from: start, isInteger: isInteger)
    }

    private func makeNumber(from start: Int, isInteger: Bool) throws -> JSONValue {
        guard let text = String(bytes: bytes[start..<index], encoding: .utf8) else { throw Failure.invalidNumber }
        if isInteger {
            // A value too large for Int is kept as a Double rather than
            // overflowing; hit counts above Int.max are not real counts.
            if let value = Int(text) { return .int(value) }
        }
        guard let value = Double(text), value.isFinite else { throw Failure.invalidNumber }
        return .double(value)
    }
}
