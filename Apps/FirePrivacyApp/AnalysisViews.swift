import SwiftUI
import FirePrivacyCore

struct RuleFindingRow: View {
    let finding: RuleFinding
    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    SymbolBadge(symbol: "text.magnifyingglass")
                    Text(verbatim: finding.title).font(.headline).foregroundStyle(FireStyle.text)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(FireStyle.muted).accessibilityHidden(true)
                }
                Text(verbatim: finding.detail).font(.subheadline).foregroundStyle(FireStyle.muted)
                ViewThatFits(in: .horizontal) {
                    HStack { findingLabels }
                    VStack(alignment: .leading, spacing: 8) { findingLabels }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var findingLabels: some View {
        Text(finding.status.displayName).foregroundStyle(FireStyle.gold)
        Text("\(finding.evidenceIDs.count) records · \(finding.severity.displayName) review priority").foregroundStyle(FireStyle.muted)
    }
}

struct RuleFindingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let finding: RuleFinding
    let report: PrivacyReport
    private var current: RuleFinding {
        model.engine.lifecycle?.current.first { $0.id == finding.id } ?? model.analysis?.findings.first { $0.id == finding.id } ?? finding.withStatus(.superseded)
    }
    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Facts → Interpretation → Your choice", title: current.title, subtitle: current.detail)
            if current.status == .superseded {
                TextListCard(title: "Earlier analysis snapshot", strings: ["Current analysis no longer produces this exact finding. Review its historical evidence with that limitation in mind; it is not a current protection verdict."])
            }
            FireCard {
                VStack(spacing: 14) {
                    DetailRow(label: "Review state", value: current.status.displayName)
                    DetailRow(label: "Rule", value: current.ruleID + " · " + current.ruleVersion)
                    DetailRow(label: "Review priority", value: current.severity.displayName)
                    DetailRow(label: "Evidence confidence", value: current.confidence.formatted(.percent.precision(.fractionLength(0))))
                    Text("Priority and confidence describe this rule’s interpretation of exported evidence. They are not probabilities of harm or a device safety grade.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            SectionHeading(title: "Observed facts")
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(current.observedFacts.enumerated()), id: \.offset) { _, fact in
                        VStack(alignment: .leading, spacing: 6) {
                            DetailRow(label: fact.key, value: fact.value)
                            Text("\(fact.evidenceIDs.count) linked records").font(.caption).foregroundStyle(FireStyle.muted)
                        }
                    }
                }
            }
            if !current.inferences.isEmpty {
                SectionHeading(title: "Interpretations", detail: "These are bounded inferences, separate from recorded facts.")
                FireCard {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(current.inferences.enumerated()), id: \.offset) { _, inference in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: inference.statement).foregroundStyle(FireStyle.text)
                                Text("Confidence \(inference.confidence.formatted(.percent.precision(.fractionLength(0)))) · \(inference.basis.count) supporting records").font(.caption).foregroundStyle(FireStyle.gold)
                            }
                        }
                    }
                }
            }
            TextListCard(title: "What remains uncertain", strings: current.uncertainty, symbol: "questionmark.circle")
            if !current.knowledgeSources.isEmpty {
                TextListCard(title: "Knowledge sources", strings: current.knowledgeSources, symbol: "books.vertical")
            }
            SectionHeading(title: "Available choices", detail: "Reviewed actions from a versioned catalog. Keeping things as they are is a valid choice.")
            ForEach(current.actionIDs.compactMap { ActionCatalog.action(id: $0) }) { action in
                NavigationLink { CatalogActionView(action: action) } label: {
                    FireCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: action.title).font(.headline).foregroundStyle(FireStyle.ember)
                            Text(verbatim: action.detail).foregroundStyle(FireStyle.muted)
                        }
                    }
                }.buttonStyle(.plain)
            }
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Your review decision", detail: "This changes local review state, never imported evidence or system protections.")
                    QuietButton(title: "Reviewed; keep as is", symbol: "checkmark.circle") { updateDecision(accepted: true, ignored: false) }
                    QuietButton(title: "Hide this finding", symbol: "eye.slash") { updateDecision(accepted: false, ignored: true) }
                    QuietButton(title: "Reset my decision", symbol: "arrow.counterclockwise") { updateDecision(accepted: false, ignored: false) }
                }
            }
            SectionHeading(title: "Supporting evidence", detail: "Historical records cannot establish transmitted content or current permission state.")
            let evidenceIDs = Set(current.evidenceIDs)
            ForEach(report.observations.filter { evidenceIDs.contains($0.id) }) { record in
                ObservationCard(observation: record)
            }
        }.navigationTitle("Finding details")
    }
    private func updateDecision(accepted: Bool, ignored: Bool) {
        var preferences = model.preferences
        preferences.acceptedFindingKeys.remove(current.lifecycleKey)
        preferences.ignoredFindingKeys.remove(current.lifecycleKey)
        if accepted { preferences.acceptedFindingKeys.insert(current.lifecycleKey) }
        if ignored { preferences.ignoredFindingKeys.insert(current.lifecycleKey) }
        Task { await model.savePreferences(preferences) }
    }
}

