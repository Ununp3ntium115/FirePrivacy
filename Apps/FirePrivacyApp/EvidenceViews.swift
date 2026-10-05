import SwiftUI
import FirePrivacyCore

private enum EvidenceKind: String, CaseIterable, Identifiable, Sendable {
    case apps = "Apps"
    case domains = "Domains"
    case notes = "Import notes"
    var id: String { rawValue }
}

struct EvidenceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind: EvidenceKind = .apps
    @State private var search = ""

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "The report, unpacked", title: "Look closer.", subtitle: "Browse the app identifiers, domains, and event records Apple exported. Every detail comes back to an imported observation.")
            if let report = model.report {
                evidencePicker
                if kind != .notes {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(FireStyle.muted).accessibilityHidden(true)
                        TextField(kind == .apps ? "Find an app identifier" : "Find a domain", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(FireStyle.text)
                            .accessibilityIdentifier("evidence-search")
                    }
                    .padding(16)
                    .background(FireStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                }
                evidenceContent(report)
            } else {
                EmptyState(symbol: "doc.text.magnifyingglass", title: "Your evidence starts with an import", message: "Choose an exported App Privacy Report or explore the clearly labeled fictional sample.")
                PrimaryButton(title: "Import privacy report", symbol: "square.and.arrow.down") { model.requestImport() }
                QuietButton(title: "Explore a sample", symbol: "sparkles") { model.showDemo() }
            }
        }
        .accessibilityIdentifier("evidence-screen")
    }

    @ViewBuilder
    private var evidencePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            pickerContent
                .pickerStyle(.menu)
                .font(.headline)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("evidence-type-picker")
        } else {
            pickerContent
                .pickerStyle(.segmented)
                .accessibilityIdentifier("evidence-type-picker")
        }
    }

    private var pickerContent: some View {
        Picker("Evidence type", selection: $kind) {
            ForEach(EvidenceKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
        }
    }

    @ViewBuilder
    private func evidenceContent(_ report: PrivacyReport) -> some View {
        switch kind {
        case .apps:
            let apps = report.apps.filter { search.isEmpty || $0.bundleID.localizedCaseInsensitiveContains(search) }
            SectionHeading(title: "\(apps.count.formatted()) app identifiers", detail: "Identifiers come from the export. Fire Privacy cannot enumerate installed apps or reliably infer their display names.")
            if apps.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matching identifiers", message: "Try another search. Only identifiers present in this report can appear here.")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(apps) { app in
                        NavigationLink { AppEvidenceView(app: app, report: report) } label: {
                            FireCard { AppSummaryRow(app: app) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .domains:
            let domains = report.domains.filter { search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search) }
            SectionHeading(title: "\(domains.count.formatted()) domains", detail: "Contact counts are historical frequency. Domain ownership and purpose are not verified in this build.")
            if domains.isEmpty {
                EmptyState(symbol: "globe", title: "No matching domains", message: "This report may contain only sensor events, or your search may not match a recorded domain.")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(domains) { domain in
                        NavigationLink { DomainEvidenceView(domain: domain, report: report) } label: {
                            FireCard { DomainSummaryRow(domain: domain) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .notes:
            SectionHeading(title: "Import notes", detail: "Skipped records are quarantined from analysis. The report can be incomplete when records are malformed, unsupported, or beyond a limit.")
            if report.issues.isEmpty {
                EmptyState(symbol: "checkmark.circle", title: "No records were skipped", message: "Every nonempty record was recognized by the importer. This does not guarantee that Apple recorded all device activity.")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                        FireCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Line \(issue.line.formatted()) · skipped", systemImage: "exclamationmark.circle")
                                    .font(.headline).foregroundStyle(FireStyle.gold)
                                Text(verbatim: issue.message).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AppSummaryRow: View {
    let app: AppSummary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolBadge(symbol: "app")
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: app.bundleID).font(.headline).foregroundStyle(FireStyle.text).fixedSize(horizontal: false, vertical: true)
                Text("\(app.contacts.formatted()) contacts · \(app.domains.count.formatted()) domains")
                    .font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                if app.sensorAccesses > 0 {
                    Text("\(app.sensorAccesses.formatted()) sensor event records")
                        .font(.caption).foregroundStyle(FireStyle.gold).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(FireStyle.muted).padding(.top, 6).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DomainSummaryRow: View {
    let domain: DomainSummary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolBadge(symbol: "globe")
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: domain.domain).font(.headline).foregroundStyle(FireStyle.text).fixedSize(horizontal: false, vertical: true)
                Text("\(domain.contacts.formatted()) contacts · \(domain.apps.count.formatted()) app identifiers")
                    .font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(FireStyle.muted).padding(.top, 6).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppEvidenceView: View {
    let app: AppSummary
    let report: PrivacyReport

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "App identifier", title: app.bundleID, subtitle: "This identifier appears in the exported report. Its display name and current permissions are not known to Fire Privacy.")
            FireCard {
                VStack(spacing: 14) {
                    DetailRow(label: "Reported contacts", value: app.contacts.formatted())
                    DetailRow(label: "Distinct domains", value: app.domains.count.formatted())
                    DetailRow(label: "Sensor event records", value: app.sensorAccesses.formatted())
                }
            }
            if !app.domains.isEmpty {
                SectionHeading(title: "Contacted domains", detail: "A domain contact does not reveal request contents or establish harm.")
                LazyVStack(spacing: 12) {
                    ForEach(report.domains.filter { app.domains.contains($0.domain) }) { domain in
                        NavigationLink { DomainEvidenceView(domain: domain, report: report) } label: {
                            FireCard { DomainSummaryRow(domain: domain) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SectionHeading(title: "Imported evidence", detail: "Each card is an exported record. Sensor interval begin/end records can describe the same access.")
            LazyVStack(spacing: 12) {
                ForEach(report.observations.filter { $0.bundleID == app.bundleID }) { observation in
                    ObservationCard(observation: observation)
                }
            }
        }
        .navigationTitle("App evidence")
    }
}

struct DomainEvidenceView: View {
    let domain: DomainSummary
    let report: PrivacyReport

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Recorded destination", title: domain.domain, subtitle: "The hostname was recorded in the report. Fire Privacy does not visit it, verify its owner, or classify it as a tracker.")
            FireCard {
                VStack(spacing: 14) {
                    DetailRow(label: "Reported contacts", value: domain.contacts.formatted())
                    DetailRow(label: "App identifiers", value: domain.apps.count.formatted())
                    DetailRow(label: "Owner / purpose", value: "Not verified")
                }
            }
            SectionHeading(title: "Contributing apps")
            LazyVStack(spacing: 12) {
                ForEach(report.apps.filter { domain.apps.contains($0.bundleID) }) { app in
                    NavigationLink { AppEvidenceView(app: app, report: report) } label: {
                        FireCard { AppSummaryRow(app: app) }
                    }
                    .buttonStyle(.plain)
                }
            }
            SectionHeading(title: "Imported evidence", detail: "Counts are exported contact frequency, not data volume. These records do not show what was transmitted.")
            LazyVStack(spacing: 12) {
                ForEach(report.observations.filter { $0.category == .network && $0.domain == domain.domain }) { observation in
                    ObservationCard(observation: observation)
                }
            }
        }
        .navigationTitle("Domain evidence")
    }
}

struct ObservationCard: View {
    let observation: Observation

    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(observation.category == .network ? "Network activity record" : "Sensor event record", systemImage: observation.category == .network ? "network" : "sensor")
                    .font(.headline).foregroundStyle(observation.category == .network ? FireStyle.ember : FireStyle.gold)
                Text(verbatim: observation.bundleID).font(.subheadline.weight(.medium)).foregroundStyle(FireStyle.text).fixedSize(horizontal: false, vertical: true)
                if let domain = observation.domain {
                    DetailRow(label: "Domain", value: domain)
                }
                DetailRow(label: observation.category == .network ? "Record type" : "Recorded category", value: observation.accessType)
                if observation.category == .network {
                    DetailRow(label: "Reported contacts", value: observation.count.formatted())
                    timestampRow(label: "First recorded", date: observation.firstTimestamp, original: observation.firstTimestampText)
                    timestampRow(label: "Last recorded", date: networkLastTimestamp, original: observation.lastTimestampText ?? observation.timestampText)
                } else {
                    if let eventKind = observation.eventKind {
                        DetailRow(label: "Event kind", value: eventKind)
                    }
                    timestampRow(label: "Recorded time", date: observation.timestamp, original: observation.timestampText)
                }
                Text("Evidence ID").font(.caption).foregroundStyle(FireStyle.muted)
                Text(verbatim: observation.id.uuidString).font(.system(.caption2, design: .monospaced)).foregroundStyle(FireStyle.muted).textSelection(.enabled)
            }
        }
    }

    private var networkLastTimestamp: Date? {
        if let last = observation.lastTimestamp { return last }
        // The importer's representative timestamp can fall back to the first
        // time. Use the canonical timeStamp only when it exists; a demo with
        // no first/last fields may provide a representative Date directly.
        if observation.timestampText != nil || observation.firstTimestamp == nil {
            return observation.timestamp
        }
        return nil
    }

    @ViewBuilder
    private func timestampRow(label: String, date: Date?, original: String?) -> some View {
        if let original {
            DetailRow(label: date == nil ? label + " (unparsed)" : label, value: original)
        } else if let date {
            DetailRow(label: label, value: date.formatted(date: .abbreviated, time: .standard))
        } else {
            DetailRow(label: label, value: "Not included")
        }
    }
}
