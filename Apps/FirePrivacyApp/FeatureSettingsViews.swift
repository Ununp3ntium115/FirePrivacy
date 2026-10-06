import SwiftUI
import FirePrivacyCore

extension PermissionState {
    var displayName: String {
        switch self { case .unknown: "Unknown"; case .notAsked: "Not asked"; case .denied: "Denied"; case .limited: "Limited"; case .allowed: "Allowed"; case .whileUsing: "While using"; case .always: "Always" }
    }
}

extension DomainOverride.Disposition {
    var displayName: String {
        switch self { case .trusted: "Expected by me"; case .alwaysReview: "Always review"; case .customCategory: "My category"; case .localAllow: "Safari allow exception"; case .localBlockRequest: "Safari block request" }
    }
}

struct PrivacyProfileView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = "My priorities"
    @State private var tracking = 45.0
    @State private var location = 55.0
    @State private var analytics = 55.0
    @State private var crashes = 75.0
    @State private var advertising = 40.0
    @State private var social = 50.0
    @State private var role = DeviceRole.personal
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Your priorities", title: "A profile that fits.", subtitle: "Preferences change recommendation relevance. They do not change observations, classification sources or evidence confidence.")
            SectionHeading(title: "Start with a preset")
            ForEach(PrivacyProfile.presets) { profile in
                QuietButton(title: profile.name, symbol: model.preferences.profile.id == profile.id ? "checkmark.circle.fill" : "circle") {
                    var preferences = model.preferences; preferences.profile = profile
                    Task { await model.savePreferences(preferences); loadFields() }
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: "Make it personal", detail: "Tolerance: 0 means less acceptable; 100 means more acceptable. Location sensitivity: 100 means more sensitive.")
                    SettingsTextField(title: "Profile name", text: $name)
                    Picker("Device role", selection: $role) {
                        Text("Personal").tag(DeviceRole.personal); Text("Work").tag(DeviceRole.work); Text("Shared").tag(DeviceRole.shared)
                    }.pickerStyle(.menu)
                    profileSlider("Tracking tolerance", value: $tracking)
                    profileSlider("Location sensitivity", value: $location)
                    profileSlider("Analytics tolerance", value: $analytics)
                    profileSlider("Crash reporting tolerance", value: $crashes)
                    profileSlider("Advertising tolerance", value: $advertising)
                    profileSlider("Social sharing tolerance", value: $social)
                    PrimaryButton(title: "Save custom priorities", symbol: "checkmark") {
                        var preferences = model.preferences
                        preferences.profile = PrivacyProfile(name: name, trackingTolerance: Int(tracking), locationSensitivity: Int(location), analyticsTolerance: Int(analytics), crashReportingTolerance: Int(crashes), advertisingTolerance: Int(advertising), socialSharingTolerance: Int(social), deviceRole: role)
                        Task { await model.savePreferences(preferences) }
                    }
                    Toggle("Request an overall observed posture summary", isOn: Binding(get: { model.preferences.includeOverallScore == true }, set: { value in
                        var preferences = model.preferences; preferences.includeOverallScore = value
                        Task { await model.savePreferences(preferences) }
                    })).tint(FireStyle.ember)
                    Text("The summary remains unavailable when reviewed classification and app relationships are insufficient. Dimensions remain available; none is a safety grade.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
        }.navigationTitle("Privacy priorities").onAppear { loadFields() }
    }
    private func profileSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailRow(label: title, value: Int(value.wrappedValue).formatted())
            Slider(value: value, in: 0...100, step: 1).accessibilityLabel(title).tint(FireStyle.ember)
        }
    }
    private func loadFields() {
        let profile = model.preferences.profile
        name = profile.name; tracking = Double(profile.trackingTolerance); location = Double(profile.locationSensitivity)
        analytics = Double(profile.analyticsTolerance); crashes = Double(profile.crashReportingTolerance)
        advertising = Double(profile.advertisingTolerance); social = Double(profile.socialSharingTolerance); role = profile.deviceRole
    }
}