struct TextListCard: View {
    let title: String
    let strings: [String]
    var symbol = "info.circle"
    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(FireStyle.gold)
                if strings.isEmpty { Text("No entries.").foregroundStyle(FireStyle.muted) }
                ForEach(Array(strings.enumerated()), id: \.offset) { _, text in
                    Text(verbatim: text).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct CatalogActionView: View {
    let action: CatalogAction
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Reviewed action · " + ActionCatalog.version, title: action.title, subtitle: action.detail)
            if !action.steps.isEmpty {
                FireCard {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                            InstructionStep(number: index + 1, title: "Your next step", detail: step)
                        }
                    }
                }
            }
            if !action.tradeoffs.isEmpty { TextListCard(title: "Trade-offs", strings: action.tradeoffs, symbol: "scale.3d") }
            if !action.prerequisites.isEmpty { TextListCard(title: "Requirements", strings: action.prerequisites) }
            if action.id == "rec.enable-safari-blocker" || action.id == "rec.enable-standard-filter" {
                NavigationLink { ProtectionSettingsView() } label: { Label("Review protection setup", systemImage: "shield").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
            }
            if action.id == "rec.mark-domain-trusted" {
                NavigationLink { DomainOverridesView() } label: { Label("Edit local domain choices", systemImage: "pencil").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
            }
        }.navigationTitle("Your choices")
    }
}

struct PostureView: View {
    let scores: PostureScores
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Observed dimensions · " + scores.version, title: "Understand the shape.", subtitle: "Each dimension uses a documented 0–100 scale. These summarize exported evidence and review coverage, not the likelihood of harm.")
            if let overall = scores.privacyPosture {
                FireCard { VStack(alignment: .leading, spacing: 12) { DetailRow(label: "Optional observed posture", value: "\(overall) / 100"); if let definition = scores.explanation["privacyPosture"] { Text(verbatim: definition).font(.footnote).foregroundStyle(FireStyle.muted) } } }
            }
            dimension("Sensor exposure", key: "sensorExposure", value: scores.sensorExposure)
            dimension("Third-party reach", key: "thirdPartyReach", value: scores.thirdPartyReach)
            dimension("Aggregation signals", key: "aggregationSignals", value: scores.aggregationSignals)
            dimension("Recorded repetition", key: "repetition", value: scores.repetition)
            dimension("Review & coverage gap", key: "controlGap", value: scores.controlGap)
            dimension("Evidence confidence", key: "evidenceConfidence", value: scores.evidenceConfidence)
            dimension("Classification coverage", key: "classificationCoverage", value: scores.classificationCoverage)
            if let limits = scores.explanation["limits"] { TextListCard(title: "Limits", strings: [limits]) }
        }.navigationTitle("Observed dimensions")
    }
    private func dimension(_ title: String, key: String, value: Double?) -> some View {
        FireCard {
            VStack(alignment: .leading, spacing: 12) {
                DetailRow(label: title, value: value.map { $0.formatted(.number.precision(.fractionLength(1))) + " / 100" } ?? "Unknown")
                if let value {
                    ProgressView(value: value, total: 100).tint(FireStyle.ember).accessibilityLabel(title).accessibilityValue("\(value.formatted()) of 100")
                }
                if let explanation = scores.explanation[key] { Text(verbatim: explanation).font(.footnote).foregroundStyle(FireStyle.muted) }
            }
        }
    }
}

private struct EvidenceTimingSummary: Sendable {
    let activity: [SensorActivitySummary]
    let intervals: [SensorInterval]
    let associations: TemporalAssociationResult
}

