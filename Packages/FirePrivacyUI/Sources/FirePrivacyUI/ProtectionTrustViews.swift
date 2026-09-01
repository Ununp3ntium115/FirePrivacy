#if canImport(SwiftUI)
import SwiftUI
import ObservationCore
import FindingEngine
import PrivacyProfileKit
import ProtectionKit
import AdvisorKit
import ConsentKit
import TrustCenterKit

/// The complete chain behind one finding (DET-011).
public struct FindingDetailView: View {
    let model: AppModel
    public let finding: Finding

    public init(model: AppModel, finding: Finding) {
        self.model = model
        self.finding = finding
    }

    public var body: some View {
        List {
            Section {
                SeverityBadge(severity: finding.severity, confidence: finding.confidence)
                Text(finding.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Rule \(finding.ruleID) version \(finding.ruleVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Observed") {
                ForEach(finding.observedFacts, id: \.key) { fact in
                    FactRow(label: fact.key.replacingOccurrences(of: "_", with: " ").capitalized, value: fact.value)
                }
            }

            if !finding.inferences.isEmpty {
                Section("Interpretation") {
                    ForEach(finding.inferences, id: \.statement) { inference in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(inference.statement).font(.subheadline)
                            Text("Confidence \(Int(inference.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                UncertaintyList(items: finding.uncertainty)
            }

            Section("What you can do") {
                ForEach(recommendations, id: \.id) { recommendation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recommendation.title).font(.subheadline.weight(.medium))
                        Text(recommendation.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Explanation") {
                if let resolution = model.explanations[finding.id] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(resolution.output.headline).font(.subheadline.weight(.semibold))
                        Text(resolution.output.explanation).font(.footnote)
                        Text(resolution.output.whyItMatters).font(.footnote)
                        Text(resolution.output.uncertainty).font(.caption).foregroundStyle(.secondary)
                        Label(
                            "Generated explanation · \(resolution.effectiveMode.displayName)",
                            systemImage: "text.quote"
                        )
                        .font(.caption)
                        if resolution.fellBack, let reason = resolution.fallbackReason {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Button("Explain this in plain language") {
                        Task { await model.explain(finding) }
                    }
                    .font(.footnote)
                }
            }

            Section("Evidence") {
                ForEach(evidence, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.summary).font(.footnote)
                        Text("\(item.kind.rawValue) · \(item.id)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        ForEach(item.detail.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            Text("\(key): \(value)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Why this was flagged")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recommendations: [Recommendation] {
        finding.recommendationIDs.compactMap { RecommendationCatalog.recommendation(id: $0) }
    }

    private var evidence: [Evidence] {
        guard let result = model.currentResult else { return [] }
        return finding.evidenceIDs.compactMap { result.evidenceByID[$0] }
    }
}

/// The manual verification flow (PER-002).
public struct PermissionAuditView: View {
    public let sensorType: SensorType
    public let bundleID: BundleIdentifier
    @State private var completed: Set<String> = []

    public init(sensorType: SensorType, bundleID: BundleIdentifier) {
        self.sensorType = sensorType
        self.bundleID = bundleID
    }

    public var body: some View {
        List {
            Section {
                Text("Fire Privacy cannot read or change another app's permissions. These are the steps to check it yourself.")
                    .font(.footnote)
                FactRow(label: "Where", value: checklist.settingsPath)
            }

            Section("Steps") {
                ForEach(checklist.steps) { step in
                    Button {
                        if completed.contains(step.id) { completed.remove(step.id) } else { completed.insert(step.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: completed.contains(step.id) ? "checkmark.circle.fill" : "circle")
                            Text(step.text).multilineTextAlignment(.leading)
                        }
                    }
                    .accessibilityAddTraits(completed.contains(step.id) ? [.isButton, .isSelected] : .isButton)
                }
            }

            Section("Before you change anything") {
                Text(checklist.featureImpact).font(.footnote)
                if let alternative = checklist.lessRestrictiveAlternative {
                    Text(alternative).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Keeping the setting as it is remains a valid choice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                #if canImport(UIKit)
                Button("Open Fire Privacy's settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Text("iOS only lets an app open its own settings page, so this opens Fire Privacy's — not \(bundleID.rawValue)'s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .navigationTitle("Check this permission")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var checklist: PermissionAuditChecklist {
        PermissionAuditChecklist.checklist(for: sensorType)
    }
}

/// The Protection screen (§11.6).
public struct ProtectionView: View {
    let model: AppModel
    @State private var showingDisclosure = false
    @State private var pendingProfile: URLFilterProfile = .standard

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("System URL filter") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.protection.urlFilterState.displayName)
                        .font(.headline)
                    Text(model.protection.urlFilterState.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.protection.urlFilterState.isProtecting {
                    Button("Turn off protection", role: .destructive) {
                        Task { await model.disableProtection() }
                    }
                } else {
                    ForEach(URLFilterProfile.allCases.filter(\.isSelectable), id: \.self) { profile in
                        Button("Turn on \(profile.displayName)") {
                            pendingProfile = profile
                            showingDisclosure = true
                        }
                    }
                }
            }

            Section("What this can and cannot cover") {
                ForEach(URLFilterDisclosure.standard(profile: .standard, datasetVersion: "—").notCovered, id: \.self) { item in
                    Text("• \(item)").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Encrypted DNS") {
                Text(model.protection.dnsState == .active ? "Configured." : "Not configured.")
                    .font(.subheadline)
                ForEach(DNSResolverDisclosure.coverageLimits, id: \.self) { item in
                    Text("• \(item)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("If something stops working") {
                ForEach(ProtectionTroubleshooting.steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.subheadline.weight(.medium))
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Protection")
        .sheet(isPresented: $showingDisclosure) {
            URLFilterDisclosureView(
                disclosure: URLFilterDisclosure.standard(
                    profile: pendingProfile,
                    datasetVersion: model.protection.filterDatasetVersion ?? "not installed"
                ),
                onAccept: {
                    showingDisclosure = false
                    Task { await model.enableProtection(profile: pendingProfile) }
                },
                onCancel: { showingDisclosure = false }
            )
        }
    }
}

/// Shown before the filter configuration is saved (URLF-002).
public struct URLFilterDisclosureView: View {
    public let disclosure: URLFilterDisclosure
    public let onAccept: () -> Void
    public let onCancel: () -> Void

    public init(disclosure: URLFilterDisclosure, onAccept: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.disclosure = disclosure
        self.onAccept = onAccept
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("What gets blocked") {
                    ForEach(disclosure.blockedCategories, id: \.self) { Text($0) }
                }
                Section("What is covered") {
                    ForEach(disclosure.covered, id: \.self) { Text($0).font(.footnote) }
                }
                Section("What is not covered") {
                    ForEach(disclosure.notCovered, id: \.self) { Text($0).font(.footnote) }
                }
                Section("How your privacy is preserved") {
                    ForEach(disclosure.privacyStatements, id: \.self) { Text($0).font(.footnote) }
                }
                Section("How to turn it off") {
                    ForEach(disclosure.howToTurnOff, id: \.self) { Text($0).font(.footnote) }
                }
                if let warning = disclosure.profile.breakageWarning {
                    Section {
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    FactRow(label: "List version", value: disclosure.datasetVersion)
                }
            }
            .navigationTitle("Before you turn this on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Turn on", action: onAccept) }
            }
        }
    }
}

/// The Trust Center (§11.8).
public struct TrustCenterView: View {
    let model: AppModel
    @State private var confirmingDelete = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if let inventory = model.inventory {
                Section("What Fire Privacy knows") {
                    Text(inventory.headline).font(.subheadline)
                    FactRow(label: "Imports", value: String(inventory.sessionCount))
                    FactRow(label: "Observations", value: String(inventory.observationCount))
                    FactRow(label: "Findings", value: String(inventory.findingCount))
                    FactRow(label: "Explanations cached", value: String(inventory.explanationCount))
                    FactRow(label: "Your overrides", value: String(inventory.overrideCount))
                    FactRow(label: "Retained source files", value: String(inventory.retainedRawFileCount))
                    FactRow(label: "Storage used", value: "\(inventory.storageBytes / 1024) KB")
                }

                Section("Versions") {
                    FactRow(label: "Knowledge base", value: inventory.knowledgeBaseVersion)
                    FactRow(label: "Filter list", value: inventory.filterDatasetVersion ?? "not installed")
                    FactRow(label: "App", value: model.appVersion)
                }

                Section("Turned on") {
                    if inventory.activeConsents.isEmpty {
                        Text("Nothing optional is turned on.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(inventory.activeConsents, id: \.rawValue) { consent in
                        Text(consent.displayName).font(.footnote)
                    }
                }
            }

            Section("What leaves this iPhone") {
                ForEach(NetworkLedger.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.purpose).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(entry.carriesUserData ? "carries your data" : "no data about you")
                                .font(.caption2)
                                .foregroundStyle(entry.carriesUserData ? .orange : .secondary)
                        }
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section("Explanations") {
                Picker("Mode", selection: Binding(
                    get: { model.advisorMode },
                    set: { mode in Task { await model.setAdvisorMode(mode) } }
                )) {
                    ForEach(AdvisorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(model.advisorMode.dataFlowDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.advisorMode.sendsDataOffDevice {
                    Label("This mode sends data off this iPhone.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Your data") {
                Button("Delete all Fire Privacy data", role: .destructive) {
                    confirmingDelete = true
                }
                Text("Deletes imports, observations, findings, explanations, overrides and the encryption key. Protection configurations are removed separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Trust Center")
        .task { await model.refreshInventory() }
        .confirmationDialog(
            "Delete everything Fire Privacy holds?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task { await model.deleteEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Your original file in Files is not touched.")
        }
    }
}

/// First run (§11.2).
public struct OnboardingView: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var page = 0
    @State private var showingImporter = false

    public init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your data. Your rules.")
                        .font(.largeTitle.weight(.bold))
                    Text("Fire Privacy turns Apple's privacy activity into clear, evidence-backed choices. Your reports stay on this iPhone unless you choose to export them or turn on an external model.")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 12) {
                        promise("On-device by default", "Importing, analyzing and exporting happen here, with no connection.")
                        promise("No advertising, no resale", "Fire Privacy contains no advertising SDK, no cross-app identifier and no analytics about you.")
                        promise("AI is optional", "Explanations can be produced without any model, and turning models off loses no detection.")
                        promise("You approve every change", "Nothing is switched on for you.")
                        promise("Evidence and uncertainty", "Every finding shows what it rests on and what it does not establish.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What Fire Privacy cannot do")
                            .font(.headline)
                        Text("It cannot list every app on your iPhone, read another app's current permissions, see inside another app's traffic, or change a setting for you. It reads the report you export and tells you what that report supports.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Analyze a report", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task {
                                await model.importDemoReport()
                                isPresented = false
                            }
                        } label: {
                            Label("Explore the demo", systemImage: "theatermasks")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        NavigationLink("How to turn on App Privacy Report") {
                            EnableReportGuideView()
                        }
                        .font(.footnote)

                        Button("Skip for now") { isPresented = false }
                            .font(.footnote)
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: ImportFileTypes.accepted,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                await model.importSecurityScoped(url: url)
                isPresented = false
            }
        }
    }

    private func promise(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "checkmark.seal")
                .font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Version-aware instructions for turning the report on (§11.2, screen 4).
public struct EnableReportGuideView: View {
    public init() {}

    public var body: some View {
        List {
            Section("On iOS 18 and later") {
                Text("1. Open Settings.")
                Text("2. Tap Privacy & Security.")
                Text("3. Tap App Privacy Report.")
                Text("4. Turn on App Privacy Report.")
                Text("5. Wait a few days so the report has activity to show.")
                Text("6. Return to App Privacy Report and use the share button to save the file.")
                Text("7. Come back here and choose Analyze a report.")
            }
            Section {
                Text("iOS collects this report for you whether or not Fire Privacy is installed. Fire Privacy only reads the copy you export.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Turn on App Privacy Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
