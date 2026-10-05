import Foundation

public enum ReportImporter {
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static let maximumLineBytes = 64 * 1_024
    public static let maximumRecords = 100_000
    public static let maximumNestingDepth = 12

    public enum ImportError: Error, LocalizedError, Equatable, Sendable {
        case fileTooLarge
        case tooManyRecords
        case noRecognizedRecords(issues: Int)

        public var errorDescription: String? {
            switch self {
            case .fileTooLarge: "Choose a report smaller than 16 MB."
            case .tooManyRecords: "This report exceeds the limit of 100,000 nonempty records."
            case .noRecognizedRecords(let issues): "No supported App Privacy Report records were found. \(issues) line(s) could not be imported. Export the report from Settings > Privacy & Security > App Privacy Report."
            }
        }
    }

    /// Imports only supported exported event records. Invalid lines are quarantined
    /// without copying their sensitive contents into error messages.
    public static func parse(_ data: Data, importedAt: Date = Date(), sourceFilename: String? = nil) throws -> PrivacyReport {
        guard data.count <= maximumFileBytes else { throw ImportError.fileTooLarge }
        var observations: [Observation] = []
        var issues: [ImportIssue] = []
        var nonemptyRecords = 0
        var contactTotal = 0
        let timestamps = TimestampParser()
        let sourceDigest = ContentDigest.sha256(data)

        var position = data.startIndex
        var lineNumber = 0
        while position < data.endIndex {
            let lineEnd = data[position..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
            var line = Data(data[position..<lineEnd])
            let lineDigest = ContentDigest.sha256(line)
            position = lineEnd == data.endIndex ? data.endIndex : lineEnd + 1
            lineNumber += 1
            if lineNumber == 1, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }
            nonemptyRecords += 1
            guard nonemptyRecords <= maximumRecords else { throw ImportError.tooManyRecords }
            do {
                guard line.count <= maximumLineBytes else { throw LineError("Line exceeds the 64 KB limit.") }
                guard String(data: line, encoding: .utf8) != nil else { throw LineError("Line is not valid UTF-8.") }
                var validator = BoundedJSONValidator(bytes: Array(line))
                try validator.validate()
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw LineError("Expected one JSON object per line.")
                }
                let observation = try parseRecord(object, rawNumbers: validator.topLevelNumbers, timestamps: timestamps,
                    id: ContentDigest.stableID("FirePrivacy/Observation/v2|\(sourceDigest)|\(lineNumber)|\(lineDigest)"),
                    sourceLine: lineNumber, lineDigest: lineDigest)
                if observation.category == .network {
                    let (nextTotal, overflow) = contactTotal.addingReportingOverflow(observation.count)
                    guard !overflow else { throw LineError("Contact total exceeds the supported integer range.") }
                    contactTotal = nextTotal
                }
                observations.append(observation)
            } catch let error as LineError {
                issues.append(ImportIssue(message: error.message, line: lineNumber))
            } catch {
                issues.append(ImportIssue(message: "Line is not valid JSON.", line: lineNumber))
            }
        }
        guard !observations.isEmpty else { throw ImportError.noRecognizedRecords(issues: issues.count) }
        let times = observations.flatMap { [$0.timestamp, $0.firstTimestamp, $0.lastTimestamp].compactMap { $0 } }
        let filename = sourceFilename?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        let metadata = ReportMetadata(sourceSHA256: sourceDigest, sourceFilename: filename,
            reportStart: times.min(), reportEnd: times.max(), status: issues.isEmpty ? .complete : .partial,
            recognizedRecords: observations.count, skippedRecords: issues.count)
        return PrivacyReport(id: ContentDigest.stableID("FirePrivacy/Report/v2|" + sourceDigest), importedAt: importedAt,
                             observations: observations, issues: issues, metadata: metadata)
    }

    private static func parseRecord(_ object: [String: Any], rawNumbers: [String: String], timestamps: TimestampParser,
                                    id: UUID, sourceLine: Int, lineDigest: String) throws -> Observation {
        guard let type = object["type"] as? String, type == "networkActivity" || type == "access" else {
            throw LineError("Unsupported record type. Only networkActivity and access events are imported.")
        }
        let nestedID = try accessorBundleID(object)
        let topLevelID: String?
        if let value = object["bundleID"] {
            guard let string = value as? String, isSafeIdentifier(string) else {
                throw LineError("Unsupported top-level app bundle identifier.")
            }
            topLevelID = string
        } else {
            topLevelID = nil
        }
        if let topLevelID, let nestedID, topLevelID != nestedID {
            throw LineError("Conflicting app bundle identifiers in the same record.")
        }
        guard let bundleID = type == "access" ? nestedID : (topLevelID ?? nestedID) else {
            throw LineError("Missing or unsupported app bundle identifier.")
        }
        var warnings: [String] = []
        let context = optionalText(object, key: "context", warnings: &warnings)
        let owner = optionalText(object, key: "domainOwner", warnings: &warnings)
        let domainType = reportedValue(object, key: "domainType", rawNumbers: rawNumbers, warnings: &warnings)
        let initiatedType = reportedValue(object, key: "initiatedType", rawNumbers: rawNumbers, warnings: &warnings)
        let classification = reportedValue(object, key: "domainClassification", rawNumbers: rawNumbers, warnings: &warnings)

        if type == "networkActivity" {
            guard let originalDomain = object["domain"] as? String,
                  let domain = normalizedDomain(originalDomain) else {
                throw LineError("Missing or unsupported domain name.")
            }
            if domain != originalDomain { warnings.append("Domain spelling was normalized to its canonical host identity.") }
            guard let count = nonnegativeInteger(rawNumbers["hits"]) else {
                throw LineError("Network hits must be a nonnegative integer in the supported range.")
            }
            let first = try timestamps.read(object, key: "firstTimeStamp")
            let last = try timestamps.read(object, key: "lastTimeStamp")
            let single = try timestamps.read(object, key: "timeStamp")
            if let firstInstant = first.instant, let lastInstant = last.instant ?? single.instant, firstInstant > lastInstant {
                throw LineError("The first timestamp is later than the last timestamp.")
            }
            return Observation(
                id: id, bundleID: bundleID, domain: domain, category: .network,
                accessType: type, count: count, timestamp: last.date ?? single.date ?? first.date,
                firstTimestamp: first.date, lastTimestamp: last.date,
                timestampText: single.text, firstTimestampText: first.text, lastTimestampText: last.text,
                provenance: ObservationProvenance(sourceLine: sourceLine, sourceSHA256: lineDigest, normalizationWarnings: warnings),
                context: context, domainOwner: owner, domainType: domainType, initiatedType: initiatedType,
                domainClassification: classification, originalDomain: originalDomain
            )
        }

        guard let category = object["category"] as? String, isSafeIdentifier(category) else {
            throw LineError("Missing or unsupported sensor category.")
        }
        // Retain Apple's category rather than guessing a permission or risk class.
        let kind: String?
        if let value = object["kind"] {
            guard let string = value as? String, isSafeIdentifier(string) else {
                throw LineError("Unsupported sensor event kind.")
            }
            kind = string
        } else {
            kind = nil
        }
        let timestamp = try timestamps.read(object, key: "timeStamp")
        let sensorIdentifier = exactIdentifier(object, key: "identifier", warnings: &warnings)
        return Observation(
            id: id, bundleID: bundleID, category: .sensor, accessType: category,
            count: 1, timestamp: timestamp.date, timestampText: timestamp.text, eventKind: kind,
            provenance: ObservationProvenance(sourceLine: sourceLine, sourceSHA256: lineDigest, normalizationWarnings: warnings),
            context: context, domainOwner: owner, domainType: domainType, initiatedType: initiatedType,
            domainClassification: classification, sensorIdentifier: sensorIdentifier
        )
    }

    private static func optionalText(_ object: [String: Any], key: String, warnings: inout [String]) -> String? {
        guard let raw = object[key] else { return nil }
        guard let text = raw as? String else { warnings.append("Unsupported \(key) value was omitted."); return nil }
        let safe = ImportedText.sanitize(text)
        if safe != text { warnings.append("\(key) contained hidden characters or exceeded the display limit.") }
        return safe.isEmpty ? nil : safe
    }

    private static func exactIdentifier(_ object: [String: Any], key: String, warnings: inout [String]) -> String? {
        guard let raw = object[key] else { return nil }
        guard let text = raw as? String, !text.isEmpty,
              ImportedText.sanitize(text) == text else {
            warnings.append("Unsupported sensor identifier was omitted; it cannot be used for interval pairing.")
            return nil
        }
        return text
    }

    private static func reportedValue(_ object: [String: Any], key: String, rawNumbers: [String: String],
                                      warnings: inout [String]) -> ReportedValue? {
        guard let value = object[key] else { return nil }
        if let token = rawNumbers[key] {
            guard token.utf8.count <= 128 else { warnings.append("Unsupported \(key) numeric length was omitted."); return nil }
            return Int(token).map(ReportedValue.integer) ?? .number(token)
        }
        if let text = value as? String {
            let safe = ImportedText.sanitize(text)
            if safe != text { warnings.append("\(key) contained hidden characters or exceeded the display limit.") }
            return .text(safe)
        }
        if value is NSNull { return .null }
        if let bool = value as? Bool { return .boolean(bool) }
        warnings.append("Unsupported \(key) structure was omitted.")
        return nil
    }

    private static func accessorBundleID(_ object: [String: Any]) throws -> String? {
        guard let value = object["accessor"] else { return nil }
        guard let accessor = value as? [String: Any],
              let bundleID = accessor["identifier"] as? String,
              isSafeIdentifier(bundleID) else {
            throw LineError("Missing or unsupported accessor app bundle identifier.")
        }
        if let identifierType = accessor["identifierType"] {
            guard let value = identifierType as? String, value == "bundleID" else {
                throw LineError("The accessor is not an app bundle identifier.")
            }
        }
        return bundleID
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
            ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 45 || $0 == 95
        }
    }

    private static func normalizedDomain(_ value: String) -> String? {
        guard ImportedText.sanitize(value, maximumCharacters: 4_096) == value else { return nil }
        if let identity = DomainIdentity(value) { return identity.value }
        // Preserve earlier strictly ASCII destination compatibility, including
        // single-label names and IPv4 literals. A failed DomainIdentity has no
        // registrable-domain assertion and cannot match a PSL owner.
        guard !value.isEmpty, value.utf8.count <= 253 else { return nil }
        let normalized = value.lowercased()
        guard normalized.utf8.allSatisfy({
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46
        }) else { return nil }
        let withoutRootDot = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        guard !withoutRootDot.isEmpty, withoutRootDot.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
        }) else { return nil }
        return withoutRootDot
    }

    private static func nonnegativeInteger(_ text: String?) -> Int? {
        guard let text, text.utf8.count <= 64 else { return nil }
        if let integer = Int(text) { return integer >= 0 ? integer : nil }
        // Parse the validated JSON token using decimal digits. NSNumber and Decimal
        // can round a large integer or a tiny fractional remainder on some platforms.
        let negative = text.hasPrefix("-")
        let unsigned = negative ? String(text.dropFirst()) : text
        let pieces = unsigned.split(whereSeparator: { $0 == "e" || $0 == "E" })
        guard let mantissa = pieces.first else { return nil }
        let exponent: Int
        if pieces.count == 2 {
            guard let parsed = Int(pieces[1]), (-1_000...1_000).contains(parsed) else { return nil }
            exponent = parsed
        } else {
            exponent = 0
        }
        let decimalParts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let fractionLength = decimalParts.count == 2 ? decimalParts[1].count : 0
        var digits = String(decimalParts.joined()).drop(while: { $0 == "0" })
        if digits.isEmpty { return 0 }
        guard !negative else { return nil }
        let shift = exponent - fractionLength
        if shift < 0 {
            guard -shift < digits.count, digits.suffix(-shift).allSatisfy({ $0 == "0" }) else { return nil }
            digits = digits.dropLast(-shift)
        }
        guard digits.count + max(shift, 0) <= String(Int.max).count else { return nil }
        return Int(String(digits) + String(repeating: "0", count: max(shift, 0)))
    }
}