struct EvidenceTimingView: View {
    let report: PrivacyReport
    @State private var summary: EvidenceTimingSummary?
    @State private var visibleAssociations = 100
    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Timing is context, not causation", title: "Read the recorded moments.", subtitle: "Sensor records and network windows can be close in time without sharing data. These local associations do not prove that sensor content was transmitted.")
            if let summary {
                SectionHeading(title: "Sensor record summary", detail: "Begin/end pairs are candidate intervals, not a proven number of distinct accesses.")
                ForEach(summary.activity) { activity in
                    FireCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: activity.bundleID).font(.headline).foregroundStyle(FireStyle.text)
                            DetailRow(label: "Reported category", value: activity.category)
                            DetailRow(label: "Event records", value: activity.eventRecords.formatted())
                            DetailRow(label: "Begin / end records", value: "\(activity.beginRecords) / \(activity.endRecords)")
                            DetailRow(label: "Candidate matched intervals", value: activity.completedIntervals.formatted())
                            DetailRow(label: "Unknown event-kind records", value: activity.unknownKindRecords.formatted())
                        }
                    }
                }
                SectionHeading(title: "Candidate intervals", detail: "Only one begin and one end with the same reported app, category and sensor identifier are paired. Identifier semantics and access completeness remain unknown.")
                if summary.intervals.isEmpty { EmptyState(symbol: "clock", title: "No unambiguous intervals", message: "The export may omit identifiers or event times, or contain multiple unmatched events. No duration is inferred from those records.") }
                ForEach(summary.intervals) { interval in
                    FireCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: interval.bundleID).font(.headline).foregroundStyle(FireStyle.text)
                            DetailRow(label: "Reported category", value: interval.category)
                            DetailRow(label: "Start", value: interval.startTimestampText ?? interval.start.formatted(date: .abbreviated, time: .standard))
                            DetailRow(label: "End", value: interval.endTimestampText ?? interval.end.formatted(date: .abbreviated, time: .standard))
                            DisclosureGroup("Supporting records") { ForEach(records(interval.evidenceIDs)) { record in ObservationCard(observation: record) } }.tint(FireStyle.ember)
                        }
                    }
                }
                SectionHeading(title: "Temporal associations", detail: "Same-app sensor and network evidence within a five-minute tolerance. An aggregated window does not locate a particular request inside that window.")
                FireCard {
                    VStack(spacing: 12) {
                        DetailRow(label: "Associations found", value: summary.associations.associations.count.formatted())
                        DetailRow(label: "Untimed records excluded", value: summary.associations.untimedRecords.formatted())
                        DetailRow(label: "Analysis bound reached", value: summary.associations.reachedLimit ? "Yes; results incomplete" : "No")
                    }
                }
                if summary.associations.associations.isEmpty { EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No associations found within these bounds", message: "This does not establish that sensor activity and contacts were unrelated. Missing timing and export limits can prevent comparison.") }
                ForEach(summary.associations.associations.prefix(visibleAssociations)) { association in
                    FireCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: association.bundleID).font(.headline).foregroundStyle(FireStyle.text)
                            DetailRow(label: "Evidence precision", value: association.precision == .timestampPoint ? "Timestamp point" : "Aggregated time window")
                            Text(verbatim: association.explanation).foregroundStyle(FireStyle.muted)
                            DisclosureGroup("Supporting records") { ForEach(records(association.sensorEvidenceIDs + [association.networkObservationID])) { record in ObservationCard(observation: record) } }.tint(FireStyle.ember)
                        }
                    }
                }
                if visibleAssociations < summary.associations.associations.count { QuietButton(title: "Show 100 more associations", symbol: "plus") { visibleAssociations += 100 } }
            } else { Label("Preparing bounded local timing analysis", systemImage: "hourglass").foregroundStyle(FireStyle.muted) }
        }.navigationTitle("Recorded timing")
        .task(id: report.id) {
            summary = nil
            visibleAssociations = 100
            let importedReport = report
            let value = await Task.detached(priority: .userInitiated) { EvidenceTimingSummary(activity: importedReport.sensorActivity, intervals: importedReport.sensorIntervals, associations: TemporalAssociations.analyze(in: importedReport)) }.value
            guard !Task.isCancelled else { return }
            summary = value
        }
    }
    private func records(_ ids: [UUID]) -> [Observation] {
        let selected = Set(ids)
        return report.observations.filter { selected.contains($0.id) }
    }
}

