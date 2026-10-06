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
                NavigationLink { EvidenceTimingView(report: report) } label: { Label("Recorded timing & sensor intervals", systemImage: "clock.arrow.circlepath").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                NavigationLink { UsageTimelineView() } label: { Label("Activity versus app use", systemImage: "rectangle.split.2x1").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
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
            SectionHeading(title: "\(domains.count.formatted()) domains", detail: "Contact counts are historical frequency. Open a domain to separate reported metadata, signed classification and your local notes.")
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
    @EnvironmentObject private var model: AppModel
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
            NavigationLink { ManualPermissionAuditView() } label: { Label("Record a manual permission review", systemImage: "checklist").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
            if let findings = model.analysis?.findings.filter({ if case .app(let identifier) = $0.subject { return identifier == app.bundleID }; return false }), !findings.isEmpty {
                SectionHeading(title: "Linked findings", detail: "Versioned interpretations are separate from the records below.")
                ForEach(findings) { finding in NavigationLink { RuleFindingDetailView(finding: finding, report: report) } label: { RuleFindingRow(finding: finding) }.buttonStyle(.plain) }
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
    @EnvironmentObject private var model: AppModel
    let domain: DomainSummary
    let report: PrivacyReport

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Recorded destination", title: domain.domain, subtitle: "The hostname was recorded in the report. Report metadata, signed knowledge and your opinions remain separate; none proves what was transmitted.")
            FireCard {
                VStack(spacing: 14) {
                    DetailRow(label: "Reported contacts", value: domain.contacts.formatted())
                    DetailRow(label: "App identifiers", value: domain.apps.count.formatted())
                    DetailRow(label: "Contact content", value: "Not included in the report")
                }
            }
            DomainKnowledgeCard(host: domain.domain)
            NavigationLink { DomainOverridesView(initialHost: domain.domain) } label: { Label("Record a local choice for this domain", systemImage: "pencil").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
            if let findings = model.analysis?.findings.filter({ if case .domain(let host) = $0.subject { return host == domain.domain }; return false }), !findings.isEmpty {
                SectionHeading(title: "Linked findings")
                ForEach(findings) { finding in NavigationLink { RuleFindingDetailView(finding: finding, report: report) } label: { RuleFindingRow(finding: finding) }.buttonStyle(.plain) }
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
                if let context = observation.context { DetailRow(label: "Reported context", value: context) }
                if let owner = observation.domainOwner { DetailRow(label: "Reported owner", value: owner) }
                if let type = observation.domainType { DetailRow(label: "Reported domain type", value: type.displayValue) }
                if let initiated = observation.initiatedType { DetailRow(label: "Reported initiation type", value: initiated.displayValue) }
                if let classification = observation.domainClassification { DetailRow(label: "Reported classification", value: classification.displayValue) }
                if let sensor = observation.sensorIdentifier { DetailRow(label: "Reported sensor identifier", value: sensor) }
                if let provenance = observation.provenance {
                    DetailRow(label: "Source line", value: provenance.sourceLine.formatted())
                    DetailRow(label: "Source-line SHA-256", value: provenance.sourceSHA256)
                }
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

struct DomainKnowledgeCard: View {
    @EnvironmentObject private var model: AppModel
    let host: String
    private var matches: [DomainMatch] {
        guard let knowledge = model.engine.knowledgeBase else { return [] }
        return DomainMatcher(snapshot: knowledge).matches(for: host)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Signed classification", detail: "Documented business or infrastructure is distinct from observed conduct. A classification does not establish the relationship to the contacting app.")
            if matches.isEmpty {
                EmptyState(symbol: "questionmark.circle", title: "No usable classification for this hostname", message: "The current verified knowledge does not cover this destination. Unknown does not mean harmful.")
            }
            ForEach(matches, id: \.classification.id) { match in
                FireCard {
                    VStack(alignment: .leading, spacing: 14) {
                        DetailRow(label: "Documented organization", value: match.classification.organization ?? "Unknown")
                        DetailRow(label: "Documented categories", value: match.classification.categories.map(\.displayName).joined(separator: ", "))
                        DetailRow(label: "Pattern", value: match.classification.pattern)
                        DetailRow(label: "Pattern kind", value: match.classification.patternKind.rawValue)
                        DetailRow(label: "Review status", value: match.classification.reviewStatus.rawValue)
                        DetailRow(label: "Reviewed", value: match.classification.lastReviewed.formatted(date: .abbreviated, time: .omitted))
                        DetailRow(label: "Knowledge version", value: model.knowledgeBaseVersion ?? "Unavailable")
                        if match.isStale { Text("This classification may be outdated. It should not be treated as current verified context.").foregroundStyle(FireStyle.gold) }
                        if !match.classification.notes.isEmpty { Text(verbatim: match.classification.notes).font(.footnote).foregroundStyle(FireStyle.muted) }
                        ForEach(match.sources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: source.title).font(.headline).foregroundStyle(FireStyle.text)
                                Text(verbatim: source.excerpt).font(.footnote).foregroundStyle(FireStyle.muted)
                                if let url = sourceURL(source.url) {
                                    Link(destination: url) { Label("Open cited source in browser", systemImage: "arrow.up.right.square").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                                }
                            }
                        }
                    }
                }
            }
            if let identity = DomainIdentity(host), let choice = model.preferences.overrides.override(for: identity) {
                FireCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Your local opinion")
                        DetailRow(label: "Choice", value: choice.disposition.displayName)
                        if let note = choice.note { Text(verbatim: note).foregroundStyle(FireStyle.muted) }
                        Text("This is your private choice, not a signed classification or a system activation result.").font(.footnote).foregroundStyle(FireStyle.muted)
                    }
                }
            }
        }
    }
    private func sourceURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
