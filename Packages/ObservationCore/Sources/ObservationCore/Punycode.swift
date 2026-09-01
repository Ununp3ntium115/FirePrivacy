import Foundation

/// Punycode (RFC 3492) used to canonicalize internationalized host names to
/// their ASCII form before matching (§9.4).
///
/// Two hosts that differ only in Unicode form must produce the same match
/// result, and a homograph host must never accidentally match a rule written for
/// the ASCII original — both properties are tested in `DomainNormalizerTests`.
public enum Punycode {
    private static let base: UInt32 = 36
    private static let tmin: UInt32 = 1
    private static let tmax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700
    private static let initialBias: UInt32 = 72
    private static let initialN: UInt32 = 128
    private static let delimiter: Character = "-"

    /// ASCII Compatible Encoding prefix for an encoded label.
    public static let acePrefix = "xn--"

    /// Encodes one label. Returns `nil` on arithmetic overflow or invalid input.
    public static func encode(label: String) -> String? {
        let input = Array(label.unicodeScalars).map(\.value)
        var output: [Character] = []
        for scalar in input where scalar < 0x80 {
            guard let unicodeScalar = Unicode.Scalar(scalar) else { return nil }
            output.append(Character(unicodeScalar))
        }
        let basicCount = UInt32(output.count)
        var handled = basicCount
        if basicCount > 0 { output.append(delimiter) }

        var n = initialN
        var delta: UInt32 = 0
        var bias = initialBias

        while handled < UInt32(input.count) {
            var minimum = UInt32.max
            for scalar in input where scalar >= n { minimum = min(minimum, scalar) }
            guard minimum != .max else { return nil }
            let (scaled, scaleOverflow) = (minimum - n).multipliedReportingOverflow(by: handled + 1)
            guard !scaleOverflow else { return nil }
            let (advanced, addOverflow) = delta.addingReportingOverflow(scaled)
            guard !addOverflow else { return nil }
            delta = advanced
            n = minimum

            for scalar in input {
                if scalar < n {
                    let (incremented, overflow) = delta.addingReportingOverflow(1)
                    guard !overflow else { return nil }
                    delta = incremented
                }
                guard scalar == n else { continue }

                var q = delta
                var k = base
                while true {
                    let t = threshold(k: k, bias: bias)
                    if q < t { break }
                    let digit = t + ((q - t) % (base - t))
                    guard let character = digitCharacter(digit) else { return nil }
                    output.append(character)
                    q = (q - t) / (base - t)
                    k += base
                }
                guard let character = digitCharacter(q) else { return nil }
                output.append(character)
                bias = adapt(delta: delta, numberOfPoints: handled + 1, isFirst: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    /// Decodes one label body (without the `xn--` prefix). Used for display only.
    public static func decode(labelBody: String) -> String? {
        var n = initialN
        var i: UInt32 = 0
        var bias = initialBias
        var output: [UInt32] = []

        var encoded = Substring(labelBody)
        if let lastDelimiter = labelBody.lastIndex(of: delimiter) {
            for character in labelBody[labelBody.startIndex..<lastDelimiter] {
                guard character.isASCII, let scalar = character.unicodeScalars.first else { return nil }
                output.append(scalar.value)
            }
            encoded = labelBody[labelBody.index(after: lastDelimiter)...]
        }

        var index = encoded.startIndex
        while index < encoded.endIndex {
            let previousI = i
            var weight: UInt32 = 1
            var k = base
            while true {
                guard index < encoded.endIndex, let digit = digitValue(encoded[index]) else { return nil }
                index = encoded.index(after: index)
                let (scaled, scaleOverflow) = digit.multipliedReportingOverflow(by: weight)
                guard !scaleOverflow else { return nil }
                let (advanced, addOverflow) = i.addingReportingOverflow(scaled)
                guard !addOverflow else { return nil }
                i = advanced
                let t = threshold(k: k, bias: bias)
                if digit < t { break }
                let (nextWeight, weightOverflow) = weight.multipliedReportingOverflow(by: base - t)
                guard !weightOverflow else { return nil }
                weight = nextWeight
                k += base
            }
            let count = UInt32(output.count) + 1
            bias = adapt(delta: i - previousI, numberOfPoints: count, isFirst: previousI == 0)
            let (increment, incrementOverflow) = n.addingReportingOverflow(i / count)
            guard !incrementOverflow else { return nil }
            n = increment
            i %= count
            guard Unicode.Scalar(n) != nil, i <= UInt32(output.count) else { return nil }
            output.insert(n, at: Int(i))
            i += 1
        }

        var result = String.UnicodeScalarView()
        for value in output {
            guard let scalar = Unicode.Scalar(value) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }

    private static func threshold(k: UInt32, bias: UInt32) -> UInt32 {
        if k <= bias { return tmin }
        if k >= bias + tmax { return tmax }
        return k - bias
    }

    private static func adapt(delta: UInt32, numberOfPoints: UInt32, isFirst: Bool) -> UInt32 {
        var delta = isFirst ? delta / damp : delta / 2
        delta += delta / numberOfPoints
        var k: UInt32 = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= base - tmin
            k += base
        }
        return k + (base - tmin + 1) * delta / (delta + skew)
    }

    private static func digitCharacter(_ digit: UInt32) -> Character? {
        switch digit {
        case 0..<26:
            return Character(Unicode.Scalar(UInt8(digit) + UInt8(ascii: "a")))
        case 26..<36:
            return Character(Unicode.Scalar(UInt8(digit - 26) + UInt8(ascii: "0")))
        default:
            return nil
        }
    }

    private static func digitValue(_ character: Character) -> UInt32? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt32(ascii - UInt8(ascii: "a"))
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt32(ascii - UInt8(ascii: "A"))
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(ascii - UInt8(ascii: "0")) + 26
        default: return nil
        }
    }
}