private struct LineError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct TimestampParser {
    private let whole: ISO8601DateFormatter

    init() {
        whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
    }

    func read(_ object: [String: Any], key: String) throws -> (date: Date?, text: String?, instant: ExactExportTimestamp?) {
        guard let value = object[key] else { return (nil, nil, nil) }
        guard let text = value as? String, text.utf8.count <= 64,
              text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil,
              hasValidCalendarFields(text) else {
            throw LineError("A timestamp is not supported ISO 8601 text.")
        }
        let bytes = Array(text.utf8)
        var zoneIndex = 19
        var nanoseconds = 0
        if bytes[zoneIndex] == 46 {
            zoneIndex += 1
            let beginning = zoneIndex
            while (48...57).contains(bytes[zoneIndex]) {
                nanoseconds = nanoseconds * 10 + Int(bytes[zoneIndex] - 48)
                zoneIndex += 1
            }
            for _ in (zoneIndex - beginning)..<9 { nanoseconds *= 10 }
        }
        let wholeText = String(text.prefix(19)) + String(decoding: bytes[zoneIndex...], as: UTF8.self)
        guard let base = whole.date(from: wholeText) else { throw LineError("A timestamp is not supported ISO 8601 text.") }
        let instant = ExactExportTimestamp(seconds: Int64(base.timeIntervalSince1970), nanoseconds: nanoseconds)
        return (instant.date, text, instant)
    }

