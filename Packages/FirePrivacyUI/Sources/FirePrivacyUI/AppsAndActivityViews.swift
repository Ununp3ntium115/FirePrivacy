#if canImport(SwiftUI)
import SwiftUI
import ObservationCore
import FindingEngine
import KnowledgeBaseKit
import ObservationStore
import ReportKit

/// The app list (DASH-004). The bundle identifier is always visible: Fire
/// Privacy shows a display name only when it has a verified one.
public struct AppListView: View {
    let model: AppModel
    @State private var query = ""

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if model.applications.isEmpty {
                ContentUnavailableView("No apps observed", systemImage: "app.dashed")
            }
            ForEach(filtered) { summary in
                NavigationLink {
                    AppDetailView(model: model, summary: summary)
                } label: {
                    row(summary)
                }
            }
        }
        .searchable(text: $query, prompt: "Search apps and bundle IDs")
        .navigationTitle("Apps")
    }

    private var filtered: [AppModel.ApplicationSummary] {
        guard !query.isEmpty else { return model.applications }
        let needle = query.lowercased()
        return model.applications.filter {
            $0.application.bundleID.rawValue.lowercased().contains(needle)
                || ($0.application.displayName?.value.lowercased().contains(needle) ?? false)
        }
    }

    private func row(_ summary: AppModel.ApplicationSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.application.preferredLabel)
                .font(.body.weight(.medium))
            if summary.application.displayName != nil {
                Text(summary.application.bundleID.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(summary.domainCount) domains · \(summary.totalContacts) contacts· \(summary.sensorTypes.count) sensor types")
                .font(.caption)
                .foregroundStyle(.secondary)
            if summary.findingCount > 0 {
                Text("\(summary.findingCount) finding\(summary.findingCount == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// App detail (DASH-005).
public struct AppDetailView: View {
    let model: AppModel
    public let summary: AppModel.ApplicationSummary

    public init(model: AppModel, summary: AppModel.ApplicationSummary) {
        self.model = model
        self.summary = summary
    }

    public var body: some View {
        List {
            Section("Where this comes from") {
                if let session = model.latestSession?.snapshot.session {
                    FactRow(label: "Import", value: session.importedAt.formatted(date: .abbreviated, time: .shortened))
                    FactRow(label: "Source file", value: session.sourceHash.shortHexString)
                    if session.isDemoData {
                        Text("Demo data. Nothing here came from your device.")
                            .font(.footnote.weight(.semibold))
                    }
                }
                FactRow(label: "Bundle ID", value: summary.application.bundleID.rawValue)
            }

            Section("Observed access") {
                if summary.sensorTypes.isEmpty {
                    Text("No sensor access recorded for this app in this report.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(summary.sensorTypes, id: \.identifier) { sensorType in
                    NavigationLink {
                        PermissionAuditView(sensorType: sensorType, bundleID: summary.application.bundleID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sensorType.identifier.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text("Observed access — not the current setting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Contacted domains") {
                ForEach(domains, id: \.host.value) { observation in
                    NavigationLink {
                        DomainDetailView(model: model, host: observation.ownerKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(observation.host.displayValue)
                            Text(contactDescription(observation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !findings.isEmpty {
                Section("Findings") {
                    ForEach(findings) { finding in
                        NavigationLink {
                            FindingDetailView(model: model, finding: finding)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                SeverityBadge(severity: finding.severity, confidence: finding.confidence)
                                Text(finding.title).font(.subheadline)
                            }
                        }
                    }
                }
            }

            Section("Raw evidence") {
                NavigationLink("Show the records behind this app") {
                    RawEvidenceView(observations: domains, sensors: sensors)
                }
            }
        }
        .navigationTitle(summary.application.preferredLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var domains: [NetworkObservation] {
        model.latestSession?.snapshot.networkObservations
            .filter { $0.bundleID == summary.application.bundleID }
            .sorted { ($0.hits ?? 0) > ($1.hits ?? 0) } ?? []
    }

    private var sensors: [SensorObservation] {
        model.latestSession?.snapshot.sensorObservations
            .filter { $0.bundleID == summary.application.bundleID } ?? []
    }

    private var findings: [Finding] {
        model.currentResult?.findings(for: .application(summary.application.bundleID)) ?? []
    }

    private func contactDescription(_ observation: NetworkObservation) -> String {
        var parts: [String] = []
        if let hits = observation.hits { parts.append("\(hits) contacts") }
        if let owner = observation.domainOwner { parts.append(owner.value) }
        if observation.domainType.indicatesCrossAppCollection { parts.append("flagged by Apple") }
        return parts.isEmpty ? "Contacted in this report" : parts.joined(separator: " · ")
    }
}

/// Domain detail (DASH-006).
public struct DomainDetailView: View {
    let model: AppModel
    public let host: NormalizedHost

    public init(model: AppModel, host: NormalizedHost) {
        self.model = model
        self.host = host
    }

    public var body: some View {
        List {
            Section("Domain") {
                FactRow(label: "Host", value: host.displayValue)
                if host.displayValue != host.value {
                    FactRow(label: "Canonical form", value: host.value)
                }
                FactRow(label: "Contacted by", value: "\(apps.count) app\(apps.count == 1 ? "" : "s")")
                FactRow(label: "Total contacts", value: String(observations.reduce(0) { $0 + ($1.hits ?? 0) }))
            }

            Section("Apps") {
                ForEach(apps, id: \.self) { bundleID in
                    Text(bundleID)
                }
            }

            Section("Protection coverage") {
                Text(model.protection.urlFilterState.isProtecting
                     ? "Protection is on. Whether this destination is on the list is decided by iOS, not shown here."
                     : "Protection is off, so nothing is being blocked.")
                    .font(.footnote)
            }

            Section("What Fire Privacy cannot tell you") {
                Text("The report records that these contacts happened. It does not record what was sent, and it does not establish what the operator did with anything received.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(host.displayValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var observations: [NetworkObservation] {
        model.latestSession?.snapshot.networkObservations.filter { $0.ownerKey.value == host.value } ?? []
    }

    private var apps: [String] {
        Array(Set(observations.compactMap { $0.bundleID?.rawValue })).sorted()
    }
}

/// Activity, list-first. A network map is offered only as an addition to the
/// list, never as the only representation (DASH-007, §11.10).
public struct ActivityView: View {
    let model: AppModel
    @State private var mode: Mode = .domains

    enum Mode: String, CaseIterable, Identifiable {
        case domains = "Domains"
        case timeline = "Timeline"
        case comparison = "Comparison"
        var id: String { rawValue }
    }

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .domains: domainSection
            case .timeline: timelineSection
            case .comparison: comparisonSection
            }
        }
        .navigationTitle("Activity")
    }

    private var domainSection: some View {
        Section("Domains, most contacted first") {
            ForEach(domainRows, id: \.host.value) { row in
                NavigationLink {
                    DomainDetailView(model: model, host: row.host)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.host.displayValue)
                        Text("\(row.appCount) apps · \(row.hits) contacts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var timelineSection: some View {
        Section("Observed windows") {
            ForEach(timelineRows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.subheadline)
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if let comparison = model.comparison {
            Section("Between the last two reports") {
                Text(comparison.headline).font(.subheadline)
                if let note = comparison.attributionNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                FactRow(label: "New domains", value: String(comparison.newDomains.count))
                FactRow(label: "Domains no longer seen", value: String(comparison.disappearedDomains.count))
                FactRow(label: "New findings", value: String(comparison.newFindings.count))
                FactRow(label: "Resolved findings", value: String(comparison.resolvedFindings.count))
                FactRow(label: "Posture change", value: comparison.postureDelta >= 0 ? "+\(comparison.postureDelta)" : "\(comparison.postureDelta)")
            }
        } else {
            Section {
                Text("Import a second report to compare. With only one report there is nothing to compare against — which is not the same as nothing having changed.")
                    .font(.footnote)
            }
        }
    }

    private struct DomainRow {
        let host: NormalizedHost
        let appCount: Int
        let hits: Int
    }

    private var domainRows: [DomainRow] {
        guard let snapshot = model.latestSession?.snapshot else { return [] }
        var grouped: [String: (NormalizedHost, Set<String>, Int)] = [:]
        for observation in snapshot.networkObservations {
            var entry = grouped[observation.ownerKey.value] ?? (observation.ownerKey, [], 0)
            if let bundleID = observation.bundleID { entry.1.insert(bundleID.rawValue) }
            entry.2 += observation.hits ?? 0
            grouped[observation.ownerKey.value] = entry
        }
        return grouped.values
            .map { DomainRow(host: $0.0, appCount: $0.1.count, hits: $0.2) }
            .sorted { ($0.hits, $0.host.value) > ($1.hits, $1.host.value) }
    }

    private struct TimelineRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
    }

    private var timelineRows: [TimelineRow] {
        guard let snapshot = model.latestSession?.snapshot else { return [] }
        let sensors = snapshot.sensorObservations.map { observation in
            TimelineRow(
                id: observation.id.uuidString,
                title: "\(observation.bundleID?.rawValue ?? "Unknown app") · \(observation.sensorType.identifier)",
                subtitle: Self.window(observation.firstTimestamp, observation.lastTimestamp, count: observation.count)
            )
        }
        let network = snapshot.networkObservations.prefix(200).map { observation in
            TimelineRow(
                id: observation.id.uuidString,
                title: "\(observation.bundleID?.rawValue ?? "Unknown app") → \(observation.host.displayValue)",
                subtitle: Self.window(observation.firstTimestamp, observation.lastTimestamp, count: observation.hits)
            )
        }
        return (sensors + network).sorted { $0.title < $1.title }
    }

    private static func window(_ first: Date?, _ last: Date?, count: Int?) -> String {
        var parts: [String] = []
        if let first { parts.append("from \(first.formatted(date: .abbreviated, time: .shortened))") }
        if let last { parts.append("to \(last.formatted(date: .abbreviated, time: .shortened))") }
        if let count { parts.append("· \(count) recorded") }
        return parts.isEmpty ? "No timestamps in the record" : parts.joined(separator: " ")
    }
}

/// The raw records behind a screen, for people who want to check the work.
public struct RawEvidenceView: View {
    public let observations: [NetworkObservation]
    public let sensors: [SensorObservation]

    public init(observations: [NetworkObservation], sensors: [SensorObservation]) {
        self.observations = observations
        self.sensors = sensors
    }

    public var body: some View {
        List {
            Section("Network records") {
                ForEach(observations, id: \.id) { observation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(observation.host.value).font(.subheadline.monospaced())
                        Text("line \(observation.sourceLineNumber) · \(observation.mergedRecordCount) merged · hash \(observation.sourceLineHash.shortHexString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !observation.normalizationWarnings.identifiers.isEmpty {
                            Text("normalization: \(observation.normalizationWarnings.identifiers.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Sensor records") {
                ForEach(sensors, id: \.id) { sensor in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sensor.sensorType.identifier).font(.subheadline.monospaced())
                        Text("line \(sensor.sourceLineNumber) · \(sensor.mergedRecordCount) merged · hash \(sensor.sourceLineHash.shortHexString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Raw evidence")
    }
}
#endif