struct ReportHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: ReportSessionDescriptor?
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "An encrypted notebook", title: "Snapshots over time.", subtitle: "Select a saved import to review its evidence. Comparing exports does not establish that apps were installed, removed, blocked or stopped acting.")
            if model.analysisHistoryCapacityExceeded {
                TextListCard(title: "Analysis-history capacity reached", strings: ["The current analysis remains available, but this revision could not be saved within the bounded analysis-history limits. Earlier saved revisions remain; history comparisons cannot treat this unsaved output as a recorded baseline."], symbol: "exclamationmark.triangle")
            }
            if let revision = model.latestAnalysisRevision, revision.inputs.reportID == model.report?.id, !model.isDemo {
                AnalysisRevisionCard(revision: revision)
            }
            if let weekly = model.weeklySummary {
                FireCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeading(title: "Your local weekly review")
                        DetailRow(label: "Import period", value: weekly.periodStart.formatted(date: .abbreviated, time: .omitted) + " – " + weekly.periodEnd.formatted(date: .abbreviated, time: .omitted))
                        DetailRow(label: "Distinct imported reports", value: weekly.uniqueReportCount.formatted())
                        DetailRow(label: "Latest snapshot contacts", value: weekly.latestRecordedContacts?.formatted() ?? "No recent import")
                        DetailRow(label: "Latest sensor event records", value: weekly.latestRecordedSensorEvents?.formatted() ?? "No recent import")
                        ForEach(Array(weekly.limitations.enumerated()), id: \.offset) { _, text in Text(verbatim: text).font(.footnote).foregroundStyle(FireStyle.muted) }
                    }
                }
            }
            if let comparison = model.comparison {
                NavigationLink { ReportComparisonView(comparison: comparison) } label: {
                    FireCard { Label("Compare selected report with its previous import", systemImage: "arrow.left.arrow.right").foregroundStyle(FireStyle.ember) }
                }.buttonStyle(.plain)
            }
            if model.sessions.isEmpty { EmptyState(symbol: "clock", title: "No saved snapshots", message: "Imports are saved locally within your retention limits. The fictional sample is not added to history.") }
            ForEach(model.sessions) { session in
                FireCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            Text(session.importedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline).foregroundStyle(FireStyle.text)
                            Spacer(minLength: 0)
                            if session.id == model.report?.id && !model.isDemo { Label("Selected", systemImage: "checkmark.circle").foregroundStyle(FireStyle.gold) }
                        }
                        Text("\(session.observationCount) records · \(session.contactCount) recorded contacts").foregroundStyle(FireStyle.muted)
                        DetailRow(label: "Encrypted storage", value: ByteCountFormatter.string(fromByteCount: Int64(session.encryptedBytes + session.encryptedSourceBytes), countStyle: .file))
                        DetailRow(label: "Original source copy", value: session.retainsEncryptedSource ? "Retained encrypted by consent" : "Not retained")
                        if model.unavailableSessionIDs.contains(session.id) { Text("This saved session needs attention and could not be opened.").foregroundStyle(FireStyle.gold) }
                        QuietButton(title: "Open this snapshot", symbol: "doc.text.magnifyingglass") { Task { await model.selectReport(session.id) } }
                        Button("Delete this snapshot", role: .destructive) { deleting = session }.frame(minHeight: 44)
                    }
                }
            }
        }.navigationTitle("Report history")
        .confirmationDialog("Delete this saved snapshot?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete snapshot", role: .destructive) { if let session = deleting { Task { await model.deleteReport(session.id) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes this saved report and any retained encrypted source from Fire Privacy. Originals in Files and exports shared elsewhere remain.") }
    }
}

private struct AnalysisRevisionCard: View {
    let revision: AnalysisHistoryRecord
    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Latest saved analysis revision", detail: "An immutable local record of the inputs used. Concurrent input changes are not proof that any one change caused a finding.")
                DetailRow(label: "Evaluated", value: revision.evaluatedAt.formatted(date: .abbreviated, time: .shortened))
                DetailRow(label: "Parser / normalization", value: (revision.inputs.parserVersion ?? "Unknown") + " / " + (revision.inputs.normalizationVersion ?? "Unknown"))
                DetailRow(label: "Ruleset", value: revision.inputs.rulesetVersion)
                DetailRow(label: "Scoring", value: revision.inputs.scoringVersion)
                DetailRow(label: "Action catalog", value: revision.inputs.actionCatalogVersion)
                DetailRow(label: "Knowledge", value: revision.inputs.knowledgeBaseVersion ?? "Unavailable")
                if let comparison = revision.comparison {
                    Text(comparison.isSameEvidenceReanalysis ? "Same-evidence reanalysis" : "Comparison with an earlier saved analysis").font(.headline).foregroundStyle(FireStyle.gold)
                    Text("Changed input dimensions").font(.subheadline.weight(.medium)).foregroundStyle(FireStyle.text)
                    ForEach(comparison.dimensions, id: \.rawValue) { dimension in Text(dimensionTitle(dimension)).font(.subheadline).foregroundStyle(FireStyle.muted) }
                    DetailRow(label: "Normalized evidence changed", value: comparison.normalizedEvidenceChanged ? "Yes" : "No")
                    DetailRow(label: "Source bytes changed", value: comparison.sourceBytesChanged.map { $0 ? "Yes" : "No" } ?? "Unknown")
                    DetailRow(label: "Introduced / absent finding groups", value: "\(comparison.findings.introducedKeys.count) / \(comparison.findings.removedKeys.count)")
                    DetailRow(label: "Changed / unchanged finding groups", value: "\(comparison.findings.changedKeys.count) / \(comparison.findings.unchangedKeys.count)")
                    ForEach(Array(comparison.limitations.enumerated()), id: \.offset) { _, limitation in Text(verbatim: limitation).font(.footnote).foregroundStyle(FireStyle.muted) }
                } else { Text("No earlier saved analysis baseline is attached to this revision.").font(.footnote).foregroundStyle(FireStyle.muted) }
            }
        }
    }
    private func dimensionTitle(_ dimension: AnalysisChangeDimension) -> String {
        switch dimension {
        case .reportIdentity: "Report identity"
        case .sourceIdentity: "Source identity"
        case .normalizedEvidence: "Normalized evidence"
        case .evidenceReferences: "Evidence references"
        case .importTime: "Import time"
        case .reportMetadata: "Report metadata"
        case .parserVersion: "Parser version"
        case .normalizationVersion: "Normalization version"
        case .rulesetVersion: "Ruleset version"
        case .scoringVersion: "Scoring version"
        case .actionCatalogVersion: "Action catalog version"
        case .knowledgeVersion: "Knowledge version"
        case .reviewedKnowledge: "Reviewed knowledge context"
        case .profile: "Privacy priorities"
        case .permissionAudit: "Manual permission audit"
        case .domainOverrides: "Local domain choices"
        case .publisherIdentities: "Publisher identities"
        case .protection: "Protection state"
        case .scoringPreference: "Overall-summary preference"
        case .findingDecisions: "Your finding-review decisions"
        case .evaluationTime: "Evaluation time"
        case .analysisOutput: "Analysis output"
        }
    }
}