    private func hasValidCalendarFields(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func integer(_ range: Range<Int>) -> Int? { Int(String(decoding: bytes[range], as: UTF8.self)) }
        guard let year = integer(0..<4), year > 0,
              let month = integer(5..<7), (1...12).contains(month),
              let day = integer(8..<10), day > 0,
              let hour = integer(11..<13), (0...23).contains(hour),
              let minute = integer(14..<16), (0...59).contains(minute),
              let second = integer(17..<19), (0...59).contains(second) else { return false }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= monthLengths[month - 1] else { return false }
        if !text.hasSuffix("Z") {
            let beginning = bytes.count - 6
            guard let zoneHour = integer((beginning + 1)..<(beginning + 3)), zoneHour <= 23,
                  let zoneMinute = integer((beginning + 4)..<(beginning + 6)), zoneMinute <= 59 else { return false }
        }
        return true
    }
}

/// Validates structure before Foundation can allocate an arbitrarily nested graph.
/// Duplicate keys are rejected rather than accepting a parser's last-value choice.
private struct BoundedJSONValidator {
    let bytes: [UInt8]
    private(set) var topLevelNumbers: [String: String] = [:]
    private var index = 0
    private let maximumStringBytes = 4_096

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw LineError("Unexpected data after the JSON value.") }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= ReportImporter.maximumNestingDepth else { throw LineError("JSON nesting exceeds the supported limit.") }
        whitespace()
        guard index < bytes.count else { throw LineError("Incomplete JSON value.") }
        switch bytes[index] {
        case 0x7B: try object(depth: depth)
        case 0x5B: try array(depth: depth)
        case 0x22: _ = try string()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        case 0x2D, 0x30...0x39: try number()
        default: throw LineError("Invalid JSON value.")
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        whitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            whitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw LineError("JSON object contains a duplicate key.") }
            guard keys.count <= 128 else { throw LineError("JSON object exceeds the field limit.") }
            whitespace()
            guard consume(0x3A) else { throw LineError("Missing JSON field separator.") }
            whitespace()
            let valueBeginning = index
            try value(depth: depth + 1)
            if depth == 0, valueBeginning < bytes.count,
               bytes[valueBeginning] == 0x2D || (0x30...0x39).contains(bytes[valueBeginning]) {
                topLevelNumbers[key] = String(decoding: bytes[valueBeginning..<index], as: UTF8.self)
            }
            whitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw LineError("Missing JSON object separator.") }
        }
    }

    private mutating func array(depth: Int) throws {
        index += 1
        whitespace()
        if consume(0x5D) { return }
        var elements = 0
        while true {
            elements += 1
            guard elements <= 128 else { throw LineError("JSON array exceeds the element limit.") }
            try value(depth: depth + 1)
            whitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw LineError("Missing JSON array separator.") }
        }
    }

    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 0x22 else { throw LineError("Expected a JSON string.") }
        let beginning = index
        index += 1
        while index < bytes.count {
            guard index - beginning <= maximumStringBytes else { throw LineError("JSON string exceeds the length limit.") }
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                let data = Data(bytes[beginning..<index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: data) else { throw LineError("Invalid JSON string encoding.") }
                return decoded
            }
            guard byte >= 0x20 else { throw LineError("Unescaped control character in JSON string.") }
            if byte == 0x5C {
                guard index < bytes.count else { throw LineError("Incomplete JSON escape.") }
                let escaped = bytes[index]
                index += 1
                if escaped == 0x75 {
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy({
                              (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
                          }) else { throw LineError("Invalid JSON Unicode escape.") }
                    index += 4
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    throw LineError("Invalid JSON escape.")
                }
            }
        }
        throw LineError("Unterminated JSON string.")
    }

    private mutating func number() throws {
        _ = consume(0x2D)
        guard index < bytes.count else { throw LineError("Incomplete JSON number.") }
        if !consume(0x30) {
            guard (0x31...0x39).contains(bytes[index]) else { throw LineError("Invalid JSON number.") }
            digits()
        }
        if consume(0x2E) {
            let before = index
            digits()
            guard index > before else { throw LineError("Invalid JSON fraction.") }
        }
        if consume(0x65) || consume(0x45) {
            _ = consume(0x2B) || consume(0x2D)
            let before = index
            digits()
            guard index > before else { throw LineError("Invalid JSON exponent.") }
        }
    }

    private mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else { throw LineError("Invalid JSON literal.") }
        index += expected.count
    }

    private mutating func digits() {
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
    }

    private mutating func whitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0D, 0x0A].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