struct ManualPermissionAuditView: View {
    @EnvironmentObject private var model: AppModel
    @State private var bundleID = ""
    @State private var category = "location"
    @State private var state = PermissionState.unknown
    @State private var expected = "unknown"
    @State private var note = ""
    private let states: [PermissionState] = [.unknown, .notAsked, .denied, .limited, .allowed, .whileUsing, .always]
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "A dated statement by you", title: "Review permissions yourself.", subtitle: "Apple Settings shows current permission choices. This audit records what you report; it is never treated as an automatic reading of another app’s permission.")
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsTextField(title: "App bundle identifier", text: $bundleID)
                    if let apps = model.report?.apps, !apps.isEmpty {
                        Menu("Use an identifier from this report") { ForEach(apps) { app in Button { bundleID = app.bundleID } label: { Text(verbatim: app.bundleID) } } }.frame(minHeight: 44)
                    }
                    Picker("Permission category", selection: $category) { ForEach(["location", "camera", "microphone", "contacts", "photos"], id: \.self) { Text($0.capitalized).tag($0) } }.pickerStyle(.menu)
                    Picker("My observed setting", selection: $state) { ForEach(states, id: \.rawValue) { Text($0.displayName).tag($0) } }.pickerStyle(.menu)
                    Picker("Expected for my use", selection: $expected) { Text("Not sure").tag("unknown"); Text("Expected").tag("yes"); Text("Unexpected").tag("no") }.pickerStyle(.menu)
                    SettingsTextField(title: "Optional private note", text: $note)
                    PrimaryButton(title: "Save my review", symbol: "checklist") {
                        var preferences = model.preferences
                        preferences.permissionAudit.record(SelfReportedPermission(bundleID: bundleID, category: category, state: state, isExpected: expected == "unknown" ? nil : expected == "yes", note: note.isEmpty ? nil : note))
                        Task { await model.savePreferences(preferences) }
                    }.disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ForEach(model.preferences.permissionAudit.entries) { entry in
                FireCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: entry.bundleID).font(.headline).foregroundStyle(FireStyle.text)
                        DetailRow(label: entry.category, value: entry.state.displayName)
                        DetailRow(label: "Self reported", value: entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        if let note = entry.note { Text(verbatim: note).foregroundStyle(FireStyle.muted) }
                        QuietButton(title: "Edit this review", symbol: "pencil") { bundleID = entry.bundleID; category = entry.category; state = entry.state; expected = entry.isExpected.map { $0 ? "yes" : "no" } ?? "unknown"; note = entry.note ?? "" }
                        Button("Remove my review", role: .destructive) {
                            var preferences = model.preferences; preferences.permissionAudit.remove(bundleID: entry.bundleID, category: entry.category)
                            Task { await model.savePreferences(preferences) }
                        }.frame(minHeight: 44)
                    }
                }
            }
        }.navigationTitle("Manual permission audit")
    }
}

struct DomainOverridesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var host: String
    @State private var disposition = DomainOverride.Disposition.trusted
    @State private var category = DomainCategory.unknown
    @State private var note = ""
    init(initialHost: String = "") { _host = State(initialValue: initialHost) }
    private let dispositions: [DomainOverride.Disposition] = [.trusted, .alwaysReview, .customCategory, .localAllow, .localBlockRequest]
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Local choices, separate from signed knowledge", title: "Keep your own context.", subtitle: "Notes and categories are your opinions. Allow and block requests affect Safari rules only after a new scoped consent and successful setup; they are not proof of protection.")
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsTextField(title: "Domain hostname", text: $host)
                    Picker("My choice", selection: $disposition) { ForEach(dispositions, id: \.rawValue) { Text(dispositionTitle($0)).tag($0) } }.pickerStyle(.menu)
                    if disposition == .customCategory { Picker("My category", selection: $category) { ForEach(DomainCategory.allCases, id: \.rawValue) { Text($0.displayName).tag($0) } }.pickerStyle(.menu) }
                    SettingsTextField(title: "Optional private note", text: $note)
                    PrimaryButton(title: "Save local choice", symbol: "checkmark") {
                        guard let identity = DomainIdentity(host) else { return }
                        var preferences = model.preferences
                        preferences.overrides.set(DomainOverride(host: identity, disposition: disposition, customCategories: disposition == .customCategory ? [category] : [], note: note.isEmpty ? nil : note))
                        Task { await model.savePreferences(preferences) }
                    }.disabled(DomainIdentity(host) == nil)
                    NavigationLink { ProtectionSettingsView() } label: { Label("Review and apply Safari configuration", systemImage: "shield").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                }
            }
            ForEach(model.preferences.overrides.sorted) { value in
                FireCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: value.host.value).font(.headline).foregroundStyle(FireStyle.text)
                        DetailRow(label: "Local choice", value: dispositionTitle(value.disposition))
                        if !value.customCategories.isEmpty { DetailRow(label: "Your categories", value: value.customCategories.map(\.displayName).joined(separator: ", ")) }
                        if let note = value.note { Text(verbatim: note).foregroundStyle(FireStyle.muted) }
                        QuietButton(title: "Edit choice", symbol: "pencil") { host = value.host.value; disposition = value.disposition; category = value.customCategories.first ?? .unknown; note = value.note ?? "" }
                        Button("Remove local choice", role: .destructive) {
                            var preferences = model.preferences; preferences.overrides.remove(host: value.host)
                            Task { await model.savePreferences(preferences) }
                        }.frame(minHeight: 44)
                    }
                }
            }
        }.navigationTitle("Local domain choices")
    }
    private func dispositionTitle(_ value: DomainOverride.Disposition) -> String {
        value.displayName
    }
}

struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(FireStyle.muted)
            TextField(title, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

private struct PreparedRequestPresentation: Identifiable {
    let id = UUID()
    let prepared: PreparedEngineRequest
}

struct AdvisorSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var retention = ""
    @State private var certificate = ""
    @State private var token = ""
    @State private var availability = AdvisorAvailability.unavailable
    @State private var preview: PreparedRequestPresentation?
    @State private var showOnDeviceConsent = false
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "An advisor grounded in evidence", title: "Explain. Never invent.", subtitle: "Advisors can order supported findings and choose a reviewed presentation style. Displayed facts, interpretations and actions come from the deterministic engine, not model-authored conclusions.")
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    DetailRow(label: "Selected mode", value: model.preferences.advisorMode.displayName)
                    PrimaryButton(title: "Use offline explanations", symbol: "iphone") {
                        Task { var preferences = model.preferences; preferences.advisorMode = .offline; await model.savePreferences(preferences); await model.assessLocally() }
                    }.disabled(model.analysis == nil)
                    Text("Offline mode makes no model or network request.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Apple on-device advisor", detail: availability.explanation)
                    Text("On supported iOS or iPadOS 26 devices with Apple Intelligence enabled and the model ready, bounded finding references are processed by SystemLanguageModel. No Private Cloud Compute or external fallback is used.").foregroundStyle(FireStyle.muted)
                    QuietButton(title: "Review on-device consent", symbol: "cpu") { showOnDeviceConsent = true }.disabled(availability != .available || model.analysis == nil)
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Your model endpoint", detail: "This optional mode sends a bounded structured reference payload to the HTTPS endpoint you configure. Review the exact request before every send.")
                    SettingsTextField(title: "HTTPS assessment endpoint", text: $endpoint)
                    SettingsTextField(title: "Model name", text: $modelName)
                    SettingsTextField(title: "Operator retention disclosure", text: $retention)
                    SettingsTextField(title: "Optional certificate SHA-256 pin", text: $certificate)
                    SecureField("Optional bearer token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Text("The payload excludes report text, domains, app identifiers, notes and timestamps. The operator still receives connection metadata, model selection and any configured authentication. Its retention or training policy cannot be verified by this app.").font(.footnote).foregroundStyle(FireStyle.muted)
                    QuietButton(title: "Save configuration", symbol: "checkmark") { saveConfiguration() }
                    QuietButton(title: "Retain token in device Keychain", symbol: "key") { let credential = token; token = ""; Task { await model.retainAdvisorCredential(credential) } }.disabled(token.isEmpty || model.preferences.selfHostedConfiguration == nil)
                    QuietButton(title: "Forget all saved advisor tokens", symbol: "trash") { token = ""; Task { await model.forgetAdvisorCredentials() } }
                    PrimaryButton(title: "Prepare exact request preview", symbol: "doc.text.magnifyingglass") {
                        let credential = token.isEmpty ? nil : token; token = ""
                        Task { if let prepared = await model.prepareSelfHostedAssessment(bearerToken: credential) { preview = PreparedRequestPresentation(prepared: prepared) } }
                    }.disabled(model.analysis == nil || model.preferences.selfHostedConfiguration == nil)
                    Text("Preparation uses the saved configuration; it does not send or grant consent. Unsaved edits above are not applied.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            if let result = model.advisorResult {
                FireCard {
                    VStack(alignment: .leading, spacing: 14) {
                        DetailRow(label: "Last explanation mode", value: result.mode.displayName)
                        if result.fallback != nil { Text("The selected advisor could not complete the request. Offline explanations were used.").foregroundStyle(FireStyle.gold) }
                    }
                }
                if let analysis = model.analysis, let explanations = try? AdvisorRenderer.explanations(assessment: result.assessment, analysis: analysis), let report = model.report {
                    ForEach(explanations) { explanation in
                        if let finding = analysis.findings.first(where: { $0.id == explanation.findingID }) {
                            NavigationLink { RuleFindingDetailView(finding: finding, report: report) } label: { RuleFindingRow(finding: finding) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.navigationTitle("Explanation advisor")
        .task { availability = await SystemLanguageModelAdvisor().availability(); loadConfiguration() }
        .sheet(item: $preview) { value in NavigationStack { ExactRequestPreviewView(prepared: value.prepared) } }
        .sheet(isPresented: $showOnDeviceConsent) {
            NavigationStack {
                FeatureConsentView(feature: .onDeviceAdvisor, scope: "system-language-model-v1", title: "Use Apple’s on-device model?", paragraphs: ["Only bounded finding references are processed by SystemLanguageModel on this device. The model can select order and presentation style; deterministic findings supply all displayed evidence and conclusions.", "Requires a supported device, iOS or iPadOS 26, Apple Intelligence enabled, and a ready model. If generation is unavailable or rejected, offline explanations remain available.", "Declining keeps offline explanations available. You can revoke this grant in Trust Center."]) {
                    var preferences = model.preferences; preferences.advisorMode = .appleOnDevice
                    await model.savePreferences(preferences); await model.assessLocally()
                }
            }
        }
    }
    private func loadConfiguration() {
        guard let config = model.preferences.selfHostedConfiguration else { return }
        endpoint = config.endpoint.absoluteString; modelName = config.modelName; retention = config.retentionDisclosure; certificate = config.certificateSHA256 ?? ""
    }
    private func saveConfiguration() {
        do {
            guard let url = URL(string: endpoint) else { throw AdvisorError.invalidConfiguration }
            let config = try SelfHostedAdvisorConfiguration(endpoint: url, modelName: modelName, retentionDisclosure: retention, certificateSHA256: certificate.isEmpty ? nil : certificate)
            var preferences = model.preferences; preferences.selfHostedConfiguration = config; preferences.advisorMode = .selfHosted
            Task { await model.savePreferences(preferences) }
        } catch { model.notice = AppNotice(title: "Configuration needs attention", message: error.localizedDescription) }
    }
}

struct ExactRequestPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prepared: PreparedEngineRequest
    private var feature: ConsentFeature? { prepared.request.purpose.requiredConsent }
    private var granted: Bool {
        guard let feature else { return false }
        return model.consent.activeReceipt(for: feature, disclosureVersion: prepared.preview.disclosureVersion, scopeIdentity: prepared.preview.configurationIdentity) != nil
    }
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Nothing sent during preparation", title: "Inspect this exact request.", subtitle: prepared.preview.disclosure.purpose.title)
            TextListCard(title: "Network disclosure", strings: [prepared.preview.disclosure.destination, prepared.preview.disclosure.payloadDescription, prepared.preview.disclosure.connectionMetadataDescription, prepared.preview.disclosure.retentionDescription, prepared.preview.disclosure.triggerDescription])
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    DetailRow(label: "Authentication", value: prepared.preview.authenticationDescription)
                    DetailRow(label: "Payload SHA-256", value: prepared.preview.payloadSHA256)
                    if let pin = prepared.preview.certificateSHA256 { DetailRow(label: "Certificate pin", value: pin) }
                    SectionHeading(title: "Exact UTF-8 body")
                    Text(verbatim: prepared.preview.payloadUTF8.isEmpty ? "No request body" : prepared.preview.payloadUTF8).font(.system(.caption, design: .monospaced)).foregroundStyle(FireStyle.text).textSelection(.enabled)
                }
            }
            if let feature {
                QuietButton(title: granted ? "Feature consent granted for this configuration" : "Grant consent for this configuration", symbol: granted ? "checkmark.circle" : "hand.raised") {
                    Task { _ = await model.grantFeature(feature, scope: prepared.preview.configurationIdentity, disclosureVersion: prepared.preview.disclosureVersion) }
                }.disabled(granted)
            }
            PrimaryButton(title: "Approve & send this exact request", symbol: "paperplane") { Task { if await model.sendPreparedRequest(prepared) { dismiss() } } }.disabled(!granted || model.isWorking)
            Text("Approval is bound to this payload and configuration. A changed report, preference, credential or consent invalidates it. Declining sends nothing; local analysis remains available.").font(.footnote).foregroundStyle(FireStyle.muted)
        }.navigationTitle("Request preview").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
}