struct ReportComparisonView: View {
    let comparison: ReportComparison
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Two historical snapshots", title: "What the exports show.", subtitle: "Changes below compare recorded totals. Export windows can overlap, so a delta is not a measured change in behavior.")
            TextListCard(title: "Read the comparison carefully", strings: comparison.warnings)
            FireCard {
                VStack(spacing: 14) {
                    DetailRow(label: "Inferred time coverage", value: coverageLabel)
                    DetailRow(label: "Source bytes changed", value: comparison.sourceBytesChanged.map { $0 ? "Yes" : "No" } ?? "Unknown")
                    DetailRow(label: "Normalized evidence changed", value: comparison.normalizedEvidenceChanged ? "Yes" : "No")
                    DetailRow(label: "Analysis revision changed", value: comparison.analysisRevisionChanged.map { $0 ? "Yes" : "No" } ?? "Unknown")
                    countRow("Network contacts", change: comparison.totalContactChange)
                    countRow("Sensor event records", change: comparison.sensorEventRecordChange)
                    countRow("Sensor begin records", change: comparison.sensorBeginRecordChange)
                }
            }
            TextListCard(title: "App identifiers present only in the later export", strings: comparison.appsPresentOnlyLater)
            TextListCard(title: "App identifiers present only in the earlier export", strings: comparison.appsPresentOnlyEarlier)
            TextListCard(title: "Domains present only in the later export", strings: comparison.domainsPresentOnlyLater)
            TextListCard(title: "Domains present only in the earlier export", strings: comparison.domainsPresentOnlyEarlier)
            SectionHeading(title: "App contact counts", detail: "Earlier → later recorded totals")
            ForEach(comparison.appContactChanges) { change in FireCard { countRow(change.key, change: change) } }
            SectionHeading(title: "Domain contact counts", detail: "Earlier → later recorded totals")
            ForEach(comparison.domainContactChanges) { change in FireCard { countRow(change.key, change: change) } }
        }.navigationTitle("Compare snapshots")
    }
    private var coverageLabel: String {
        switch comparison.coverage {
        case .unknown: "Unknown"
        case .sameInferredBounds: "Same inferred bounds"
        case .overlappingInferredBounds: "Overlapping inferred bounds"
        case .differentInferredBounds: "Different inferred bounds"
        }
    }
    private func countRow(_ label: String, change: RecordedCountChange) -> some View {
        DetailRow(label: label, value: "\(change.earlierCount) → \(change.laterCount) (delta \(change.delta.map(String.init) ?? "unavailable"))")
    }
}
