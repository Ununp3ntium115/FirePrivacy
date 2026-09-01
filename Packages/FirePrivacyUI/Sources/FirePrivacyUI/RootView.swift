#if canImport(SwiftUI)
import SwiftUI
import ObservationCore
import FindingEngine
import ProtectionKit
import AdvisorKit
import ReportKit
import UniformTypeIdentifiers

/// Five tabs on iPhone, with the advisor reachable from Overview and from a
/// finding rather than taking a permanent slot (§11.1).
public struct RootView: View {
    @State private var model: AppModel
    @State private var selection: Tab = .overview
    @State private var showOnboarding = false

    public enum Tab: Hashable {
        case overview, apps, activity, protection, trust
    }

    public init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        TabView(selection: $selection) {
            NavigationStack { OverviewView(model: model) }
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                .tag(Tab.overview)

            NavigationStack { AppListView(model: model) }
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(Tab.apps)

            NavigationStack { ActivityView(model: model) }
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(Tab.activity)

            NavigationStack { ProtectionView(model: model) }
                .tabItem { Label("Protection", systemImage: "shield") }
                .tag(Tab.protection)

            NavigationStack { TrustCenterView(model: model) }
                .tabItem { Label("Trust", systemImage: "lock.shield") }
                .tag(Tab.trust)
        }
        .task {
            await model.start()
            showOnboarding = model.phase == .needsOnboarding
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(model: model, isPresented: $showOnboarding)
        }
    }
}

public struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var showingImporter = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.latestSession?.snapshot.session.isDemoData == true {
                    DemoDataBanner()
                }

                freshnessCard

                if let result = model.currentResult {
                    postureSection(result)
                    prioritySection(result)
                } else {
                    ContentUnavailableView(
                        "No report analyzed yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Import an App Privacy Report from Settings, or explore the demo to see what Fire Privacy shows.")
                    )
                }

                if let comparison = model.comparison {
                    changeCard(comparison)
                }

                protectionCard
            }
            .padding()
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import", systemImage: "square.and.arrow.down") { showingImporter = true }
                    .accessibilityLabel("Import an App Privacy Report")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: ImportFileTypes.accepted,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importSecurityScoped(url: url) }
        }
    }

    private var freshnessCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Where this comes from", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            if let session = model.latestSession?.snapshot.session {
                Text("Imported \(session.importedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.footnote)
                if let interval = session.coveredInterval {
                    Text("Covers \(interval.start.formatted(date: .abbreviated, time: .omitted)) to \(interval.end.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.footnote)
                } else {
                    Text("The covered window could not be determined from this file.")
                        .font(.footnote)
                }
                if session.status != .complete {
                    Text("Some lines could not be read, so these results may be incomplete.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Nothing imported yet.").font(.footnote)
            }
            if let result = model.currentResult {
                Text("Knowledge base \(result.knowledgeBaseVersion.datasetVersion) · rules \(result.ruleSetVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func postureSection(_ result: FindingEvaluationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Privacy posture")
                    .font(.headline)
                Spacer()
                NavigationLink("How is this calculated?") {
                    ScoreExplanationView(scores: result.scores)
                }
                .font(.footnote)
            }
            Text("\(result.scores.privacyPosture)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Privacy posture \(result.scores.privacyPosture) out of 100, where higher is better.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                DimensionCard(title: "Sensor exposure", value: result.scores.sensorExposure, explanation: result.scores.explanation["sensorExposure"] ?? "")
                DimensionCard(title: "Third-party reach", value: result.scores.thirdPartyReach, explanation: result.scores.explanation["thirdPartyReach"] ?? "")
                DimensionCard(title: "Aggregation signals", value: result.scores.aggregationSignals, explanation: result.scores.explanation["aggregationSignals"] ?? "")
                DimensionCard(title: "Repetition", value: result.scores.repetition, explanation: result.scores.explanation["repetition"] ?? "")
                DimensionCard(title: "Control gap", value: result.scores.controlGap, explanation: result.scores.explanation["controlGap"] ?? "")
                DimensionCard(title: "Evidence confidence", value: result.scores.evidenceConfidence, higherIsBetter: true, explanation: result.scores.explanation["evidenceConfidence"] ?? "")
            }
        }
    }

    private func prioritySection(_ result: FindingEvaluationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to look at first")
                .font(.headline)
            if result.priorityFindings.isEmpty {
                Text("Nothing in this report met the threshold for a finding.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(result.priorityFindings) { finding in
                NavigationLink {
                    FindingDetailView(model: model, finding: finding)
                } label: {
                    FindingRow(finding: finding)
                }
                .buttonStyle(.plain)
            }
            if result.findings.count > result.priorityFindings.count {
                NavigationLink("See all \(result.findings.count) findings") {
                    AllFindingsView(model: model, findings: result.findings)
                }
                .font(.footnote)
            }
        }
    }

    private func changeCard(_ comparison: ReportComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What changed", systemImage: "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
            Text(comparison.headline).font(.footnote)
            if let note = comparison.attributionNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Protection", systemImage: "shield")
                .font(.subheadline.weight(.semibold))
            Text(model.protection.urlFilterState.displayName)
                .font(.footnote.weight(.semibold))
            Text(model.protection.urlFilterState.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

public struct FindingRow: View {
    public let finding: Finding

    public init(finding: Finding) {
        self.finding = finding
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SeverityBadge(severity: finding.severity, confidence: finding.confidence)
            Text(finding.title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                Text(finding.ruleID)
                if finding.isStale {
                    Text("· classifications may be out of date")
                }
                if finding.status == .recurring {
                    Text("· seen before")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

public struct ScoreExplanationView: View {
    public let scores: PostureScores

    public init(scores: PostureScores) {
        self.scores = scores
    }

    public var body: some View {
        List {
            Section("What these numbers mean") {
                Text("Each dimension is scored separately so you can see which part of the picture drives the summary. The summary is not a safety grade and not a legal judgement.")
                    .font(.footnote)
            }
            ForEach(scores.explanation.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.subheadline.weight(.semibold))
                    Text(value).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("How this is calculated")
    }
}

public struct AllFindingsView: View {
    let model: AppModel
    public let findings: [Finding]

    public init(model: AppModel, findings: [Finding]) {
        self.model = model
        self.findings = findings
    }

    public var body: some View {
        List(findings) { finding in
            NavigationLink {
                FindingDetailView(model: model, finding: finding)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    SeverityBadge(severity: finding.severity, confidence: finding.confidence)
                    Text(finding.title).font(.subheadline)
                }
            }
        }
        .navigationTitle("All findings")
    }
}

/// File types the picker accepts (IMP-001).
///
/// `.txt` is included because the export is sometimes saved with that
/// extension; the content is validated either way.
public enum ImportFileTypes {
    public static let accepted: [UTType] = [
        UTType(filenameExtension: "ndjson") ?? .json,
        UTType(filenameExtension: "jsonl") ?? .json,
        .json,
        .plainText,
    ]
}
#endif