struct FeatureConsentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let feature: ConsentFeature
    let scope: String
    let title: String
    let paragraphs: [String]
    let onGranted: @MainActor () async -> Void
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "A separate, scoped choice", title: title, subtitle: "Disclosure " + ConsentDisclosure.currentVersion)
            TextListCard(title: "Before you decide", strings: paragraphs, symbol: "hand.raised")
            FireCard { DetailRow(label: "Configuration identity", value: scope) }
            PrimaryButton(title: "Grant consent & continue", symbol: "checkmark") {
                Task { if await model.grantFeature(feature, scope: scope) { await onGranted(); dismiss() } }
            }.disabled(model.isWorking)
            QuietButton(title: "Decline", symbol: "xmark") { dismiss() }
        }.navigationTitle("Feature consent").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
}

struct DatasetUpdatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = ""
    @State private var retention = ""
    @State private var purpose = NetworkPurpose.knowledgeBaseUpdate
    @State private var preview: PreparedRequestPresentation?
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Authenticated knowledge, explicit updates", title: "Keep sources accountable.", subtitle: "Signed knowledge, reviewed rule configurations and filter data are verified before activation. A network response is never assumed trustworthy.")
            FireCard {
                VStack(spacing: 14) {
                    DetailRow(label: "Knowledge version", value: model.knowledgeBaseVersion ?? "No usable verified knowledge")
                    DetailRow(label: "Rule analysis version", value: model.rulesVersion)
                    DetailRow(label: "Rule configuration", value: model.ruleConfigurationFailure ? "Rejected candidate; compiled defaults retained" : model.engine.verifiedRuleConfiguration == nil ? "Compiled reviewed defaults" : "Verified signed configuration")
                    DetailRow(label: "Verification status", value: model.knowledgeBaseFailure ? "Unavailable or rejected; evidence remains usable" : "Current engine snapshot")
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Update purpose", selection: $purpose) { Text("Knowledge / reviewed rules").tag(NetworkPurpose.knowledgeBaseUpdate); Text("Filter dataset / revocations").tag(NetworkPurpose.filterListUpdate) }.pickerStyle(.menu)
                    SettingsTextField(title: "HTTPS signed-document endpoint", text: $endpoint)
                    SettingsTextField(title: "Operator retention disclosure", text: $retention)
                    Text("The endpoint receives connection metadata. Updates contain no imported report payload. Supply a real publisher endpoint using this build’s signed update format and trust roots. There is no automatic polling.").foregroundStyle(FireStyle.muted)
                    PrimaryButton(title: "Prepare update preview", symbol: "doc.text.magnifyingglass") {
                        guard let url = URL(string: endpoint) else { model.notice = AppNotice(title: "Invalid endpoint", message: "Enter a valid HTTPS update endpoint."); return }
                        Task { if let request = await model.prepareUpdate(endpoint: url, purpose: purpose, operatorRetention: retention) { preview = PreparedRequestPresentation(prepared: request) } }
                    }.disabled(endpoint.isEmpty || retention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.navigationTitle("Signed updates").sheet(item: $preview) { item in NavigationStack { ExactRequestPreviewView(prepared: item.prepared) } }
    }
}

struct ProtectionStateCard: View {
    let title: String
    let state: ProtectionComponentState
    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: state.isActive ? "checkmark.shield" : "shield.lefthalf.filled").font(.headline).foregroundStyle(state.isActive ? FireStyle.gold : FireStyle.ember)
                DetailRow(label: "System status", value: phaseTitle)
                Text(verbatim: state.detail).foregroundStyle(FireStyle.muted)
                if let version = state.datasetVersion { DetailRow(label: "Dataset version", value: version.formatted()) }
                if let verified = state.verifiedAt { DetailRow(label: "Last status check", value: verified.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
    }
    private var phaseTitle: String {
        switch state.phase {
        case .unavailable: "Unavailable in this configuration"
        case .needsConfiguration: "Configuration needed"
        case .disabled: "Disabled"
        case .awaitingUserEnablement: "Awaiting system enablement"
        case .active: state.isActive ? "Active; system confirmed" : "Awaiting confirmation"
        case .staleDataset: "Dataset expired or stale"
        case .revokedDataset: "Dataset revoked"
        case .failed: "Failed; needs attention"
        }
    }
}

private struct ProtectionConsentPlan: Identifiable {
    let id = UUID()
    let feature: ConsentFeature
    let scope: String
    let title: String
    let paragraphs: [String]
    let dataset: ValidatedFilterDataset?
}

struct ProtectionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var plan: ProtectionConsentPlan?
    @State private var preparing = false
    @State private var urlToken = ""
    private var edition: String { Bundle.main.object(forInfoDictionaryKey: "FirePrivacyDistributionEdition") as? String ?? "consumer" }
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Separate scopes. Real system status.", title: "Protection you can inspect.", subtitle: "Safari blocking, encrypted DNS and approved edition services have distinct coverage. Consent does not establish activation; only a system-confirmed state is shown as active.")
            QuietButton(title: "Refresh system status", symbol: "arrow.clockwise") { Task { await model.refreshProtection() } }
            ProtectionStateCard(title: "Safari content blocking", state: model.protection.safari)
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Safari processes validated local rules. The starter list is intentionally narrow: third-party resources at api.segment.io. It does not control other apps or block all tracking. Rules can break site features; local allow exceptions take precedence.").foregroundStyle(FireStyle.muted)
                    Link("Starter dataset source: Segment documentation", destination: BundledProtectionDataset.safariStarterSourceURL).foregroundStyle(FireStyle.ember).frame(minHeight: 44)
                    QuietButton(title: "Review validated rules & grant", symbol: "safari") { prepare(.safariProtection) }.disabled(preparing || model.protection.safari.phase == .unavailable)
                    NavigationLink { DomainOverridesView() } label: { Label("Edit local allow and block choices", systemImage: "pencil").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                    Button("Revoke & remove Safari rules", role: .destructive) { Task { await model.revokeFeature(.safariProtection) } }.frame(minHeight: 44)
                    Text("After setup, enable Fire Privacy in Settings → Apps → Safari → Extensions or Content Blockers, as offered by your system. Return here and refresh the status. Website-specific choices can limit coverage.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            ProtectionStateCard(title: "Encrypted DNS", state: model.protection.encryptedDNS)
            NavigationLink { DNSResolverSettingsView() } label: { FireCard { Label("Configure and disclose your resolver", systemImage: "network").foregroundStyle(FireStyle.ember) } }.buttonStyle(.plain)
            if model.preferences.dnsConfiguration != nil {
                QuietButton(title: "Review resolver disclosure & grant", symbol: "hand.raised") { prepare(.encryptedDNS) }.disabled(preparing || model.protection.encryptedDNS.phase == .unavailable)
            }
            Button("Revoke & remove DNS configuration", role: .destructive) { Task { await model.revokeFeature(.encryptedDNS) } }.frame(minHeight: 44)
            ProtectionStateCard(title: "System URL filtering", state: model.protection.systemURLFilter)
            if edition == "url-filter" {
                if #available(iOS 26.0, *) {
                    FireCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Requires a signed Apple Bloom dataset, an approved service configuration and this edition’s entitlements. Participating networking APIs determine coverage; it is not whole-device monitoring.").foregroundStyle(FireStyle.muted)
                            SecureField("Service authentication token", text: $urlToken).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                            QuietButton(title: "Review signed URL service & grant", symbol: "link") { prepare(.urlProtection) }.disabled(preparing || urlToken.isEmpty || model.protection.systemURLFilter.phase == .unavailable)
                            Button("Revoke & remove URL filter", role: .destructive) { urlToken = ""; Task { await model.revokeFeature(.urlProtection) } }.frame(minHeight: 44)
                        }
                    }
                } else { Text("URL filtering requires iOS or iPadOS 26 or later.").foregroundStyle(FireStyle.muted) }
            }
            ProtectionStateCard(title: "Managed filtering", state: model.protection.managed)
            if edition == "managed" {
                Text("Managed filtering requires the approved managed edition, the system’s enrollment and entitlement conditions, and a validated signed policy. Consumer devices do not receive managed filtering from a local switch.").foregroundStyle(FireStyle.muted)
                QuietButton(title: "Review signed managed policy & grant", symbol: "building.2") { prepare(.managedProtection) }.disabled(preparing || model.protection.managed.phase == .unavailable)
                Button("Revoke & remove managed filter", role: .destructive) { Task { await model.revokeFeature(.managedProtection) } }.frame(minHeight: 44)
            }
            NavigationLink { DatasetUpdatesView() } label: { Label("Get a signed dataset or revocation update", systemImage: "arrow.down.doc").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
            if !model.pendingSystemCleanup.isEmpty {
                TextListCard(title: "System removal needs attention", strings: model.pendingSystemCleanup.map(\.rawValue).sorted() + ["A previous removal was not confirmed. Retry or review Apple Settings; the app does not claim these components are disabled."])
                QuietButton(title: "Retry system removal", symbol: "arrow.clockwise") { Task { await model.retrySystemCleanup() } }
            }
        }.navigationTitle("Protection setup")
        .task { await model.refreshProtection() }
        .onDisappear { urlToken = "" }
        .sheet(item: $plan, onDismiss: { urlToken = "" }) { value in
            NavigationStack {
                FeatureConsentView(feature: value.feature, scope: value.scope, title: value.title, paragraphs: value.paragraphs) {
                    switch value.feature {
                    case .safariProtection: if let dataset = value.dataset { await model.enableSafari(dataset) }
                    case .encryptedDNS: await model.enableDNS()
                    case .urlProtection: if #available(iOS 26.0, *), let dataset = value.dataset { let credential = urlToken; urlToken = ""; await model.enableURLFilter(dataset, authenticationToken: credential) }
                    case .managedProtection: if let dataset = value.dataset { await model.enableManaged(dataset) }
                    default: break
                    }
                }
            }
        }
    }
    private func prepare(_ feature: ConsentFeature) {
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let decline = "Declining keeps local report analysis available. Revoking consent removes this app’s configuration when the system permits; any failure remains visible for retry."
                switch feature {
                case .safariProtection:
                    let dataset = try await model.engine.filterDataset(.safariDomainsV1)
                    let allowed = model.preferences.overrides.sorted.filter { $0.disposition == .localAllow }.map { $0.host.value }
                    let blocked = model.preferences.overrides.sorted.filter { $0.disposition == .localBlockRequest }.map { $0.host.value }
                    let config = try dataset.safariConfiguration(allowedDomains: allowed, userBlockedDomains: blocked)
                    plan = ProtectionConsentPlan(feature: feature, scope: try config.scopeIdentity, title: "Install these Safari rules?", paragraphs: ["Signed dataset version \(dataset.manifest.version), expires \(dataset.expiresAt.formatted(date: .abbreviated, time: .shortened)). Safari evaluates these rules locally; imported reports and browsing URLs are not uploaded by the extension.", "Dataset domains (first 30 of \(config.blockedDomains.count); includes suffix coverage): " + config.blockedDomains.prefix(30).joined(separator: ", "), "Your allow exceptions: " + (allowed.isEmpty ? "None" : allowed.joined(separator: ", ")), "Your exact-host third-party block requests: " + (blocked.isEmpty ? "None" : blocked.joined(separator: ", ")), "Rules affect matching third-party resources in Safari and may break features. Enable the extension in Settings and refresh system status; setup alone is not activation.", decline], dataset: dataset)
                case .encryptedDNS:
                    guard let config = model.preferences.dnsConfiguration else { throw EngineError.missingConfiguration }
                    let disclosure = NetworkCatalogue.encryptedDNS(resolver: config.serverURL?.absoluteString ?? config.serverName ?? "", operatorName: config.operatorName, retention: config.retentionDisclosure)
                    plan = ProtectionConsentPlan(feature: feature, scope: try config.scopeIdentity, title: "Use this encrypted resolver?", paragraphs: [disclosure.destination, disclosure.payloadDescription, disclosure.connectionMetadataDescription, "Operator: " + config.operatorName, "Logging: " + config.loggingDisclosure, "Retention: " + config.retentionDisclosure, "Jurisdiction: " + config.jurisdictionDisclosure, "Filtering: " + config.filteringDisclosure, "Operator policy: " + config.privacyPolicyURL.absoluteString, "Encryption protects transport to the resolver, not query secrecy from that operator. It does not imply tracker blocking. Confirm the configuration in Apple Settings.", decline], dataset: nil)
                case .urlProtection:
                    let dataset = try await model.engine.filterDataset(.appleURLBloomV1)
                    let config = try dataset.urlConfiguration(controlProviderBundleIdentifier: (Bundle.main.bundleIdentifier ?? "") + ".URLFilterControl")
                    plan = ProtectionConsentPlan(feature: feature, scope: try config.scopeIdentity, title: "Configure this approved URL service?", paragraphs: ["Signed dataset version \(dataset.manifest.version), expires \(dataset.expiresAt.formatted()).", "Private lookup service: " + config.pirServerURL.absoluteString, "Apple-approved configuration identity: " + config.appleApprovedConfigurationIdentity, "The system processes supported URL requests using this service. Fire Privacy does not receive browsing URLs through the API. Service/relay metadata handling depends on the approved configuration. This does not cover all networking.", "Your authentication token is passed only to the system configuration and is not saved in ordinary app preferences. No protection is claimed until the system confirms an active state.", decline], dataset: dataset)
                case .managedProtection:
                    let dataset = try await model.engine.filterDataset(.managedRulesV1)
                    let policy = try JSONDecoder().decode(ManagedPolicy.self, from: dataset.payload)
                    plan = ProtectionConsentPlan(feature: feature, scope: try policy.scopeIdentity, title: "Apply this managed policy?", paragraphs: ["Signed policy version \(dataset.manifest.version), expires \(dataset.expiresAt.formatted()).", String(data: dataset.payload, encoding: .utf8) ?? "Policy payload unavailable", "This system capability requires approved enrollment and entitlements. Filter coverage and restrictions are limited to the signed policy and supported system flows.", decline], dataset: dataset)
                default: throw EngineError.unavailable
                }
            } catch { model.notice = AppNotice(title: "Protection configuration unavailable", message: error.localizedDescription) }
        }
    }
}

