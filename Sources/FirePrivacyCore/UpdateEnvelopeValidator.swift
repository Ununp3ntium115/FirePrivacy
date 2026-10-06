import Foundation

/// Validate the bounded raw update container before Foundation collapses its
/// object keys. Base64 payload contents remain opaque until their own signature
/// and digest verification. The typed decoder still validates JSON syntax/schema.
public enum UpdateEnvelopeValidator {
    public enum Failure: Error, Equatable, Sendable { case oversized, invalidUTF8, malformedShape }
    public static let maximumDocumentBytes = 8 * 1_024 * 1_024

    public static func validate(_ data: Data, maximumBytes: Int = maximumDocumentBytes) throws {
        guard maximumBytes > 0, maximumBytes <= maximumDocumentBytes,
              !data.isEmpty, data.count <= maximumBytes else { throw Failure.oversized }
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidUTF8 }
        do {
            try RuleConfigurationJSON.validateShape(data, maximumDepth: 8,
                maximumStringBytes: maximumBytes, maximumObjects: 128, maximumKeys: 80, maximumKeyBytes: 256)
        } catch { throw Failure.malformedShape }
    }
}
