import Foundation
import CoreFoundation

public struct AppUsageEventLogWarning: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidRecord, unmatchedOpened, unmatchedClosed, duplicateOpened, outOfOrder, outsideCoverage, noEvents
    }
    public let code: Code
    public let line: Int?
    public let bundleID: String?
}
public struct AppUsageEventLogImportResult: Codable, Equatable, Sendable {
    public let timeline: AppUsageTimeline
    public let warnings: [AppUsageEventLogWarning]
    public let warningsTruncated: Bool
    public let sourceSHA256: String
    public let importedEventRecords: Int
    public let pairedWindows: Int
}

/// User-configured Shortcuts or another supplied log can record opened/closed
/// events. Their authenticity, completeness and foreground semantics remain
/// unverified; missing boundaries are never synthesized.
public enum AppUsageEventLogImporter {
    public static let maximumFileBytes = 1_024 * 1_024
    public static let maximumLineBytes = 16 * 1_024
    public static let maximumEvents = 10_000
    public enum ImportError: Error, LocalizedError, Equatable, Sendable {
        case invalidCoverage, tooManyEvents, tooManyApps, tooManyWindows
        public var errorDescription: String? {
            switch self {
            case .invalidCoverage: "The event log needs a valid coverage header with time-zone timestamps."
            case .tooManyEvents: "The event log exceeds 10,000 event records."
            case .tooManyApps: "The event log exceeds 128 apps."
            case .tooManyWindows: "The event log exceeds the supported foreground-window limits."
            }
        }
    }
    private struct OpenEvent { let instant: ExactExportTimestamp; let text: String; let line: Int }
    public static func parse(_ data: Data, suppliedAt: Date = Date()) throws -> AppUsageEventLogImportResult {
        guard data.count <= maximumFileBytes else { throw AppUsageError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw AppUsageError.invalidJSON }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { !isBlank($0) }) else { throw ImportError.invalidCoverage }
        let header: [String: Any]
        do { header = try object(Data(lines[first])) } catch { throw ImportError.invalidCoverage }
        let allowed = Set(["type", "schemaVersion", "start", "end", "claimsCompleteForegroundWindows", "deviceScope", "bundleIDs", "sourceLabel"])
        guard Set(header.keys).isSubset(of: allowed), header["type"] as? String == "coverage",
              let version = header["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let start = header["start"] as? String, let end = header["end"] as? String,
              let complete = header["claimsCompleteForegroundWindows"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID() else { throw ImportError.invalidCoverage }
        let coverage: UsageTimeRange
        do { coverage = try UsageTimeRange(startTimestampText: start, endTimestampText: end) }
        catch { throw ImportError.invalidCoverage }
        let parser = TimestampParser()
        guard let lower = try parser.read(["timeStamp": start], key: "timeStamp").instant,
              let upper = try parser.read(["timeStamp": end], key: "timeStamp").instant else { throw ImportError.invalidCoverage }
        var scope = AppUsageDeviceScope.unspecified
        if let value = header["deviceScope"] {
            guard let text = value as? String, let decoded = AppUsageDeviceScope(rawValue: text) else { throw ImportError.invalidCoverage }
            scope = decoded
        }
        var sourceLabel = "Supplied opened/closed event log"
        if let value = header["sourceLabel"] { guard let text = value as? String else { throw ImportError.invalidCoverage }; sourceLabel = ImportedText.sanitize(text, maximumCharacters: 160) }
        var apps: Set<String> = []
        if let value = header["bundleIDs"] {
            guard let identifiers = value as? [String], identifiers.count <= 128, identifiers.allSatisfy(validBundleID),
                  Set(identifiers).count == identifiers.count else { throw ImportError.invalidCoverage }
            apps = Set(identifiers)
        }
        var opened: [String: OpenEvent] = [:]
        var lastSeen: [String: ExactExportTimestamp] = [:]
        var windows: [String: [UsageTimeRange]] = [:]
        var events: [String: Int] = [:]
        var incomplete: Set<String> = []
        var globallyIncomplete = false
        var warnings: [AppUsageEventLogWarning] = []
        var truncated = false
        var processed = 0, imported = 0, paired = 0
        func warn(_ code: AppUsageEventLogWarning.Code, line: Int?, app: String?) {
            if warnings.count < 256 { warnings.append(AppUsageEventLogWarning(code: code, line: line, bundleID: app)) }
            else { truncated = true }
        }
        for index in lines.indices where index > first && !isBlank(lines[index]) {
            processed += 1
            guard processed <= maximumEvents else { throw ImportError.tooManyEvents }
            var attributedApp: String?
            do {
                let record = try object(Data(lines[index]))
                if let bundle = record["bundleID"] as? String, validBundleID(bundle) { attributedApp = bundle }
                guard Set(record.keys) == Set(["bundleID", "event", "timestamp"]), let bundleID = attributedApp,
                      let kind = record["event"] as? String, kind == "opened" || kind == "closed",
                      let text = record["timestamp"] as? String,
                      let instant = try parser.read(["timeStamp": text], key: "timeStamp").instant else { throw AppUsageError.invalidJSON }
                apps.insert(bundleID)
                guard apps.count <= 128 else { throw ImportError.tooManyApps }
                events[bundleID, default: 0] += 1
                imported += 1
                if let previous = lastSeen[bundleID], instant < previous {
                    incomplete.insert(bundleID); opened[bundleID] = nil
                    warn(.outOfOrder, line: index + 1, app: bundleID)
                    continue
                }
                lastSeen[bundleID] = instant
                guard instant >= lower, instant <= upper else {
                    incomplete.insert(bundleID); opened[bundleID] = nil
                    warn(.outsideCoverage, line: index + 1, app: bundleID)
                    continue
                }
                if kind == "opened" {
                    if opened[bundleID] != nil {
                        incomplete.insert(bundleID); opened[bundleID] = nil
                        warn(.duplicateOpened, line: index + 1, app: bundleID)
                    } else { opened[bundleID] = OpenEvent(instant: instant, text: text, line: index + 1) }
                } else if let beginning = opened.removeValue(forKey: bundleID) {
                    guard beginning.instant <= instant else { throw AppUsageError.invalidRange }
                    let window = try UsageTimeRange(startTimestampText: beginning.text, endTimestampText: text)
                    windows[bundleID, default: []].append(window)
                    paired += 1
                    guard paired <= 2_048, windows[bundleID, default: []].count <= 128 else { throw ImportError.tooManyWindows }
                } else {
                    incomplete.insert(bundleID)
                    warn(.unmatchedClosed, line: index + 1, app: bundleID)
                }
            } catch let error as ImportError { throw error }
            catch {
                warn(.invalidRecord, line: index + 1, app: attributedApp)
                if let attributedApp {
                    apps.insert(attributedApp)
                    guard apps.count <= 128 else { throw ImportError.tooManyApps }
                    incomplete.insert(attributedApp); opened[attributedApp] = nil
                } else {
                    globallyIncomplete = true
                    opened.removeAll() // An unknown malformed event might invalidate any pending pair.
                }
            }
        }
        for (app, pending) in opened.sorted(by: { $0.key < $1.key }) {
            incomplete.insert(app); warn(.unmatchedOpened, line: pending.line, app: app)
        }
        let digest = ContentDigest.sha256(data)
        let references = try apps.sorted().map { app in
            if events[app, default: 0] == 0 { warn(.noEvents, line: nil, app: app) }
            return try AppUsageReference(id: ContentDigest.stableID("FirePrivacy/UsageEventLog/v1|" + digest + "|" + app),
                bundleID: app, provenance: .importedUsageLog, coverage: coverage,
                claimsCompleteForegroundWindows: complete.boolValue && !globallyIncomplete && !incomplete.contains(app),
                foregroundWindows: windows[app, default: []], sourceLabel: sourceLabel, suppliedAt: suppliedAt, deviceScope: scope)
        }
        return AppUsageEventLogImportResult(timeline: try AppUsageTimeline(references: references), warnings: warnings,
            warningsTruncated: truncated, sourceSHA256: digest, importedEventRecords: imported, pairedWindows: paired)
    }
    private static func validBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 255 && ImportedText.sanitize(text) == text && !text.contains(where: \.isWhitespace)
    }
    private static func isBlank(_ line: Data.SubSequence) -> Bool { line.allSatisfy { [9, 13, 32].contains($0) } }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumLineBytes else { throw AppUsageError.tooLarge }
        var validator = BoundedJSONValidator(bytes: Array(data)); try validator.validate()
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppUsageError.invalidJSON }
        return result
    }
}