struct DNSResolverSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var transport = DNSResolverConfiguration.Transport.https
    @State private var addresses = ""
    @State private var endpoint = ""
    @State private var serverName = ""
    @State private var operatorName = ""
    @State private var privacyURL = ""
    @State private var logging = ""
    @State private var retention = ""
    @State private var jurisdiction = ""
    @State private var filtering = ""
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Name your resolver. Name its trade-offs.", title: "Encrypted transport, disclosed.", subtitle: "Your resolver sees DNS query names. Enter its published policies; saving a configuration does not grant consent or enable it.")
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Transport", selection: $transport) { Text("DNS over HTTPS").tag(DNSResolverConfiguration.Transport.https); Text("DNS over TLS").tag(DNSResolverConfiguration.Transport.tls) }.pickerStyle(.menu)
                    SettingsTextField(title: "Resolver IP addresses, separated by commas", text: $addresses)
                    if transport == .https { SettingsTextField(title: "HTTPS resolver endpoint", text: $endpoint) }
                    else { SettingsTextField(title: "TLS resolver server name", text: $serverName) }
                    SettingsTextField(title: "Operator name", text: $operatorName)
                    SettingsTextField(title: "HTTPS operator privacy policy", text: $privacyURL)
                    SettingsTextField(title: "Logging disclosure", text: $logging)
                    SettingsTextField(title: "Retention disclosure", text: $retention)
                    SettingsTextField(title: "Jurisdiction disclosure", text: $jurisdiction)
                    SettingsTextField(title: "Filtering disclosure", text: $filtering)
                    PrimaryButton(title: "Validate & save resolver", symbol: "checkmark") { save() }
                    NavigationLink { ProtectionSettingsView() } label: { Label("Review consent & enable in Settings", systemImage: "hand.raised").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                }
            }
        }.navigationTitle("Resolver configuration").onAppear { load() }
    }
    private func save() {
        do {
            guard let policy = URL(string: privacyURL) else { throw ProtectionConfigurationError.invalidEndpoint }
            let config = DNSResolverConfiguration(transport: transport, servers: addresses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, serverURL: transport == .https ? URL(string: endpoint) : nil, serverName: transport == .tls ? serverName : nil, operatorName: operatorName, privacyPolicyURL: policy, loggingDisclosure: logging, retentionDisclosure: retention, jurisdictionDisclosure: jurisdiction, filteringDisclosure: filtering)
            try config.validate()
            var preferences = model.preferences; preferences.dnsConfiguration = config
            Task { await model.savePreferences(preferences) }
        } catch { model.notice = AppNotice(title: "Resolver configuration needs attention", message: error.localizedDescription) }
    }
    private func load() {
        guard let config = model.preferences.dnsConfiguration else { return }
        transport = config.transport; addresses = config.servers.joined(separator: ", "); endpoint = config.serverURL?.absoluteString ?? ""; serverName = config.serverName ?? ""; operatorName = config.operatorName; privacyURL = config.privacyPolicyURL.absoluteString; logging = config.loggingDisclosure; retention = config.retentionDisclosure; jurisdiction = config.jurisdictionDisclosure; filtering = config.filteringDisclosure
    }
}
