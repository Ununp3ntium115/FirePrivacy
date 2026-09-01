import Foundation
import ObservationCore

/// Reads a newline-delimited JSON file one line at a time.
///
/// The reader never materializes the whole file: a 250 MB report is processed in
/// fixed-size chunks with one line held at a time (IMP-003). A line longer than
/// the limit is reported and skipped rather than truncated, because a truncated
/// JSON object cannot be validated and a "best effort" parse of one would invent
/// evidence.
public struct NDJSONReader: Sendable {
    public enum Event: Sendable {
        case line(number: Int, bytes: [UInt8])
        case oversizeLine(number: Int)
    }

    public struct Summary: Sendable {
        public let bytesRead: Int
        public let lineCount: Int
    }

    /// Bytes requested per read. Chosen so peak memory stays far below the
    /// 150 MB import budget (§18.1) regardless of file size.
    public static let chunkSize = 256 * 1024

    public let limits: ImportLimits

    public init(limits: ImportLimits = .default) {
        self.limits = limits
    }

    /// Streams `url`, calling `handler` for every line.
    ///
    /// `handler` is called on the caller's task. Progress is reported after each
    /// chunk so the UI stays responsive and cancellable (§11.2, screen 6).
    public func read(
        url: URL,
        onChunk: (_ bytesRead: Int) throws -> Void = { _ in },
        handler: (Event) throws -> Bool
    ) throws -> Summary {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ImportError.unreadableFile
        }
        defer { try? handle.close() }

        var pending: [UInt8] = []
        pending.reserveCapacity(4096)
        var lineNumber = 0
        var bytesRead = 0
        var currentLineOversize = false
        var shouldContinue = true

        func flush(force: Bool) throws {
            guard force || !pending.isEmpty || currentLineOversize else { return }
            lineNumber += 1
            if currentLineOversize {
                shouldContinue = try handler(.oversizeLine(number: lineNumber))
            } else {
                shouldContinue = try handler(.line(number: lineNumber, bytes: pending))
            }
            pending.removeAll(keepingCapacity: true)
            currentLineOversize = false
        }

        while shouldContinue {
            if Task.isCancelled { throw ImportError.cancelled }
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            bytesRead += chunk.count

            for byte in chunk {
                if byte == 0x0A { // \n
                    // An empty line between records is not an error.
                    if pending.isEmpty, !currentLineOversize {
                        lineNumber += 1
                        continue
                    }
                    try flush(force: false)
                    if !shouldContinue { break }
                    continue
                }
                if byte == 0x0D { continue } // tolerate CRLF
                if currentLineOversize { continue }
                if pending.count >= limits.maximumLineBytes {
                    currentLineOversize = true
                    pending.removeAll(keepingCapacity: true)
                    continue
                }
                pending.append(byte)
            }
            try onChunk(bytesRead)
        }

        if shouldContinue, !pending.isEmpty || currentLineOversize {
            try flush(force: true)
        }
        return Summary(bytesRead: bytesRead, lineCount: lineNumber)
    }

    /// Computes the SHA-256 of a file without holding it in memory (IMP-006).
    public static func hashFile(at url: URL) throws -> (digest: FireDigest, byteCount: Int, prefix: [UInt8]) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ImportError.unreadableFile
        }
        defer { try? handle.close() }

        var hasher = FireHasher()
        var byteCount = 0
        var prefix: [UInt8] = []
        while true {
            if Task.isCancelled { throw ImportError.cancelled }
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            byteCount += chunk.count
            if prefix.count < 64 { prefix.append(contentsOf: chunk.prefix(64 - prefix.count)) }
            hasher.update(chunk)
        }
        return (hasher.finalize(), byteCount, prefix)
    }
}
