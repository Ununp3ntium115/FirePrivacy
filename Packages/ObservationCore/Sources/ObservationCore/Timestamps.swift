import Foundation

/// Parses the timestamp spellings that appear in App Privacy Report exports.
///
/// Apple has used ISO 8601 with and without fractional seconds, with `Z` and
/// with numeric offsets; some third-party tooling re-emits the report with epoch
/// seconds. All are accepted, and anything else is reported as a warning rather
/// than failing the record — a domain contact with an unparsable timestamp is
/// still evidence that the contact happened (IMP-004).
///
/// The parser is hand-written rather than formatter-based so that it is
/// deterministic across locales, calendars and time zones: the same file must
/// produce the same findings on every device (DET-012).
public enum TimestampParser {
    /// Timestamps outside this range are treated as corrupt rather than stored,
    /// which keeps a bogus far-future date out of report windows.
    public static let earliestPlausible = Date(timeIntervalSince1970: 1_262_304_000) // 2010-01-01
    public static let latestPlausibleOffset: TimeInterval = 60 * 60 * 24 * 365 // one year ahead

    public static func parse(_ raw: String, now: Date = Date()) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }

        if let seconds = Double(trimmed), seconds.isFinite {
            // Milliseconds are common in re-emitted reports; disambiguate by range.
            let candidate = abs(seconds) > 100_000_000_000 ? seconds / 1000 : seconds
            return validate(Date(timeIntervalSince1970: candidate), now: now)
        }
        guard let interval = parseISO8601(trimmed) else { return nil }
        return validate(Date(timeIntervalSince1970: interval), now: now)
    }

    private static func validate(_ date: Date, now: Date) -> Date? {
        guard date >= earliestPlausible, date <= now.addingTimeInterval(latestPlausibleOffset) else { return nil }
        return date
    }

    /// Accepts `YYYY-MM-DD`, optionally followed by `T` or a space, a time, an
    /// optional fractional part and an optional `Z` or `±HH:MM` offset.
    static func parseISO8601(_ text: String) -> TimeInterval? {
        var scanner = ByteScanner(text)
        guard let year = scanner.readInteger(digits: 4), scanner.readSeparator("-"),
              let month = scanner.readInteger(digits: 2), scanner.readSeparator("-"),
              let day = scanner.readInteger(digits: 2)
        else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        var hour = 0, minute = 0, second = 0
        var fraction: TimeInterval = 0
        var offsetSeconds = 0

        if scanner.readSeparator("T") || scanner.readSeparator("t") || scanner.readSeparator(" ") {
            guard let parsedHour = scanner.readInteger(digits: 2), scanner.readSeparator(":"),
                  let parsedMinute = scanner.readInteger(digits: 2)
            else { return nil }
            hour = parsedHour
            minute = parsedMinute
            if scanner.readSeparator(":") {
                guard let parsedSecond = scanner.readInteger(digits: 2) else { return nil }
                second = parsedSecond
            }
            if scanner.readSeparator(".") || scanner.readSeparator(",") {
                guard let digits = scanner.readDigits(maximum: 9), !digits.isEmpty else { return nil }
                fraction = TimeInterval("0." + digits) ?? 0
            }
            if scanner.readSeparator("Z") || scanner.readSeparator("z") {
                offsetSeconds = 0
            } else if let sign = scanner.readSign() {
                guard let offsetHour = scanner.readInteger(digits: 2) else { return nil }
                _ = scanner.readSeparator(":")
                let offsetMinute = scanner.readInteger(digits: 2) ?? 0
                guard offsetHour <= 18, offsetMinute < 60 else { return nil }
                offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
            }
        }
        guard scanner.isAtEnd else { return nil }
        guard hour < 24, minute < 60, second <= 60 else { return nil }
        guard day <= daysInMonth(year: year, month: month) else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let total = TimeInterval(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds)
        return total + fraction
    }

    /// Days between 1970-01-01 and the given proleptic Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var year = year
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}

/// Minimal forward-only scanner over ASCII text.
struct ByteScanner {
    private let characters: [Character]
    private var index: Int = 0

    init(_ text: String) { characters = Array(text) }

    var isAtEnd: Bool { index >= characters.count }

    mutating func readInteger(digits: Int) -> Int? {
        guard index + digits <= characters.count else { return nil }
        var value = 0
        for offset in 0..<digits {
            guard let digit = characters[index + offset].wholeNumberValue, (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }
        index += digits
        return value
    }

    mutating func readDigits(maximum: Int) -> String? {
        var result = ""
        while index < characters.count, result.count < maximum, characters[index].isNumber {
            result.append(characters[index])
            index += 1
        }
        return result.isEmpty ? nil : result
    }

    mutating func readSeparator(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    mutating func readSign() -> Int? {
        guard index < characters.count else { return nil }
        switch characters[index] {
        case "+": index += 1; return 1
        case "-": index += 1; return -1
        default: return nil
        }
    }
}
