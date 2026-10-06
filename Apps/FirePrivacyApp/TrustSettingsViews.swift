import SwiftUI
import FirePrivacyCore

enum PublicLinks {
    static var privacy: URL? { validURL(for: "FirePrivacyPrivacyURL") }
    static var support: URL? { validURL(for: "FirePrivacySupportURL") }

    private static func validURL(for key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}

extension ConsentFeature {
    var displayName: String {
        switch self {
        case .localImport: "Local report import"
        case .knowledgeBaseUpdates: "Knowledge-base updates"
        case .filterDatasetUpdates: "Filter dataset updates"
        case .selfHostedAdvisor: "Your model endpoint"
        case .onDeviceAdvisor: "Apple on-device advisor"
        case .safariProtection: "Safari content blocking"
        case .encryptedDNS: "Encrypted DNS"
        case .urlProtection: "System URL filtering"
        case .managedProtection: "Managed filtering"
        case .diagnosticsExport: "Sanitized diagnostics export"
        case .retainEncryptedSource: "Encrypted original source retention"
        case .localReminders: "Local reminders"
        case .privateCloudCompute: "Private Cloud Compute"
        }
    }
}

struct TrustCenterView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Trust is something you can inspect", title: "Clear by choice.", subtitle: "Inspect stored consent, verified knowledge, real system protection states and the local inventory of app-created network requests.")
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    TrustFact(symbol: "iphone", title: "Deterministic analysis stays local", detail: "Importing, saving and running versioned finding rules do not send report data. Optional network updates and a self-hosted advisor require separate scoped consent and approval of the exact request.")
                    TrustFact(symbol: "lock", title: "Encrypted workspace", detail: "Report history and private preferences are AES-GCM encrypted in protected app storage, excluded from backups, with device-only unlocked Keychain keys. No app-controlled cloud sync, accounts, advertising SDKs or telemetry are present.")
                    TrustFact(symbol: "doc", title: "Source retention is optional", detail: "Original source bytes are discarded after import unless you separately grant encrypted source retention and choose it for that import. Your original in Files is never modified. Revoking retention removes this app’s retained source copies.")
                    TrustFact(symbol: "square.and.arrow.up", title: "Sharing is deliberate", detail: "Full or redacted exports and sanitized diagnostics are prepared locally for the system share sheet. Protected temporary decrypted files are removed after sharing or at next launch; external copies remain with your chosen destination.")
                }
            }
            SectionHeading(title: "Verified knowledge")
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    DetailRow(label: "Knowledge version", value: model.knowledgeBaseVersion ?? "Unavailable")
                    DetailRow(label: "Verification failure", value: model.knowledgeBaseFailure ? "Needs attention; imported evidence remains usable" : "No failure in current snapshot")
                    DetailRow(label: "Publisher trust configuration", value: model.engine.datasetTrustConfigurationFailure ? "Rejected or unavailable" : "Loaded")
                    DetailRow(label: "Knowledge signing key IDs", value: model.engine.knowledgeTrustKeyIDs.joined(separator: ", "))
                    DetailRow(label: "Filter signing key IDs", value: model.engine.filterTrustKeyIDs.joined(separator: ", "))
                    if let knowledge = model.engine.knowledgeBase {
                        DetailRow(label: "Knowledge expiry", value: Date(timeIntervalSince1970: Double(knowledge.manifest.expiresAt)).formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("Classification describes documented business or infrastructure, not observed conduct. Missing, expired or rejected knowledge remains unknown. Local opinions are separate from signed sources.").foregroundStyle(FireStyle.muted)
                    NavigationLink { DatasetUpdatesView() } label: { Label("Review signed updates", systemImage: "arrow.down.doc").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                }
            }
            SectionHeading(title: "Reviewed rule configuration")
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    DetailRow(label: "Active analysis version", value: model.rulesVersion)
                    DetailRow(label: "Configuration state", value: model.engine.verifiedRuleConfiguration == nil ? "Compiled reviewed defaults" : "Verified signed configuration")
                    DetailRow(label: "Configuration failure", value: model.ruleConfigurationFailure ? "Candidate rejected or unavailable; compiled defaults retained" : "No failure in current snapshot")
                    if let verified = model.engine.verifiedRuleConfiguration {
                        DetailRow(label: "Signed configuration version", value: verified.manifest.configurationVersion)
                        DetailRow(label: "Payload SHA-256", value: verified.manifest.payloadSHA256)
                        DetailRow(label: "Manifest SHA-256", value: verified.manifestSHA256)
                        DetailRow(label: "Signer key ID", value: verified.manifest.signingKeyID)
                        DetailRow(label: "Expires", value: Date(timeIntervalSince1970: Double(verified.manifest.expiresAt)).formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("Updates can configure reviewed rule parameters within this build’s closed schema. They cannot introduce executable code or invented recommendation steps. They use the same explicit knowledge update request and signature checks.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            SectionHeading(title: "System protection inventory")
            ProtectionStateCard(title: "Safari", state: model.protection.safari)
            ProtectionStateCard(title: "Encrypted DNS", state: model.protection.encryptedDNS)
            ProtectionStateCard(title: "System URL filtering", state: model.protection.systemURLFilter)
            ProtectionStateCard(title: "Managed filtering", state: model.protection.managed)
            NavigationLink { ProtectionSettingsView() } label: { Label("Review configuration & system confirmation", systemImage: "shield").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
            SectionHeading(title: "Consent receipts", detail: "A grant is scoped to a disclosed configuration and is separate from actual activation. Revocation cancels approved requests and removes associated settings where supported; failures remain visible.")
            if model.consent.receipts.isEmpty { EmptyState(symbol: "hand.raised", title: "No saved grants", message: "Optional features stay unavailable until you make their separate choices.") }
            ForEach(model.consent.receipts.reversed()) { receipt in
                FireCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailRow(label: receipt.feature.displayName, value: receipt.isActive ? "Granted" : "Revoked")
                        DetailRow(label: "Disclosure", value: receipt.disclosureVersion)
                        DetailRow(label: "Granted", value: receipt.grantedAt.formatted(date: .abbreviated, time: .shortened))
                        if let revoked = receipt.revokedAt { DetailRow(label: "Revoked", value: revoked.formatted(date: .abbreviated, time: .shortened)) }
                        if let scope = receipt.scopeIdentity { DetailRow(label: "Scope identity", value: scope) }
                        if receipt.isActive {
                            Button("Revoke " + receipt.feature.displayName, role: .destructive) { Task { await model.revokeFeature(receipt.feature) } }.frame(minHeight: 44)
                        }
                    }
                }
            }
            if !model.pendingSystemCleanup.isEmpty {
                TextListCard(title: "Removal still needs confirmation", strings: model.pendingSystemCleanup.map(\.displayName).sorted())
                QuietButton(title: "Retry system removal", symbol: "arrow.clockwise") { Task { await model.retrySystemCleanup() } }
            }
            SectionHeading(title: "App-created network inventory", detail: "A bounded local ledger records purpose, host, time, phase and byte counts. It excludes payloads, URL paths, credentials, report identifiers and server messages. System DNS, URL service traffic, browser links and share destinations are not observed here.")
            if model.networkEvents.isEmpty { EmptyState(symbol: "network", title: "No app-created requests recorded", message: "Preparing a preview does not send a request. System-controlled networking is outside this ledger’s coverage.") }
            ForEach(model.networkEvents.reversed()) { event in
                FireCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(event.purpose.title).font(.headline).foregroundStyle(FireStyle.text)
                        DetailRow(label: "Destination host", value: event.host)
                        DetailRow(label: "Phase", value: event.phase.rawValue.capitalized)
                        DetailRow(label: "Time", value: event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        DetailRow(label: "Request bytes", value: event.requestByteCount.formatted())
                        DetailRow(label: "Response bytes", value: event.responseByteCount?.formatted() ?? "Not recorded")
                        if let status = event.statusCode { DetailRow(label: "HTTP status", value: status.formatted()) }
                    }
                }
            }
            TextListCard(title: "Evidence boundaries", strings: ["A domain contact does not reveal payloads, prove personal data transmission, or establish harm. Counts show frequency, not volume.", "Sensor begin/end records can describe one access. Historical exports do not reveal current permission choices.", "App identifiers are not an installed-app inventory. Unknown owners and app relationships remain unknown.", "Private Cloud Compute is unavailable in this build. The on-device advisor uses only SystemLanguageModel; external model processing uses only your explicitly configured endpoint."])
            NavigationLink { PrivacyPolicyView() } label: { Label("Read the privacy policy", systemImage: "doc.text").font(.headline).foregroundStyle(FireStyle.ember).padding(.vertical, 12) }.accessibilityIdentifier("privacy-policy-link")
            if let support = PublicLinks.support {
                Link("Support in your browser", destination: support).foregroundStyle(FireStyle.ember).frame(minHeight: 44)
                Text("The configured support route may be public. Share synthetic reproductions only; never post reports, private identifiers or secrets. Use the repository’s private security-report route for sensitive vulnerabilities.").font(.footnote).foregroundStyle(FireStyle.muted)
            }
        }.accessibilityIdentifier("trust-screen")
    }
}

private struct TrustFact: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(FireStyle.ember).frame(width: 24).padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline).foregroundStyle(FireStyle.text)
                Text(detail).font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showExportConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var format = ExportFormat.json
    @State private var redacted = true
    @State private var showSourceConsent = false
    @State private var showDiagnosticsConsent = false
    @State private var diagnosticsApproved = false
    private var savedState: String {
        if model.savedReportUnavailable { return "Saved data needs attention" }
        if model.hasSavedReport { return model.isDemo ? "Encrypted history retained; sample shown" : "\(model.sessions.count) saved snapshots" }
        return model.isDemo ? "Sample only; no report saved" : "No report saved"
    }
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Your data, your decisions", title: "Keep what you need.", subtitle: "Choose your priorities, configure optional features and control the encrypted history on this device.")
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: "Your reports")
                    DetailRow(label: "Saved data", value: savedState)
                    DetailRow(label: "Storage", value: "Encrypted; excluded from backup")
                    PrimaryButton(title: "Import privacy report", symbol: "square.and.arrow.down") { model.requestImport() }
                    Toggle("Retain encrypted source for my next import", isOn: Binding(get: { model.retainEncryptedSourceForNextImport }, set: { enabled in
                        if enabled { showSourceConsent = true } else { model.retainEncryptedSourceForNextImport = false }
                    })).tint(FireStyle.ember)
                    Text("Off by default. Retained original bytes contain sensitive source metadata and consume your storage budget. The original in Files remains outside this app.").font(.footnote).foregroundStyle(FireStyle.muted)
                    NavigationLink { ImportGuideView() } label: { Label("How to export from Settings", systemImage: "questionmark.circle").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                    NavigationLink { ReportHistoryView() } label: { Label("Encrypted report history & comparison", systemImage: "clock").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                    QuietButton(title: "Explore a sample", symbol: "sparkles") { model.showDemo() }
                    if model.hasSavedReport { QuietButton(title: model.isDemo ? "Return to saved report" : "Reload saved report", symbol: "arrow.clockwise") { Task { await model.restoreSavedReport() } } }
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Delete all app data", detail: "Removes encrypted history, private preferences, credentials, consent, temporary exports and encryption keys. System protection removal is attempted first; failures remain visible and retryable.")
                    Button("Delete all app data", role: .destructive) { showDeleteConfirmation = true }.frame(minHeight: 44).accessibilityIdentifier("delete-all-button")
                    Text("Originals in Files and exports already shared elsewhere remain outside this app’s control.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            SectionHeading(title: "Make it yours")
            settingsLink("Privacy priorities", symbol: "slider.horizontal.3") { PrivacyProfileView() }
            settingsLink("Manual permission audit", symbol: "checklist") { ManualPermissionAuditView() }
            settingsLink("Local domain choices", symbol: "pencil") { DomainOverridesView() }
            settingsLink("Explanation advisor", symbol: "text.bubble") { AdvisorSettingsView() }
            settingsLink("Protection setup", symbol: "shield") { ProtectionSettingsView() }
            settingsLink("Signed knowledge & filter updates", symbol: "arrow.down.doc") { DatasetUpdatesView() }
            settingsLink("Local review reminders", symbol: "bell") { ReminderSettingsView() }
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Export with care", detail: "Prepare the displayed report locally as JSON, CSV or Markdown, then choose a destination in the system share sheet.")
                    Picker("Export format", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) } }.pickerStyle(.menu)
                    Toggle("Redact selected identifiers and private fields", isOn: $redacted).tint(FireStyle.ember)
                    Text(redacted ? "Redaction replaces app/domain identifiers and omits timestamps, context, owners, provenance and narrative. Counts, record order and patterns remain; it is not guaranteed anonymity." : "Full exports contain sensitive identifiers, timestamps, context and analysis. Your destination can transmit or retain them.").font(.footnote).foregroundStyle(FireStyle.muted)
                    if model.isDemo { Text("The displayed export is explicitly labeled synthetic demo data.").foregroundStyle(FireStyle.gold) }
                    QuietButton(title: "Prepare report export", symbol: "square.and.arrow.up") { showExportConfirmation = true }.disabled(model.report == nil).accessibilityIdentifier("export-report-button")
                    QuietButton(title: "Review sanitized diagnostics export", symbol: "wrench.and.screwdriver") { showDiagnosticsConsent = true }
                }
            }
            settingsLink("Retention, key rotation & cleanup", symbol: "lock.rotation") { StorageSettingsView() }
            FireCard { DetailRow(label: "Build", value: appVersion) }
            settingsLink("Third-party notices · readable offline", symbol: "doc.plaintext") { ThirdPartyNoticesView() }
        }.accessibilityIdentifier("settings-screen")
        .confirmationDialog("Share this report?", isPresented: $showExportConfirmation, titleVisibility: .visible) {
            Button("Prepare export & choose destination") { Task { await model.prepareExport(format: format, options: redacted ? .redacted : .full) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("A decrypted temporary copy is prepared for your chosen destination. Redaction removes selected fields but does not guarantee anonymity. Share only with people and services you trust.") }
        .confirmationDialog("Delete all Fire Privacy data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete all app data", role: .destructive) { Task { await model.deleteAll() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This cannot be undone. All saved app data and keys are removed, with any failure shown. Originals in Files and external copies remain. System removals that fail will require retry or review in Apple Settings.") }
        .sheet(isPresented: $showSourceConsent) {
            NavigationStack { FeatureConsentView(feature: .retainEncryptedSource, scope: "encrypted-source-v1", title: "Retain original source bytes?", paragraphs: ["The original selected file can include private app/domain identifiers, timestamps, source names and metadata. A copy is saved only in protected, backup-excluded AES-GCM encrypted storage on this device.", "This selection applies to your next import. Retained sources consume the same bounded workspace budget. Report deletion and retention eviction remove associated source copies. Revoking this feature removes all retained source copies in Fire Privacy.", "Declining retains normalized report evidence only. The original in Files is never modified; its provider controls its own storage."]) { model.retainEncryptedSourceForNextImport = true } }
        }
        .sheet(isPresented: $showDiagnosticsConsent, onDismiss: {
            if diagnosticsApproved { diagnosticsApproved = false; Task { await model.prepareDiagnostics() } }
        }) {
            NavigationStack { FeatureConsentView(feature: .diagnosticsExport, scope: "sanitized-diagnostics-v1", title: "Prepare sanitized diagnostics?", paragraphs: ["Diagnostics include app/OS/parser versions, aggregate report and record counts, skipped-line counts and fixed event codes. They exclude report identifiers, contents, source hashes, notes, URLs and arbitrary messages.", "A protected temporary file is shared only through the destination you select. The destination controls transmission and retention. Even aggregate counts can be sensitive.", "Declining prepares no file. Temporary files are removed after the share sheet closes or at next launch."]) { diagnosticsApproved = true } }
        }
    }
    private func settingsLink<Destination: View>(_ title: String, symbol: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) { FireCard { Label(title, systemImage: symbol).font(.headline).foregroundStyle(FireStyle.ember).frame(maxWidth: .infinity, alignment: .leading) } }.buttonStyle(.plain)
    }
    private var appVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–") + ")" }
}

struct StorageSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reports = 10
    @State private var mebibytes = 64
    @State private var showRetentionConfirmation = false
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Bounded, encrypted, on this device", title: "A smaller footprint.", subtitle: "Retention removes the oldest saved imports as needed. Deletion and key rotation show incomplete cleanup instead of silently claiming success.")
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    DetailRow(label: "Current report limit", value: model.retention.maximumReports.formatted())
                    DetailRow(label: "Current encrypted-byte limit", value: ByteCountFormatter.string(fromByteCount: Int64(model.retention.maximumStoredBytes), countStyle: .file))
                    Stepper("Keep at most \(reports) reports", value: $reports, in: 1...20)
                    Stepper("Workspace limit: \(mebibytes) MiB", value: $mebibytes, in: 1...64)
                    PrimaryButton(title: "Apply retention limits", symbol: "archivebox") { showRetentionConfirmation = true }
                    Text("Saved reports and optional encrypted original bytes share this budget. Lowering it can permanently delete older snapshots immediately.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Encryption key rotation", detail: "Re-encrypts the complete private workspace under a new device-only Keychain key. Transactional recovery keeps interruption and cleanup states visible.")
                    DetailRow(label: "Rotation state", value: rotationStateLabel)
                    QuietButton(title: "Rotate the encryption key", symbol: "key") { Task { await model.rotateEncryptionKey() } }
                    if model.keyRotationStatus != .idle || model.pendingStorageCleanupCount > 0 {
                        DetailRow(label: "Pending storage cleanup tasks", value: model.pendingStorageCleanupCount.formatted())
                        QuietButton(title: "Retry storage cleanup", symbol: "arrow.clockwise") { Task { await model.retryStorageCleanup() } }
                    }
                    if model.credentialCleanupRequired {
                        Text("Saved endpoint credential removal needs attention.").foregroundStyle(FireStyle.gold)
                        QuietButton(title: "Retry credential removal", symbol: "key") { Task { await model.retryCredentialCleanup() } }
                    }
                }
            }
            NavigationLink { ReportHistoryView() } label: { Label("Delete individual saved reports", systemImage: "trash").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
        }.navigationTitle("Storage & retention").onAppear { reports = model.retention.maximumReports; mebibytes = model.retention.maximumStoredBytes / (1_024 * 1_024) }
        .confirmationDialog("Apply these retention limits?", isPresented: $showRetentionConfirmation, titleVisibility: .visible) {
            Button("Apply and remove older snapshots if needed", role: .destructive) { Task { await model.updateRetention(WorkspaceRetentionPolicy(maximumReports: reports, maximumStoredBytes: mebibytes * 1_024 * 1_024)) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Oldest imports and associated retained source copies beyond the new limits are permanently deleted. Originals in Files remain.") }
    }
    private var rotationStateLabel: String {
        switch model.keyRotationStatus {
        case .idle: "No rotation pending"
        case .staging: "Preparing the encrypted replacement"
        case .committing: "Committing the new encryption key"
        case .cleanupPending: "Previous key or storage cleanup needs retry"
        }
    }
}

struct ReminderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var weekday = 1
    @State private var time = Date()
    @State private var showConsent = false
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "A prompt to review, not monitoring", title: "Make a little time.", subtitle: "An optional weekly notification reminds you to review or import a report. It does not read new activity, upload reports or produce background surveillance.")
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Day", selection: $weekday) { ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in Text(name).tag(index + 1) } }.pickerStyle(.menu)
                    DatePicker("Local time", selection: $time, displayedComponents: .hourAndMinute)
                    PrimaryButton(title: "Review reminder consent", symbol: "bell") { showConsent = true }
                    Button("Revoke & remove all review reminders", role: .destructive) { Task { await model.revokeFeature(.localReminders) } }.frame(minHeight: 44)
                    Text("Apple’s notification permission and Focus settings determine delivery. A grant alone does not guarantee a notification will arrive.").font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }
        }.navigationTitle("Local reminders")
        .sheet(isPresented: $showConsent) {
            NavigationStack { FeatureConsentView(feature: .localReminders, scope: "weekly-local-reminder-v1", title: "Schedule a local weekly reminder?", paragraphs: ["The notification contains a generic privacy-review prompt, not app identifiers, domains, findings or report text. It is scheduled locally with Apple’s notification system.", "You may be asked for system notification permission. Delivery depends on system permissions and Focus settings. No new report is read or analyzed in the background.", "Declining leaves no reminder scheduled. Revoking this feature removes Fire Privacy’s scheduled reminders."]) {
                let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                await model.scheduleReminder(weekday: weekday, hour: components.hour ?? 9, minute: components.minute ?? 0)
            } }
        }
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Privacy policy · This app build", title: "Your report belongs to you.", subtitle: "Fire Privacy analyzes imported historical evidence on iPhone and iPad. Optional model, dataset and protection features are separately disclosed and controlled.")
            PolicySection(title: "Information you import", text: "App Privacy Reports can include bundle identifiers, domains, counts, sensor categories, event types, timestamps, context, reported owners and source provenance. Parsing is bounded and skipped records are quarantined from analysis. Original source bytes are discarded unless you explicitly grant encrypted source retention and choose it for that import. Your original in Files is never modified.")
            PolicySection(title: "Local analysis and storage", text: "Versioned rules, profiles, manual audits, local overrides, comparisons and weekly summaries run locally. History and private feature state are AES-GCM encrypted in protected, backup-excluded storage with device-only unlocked Keychain keys. There is no app-controlled cloud sync, user account, advertising SDK or telemetry. A fictional demo is clearly labeled and is not saved as an imported report.")
            PolicySection(title: "Supplied app-use comparisons", text: "Recollections, transcribed usage totals and imported windows or opened/closed logs are stored separately from privacy-report observations in the encrypted workspace. Their origin, device scope and completeness remain unverified. Comparisons require an explicit same-device claim bound to the selected report; timing outside supplied windows is context for review, not proof of misuse, background state or transmitted contents. Fire Privacy does not automatically read Screen Time, and usage references are not sent to an advisor. You can clear these references independently; Delete All removes the stored copy but cannot remove original files or external copies.")
            PolicySection(title: "Optional advisors", text: "Offline explanations make no model request. On eligible devices, separate consent enables Apple’s SystemLanguageModel on-device adapter; this build does not use Private Cloud Compute or an automatic external fallback. A separately configured self-hosted HTTPS endpoint receives only the exact bounded reference payload you preview and approve, excluding report text, bundle identifiers, domains, notes and timestamps. Its operator still receives connection metadata, model selection and any configured authentication. Its retention and model-training practices are outside this app’s control. All displayed conclusions remain grounded in deterministic findings.")
            PolicySection(title: "Updates and network inventory", text: "Knowledge, reviewed rule configuration and filter updates occur only after separate scoped consent and approval of an exact request preview. Knowledge and closed-schema rule configurations use the same update channel. The endpoint receives connection metadata; imported report payloads are not attached. Signed data must pass trusted-key, integrity, version, expiry and revocation checks. A bounded local ledger stores purpose, host, time, phase and byte counts, excluding paths, credentials, report identifiers, raw payloads and server messages. There is no silent polling.")
            PolicySection(title: "Optional protection", text: "Safari evaluates validated rules locally after system enablement; coverage is limited to matching Safari resources and may break features. Encrypted DNS sends query names to your disclosed resolver, which can read them; encryption does not itself establish tracking protection. Approved URL-filter and managed editions require their platform, entitlement, service and enrollment conditions. Consent is separate from system activation, and failures or incomplete removals remain visible. The app does not automatically change another app’s permissions.")
            PolicySection(title: "Sharing, links and providers", text: "Full or redacted JSON, CSV and Markdown exports are prepared locally and shared only to the destination you choose. Redaction removes selected fields but does not guarantee anonymity. Sanitized diagnostics exclude report contents and identifiers but include versions and aggregate counts. Protected temporary decrypted files are removed after sharing or at next launch. Files providers, browser links, system-controlled DNS or URL services and share destinations apply their own privacy and retention practices and are outside the app request ledger’s coverage.")
            PolicySection(title: "Retention, credentials and deletion", text: "Bounded retention removes oldest imports as needed. You can delete individual reports, revoke source retention, rotate encryption keys or delete all app data. Saved endpoint credentials require a separate deliberate choice and are stored in the device-only Keychain rather than ordinary preferences. Revocation cancels approved operations and attempts system removal; incomplete cleanup is shown and retryable. Delete All removes private workspace data, credentials, consent, temporary exports and keys. It does not delete originals in Files, external exports or data already received by advisor, resolver or other service operators. Contact those recipients under their own policies for their deletion options.")
            PolicySection(title: "Reminders and accuracy", text: "Optional local notifications contain a generic review prompt and require separate consent plus Apple notification permission. They do not monitor activity in the background. Historical contact counts are frequency, not data volume or proof of transmission or harm. Sensor records do not reveal current permissions. Classification describes documented business, not conduct. Incomplete knowledge remains unknown, and a finding absent from a later export is not assumed resolved.")
            PolicySection(title: "Sensitive information", text: "Reports and local notes can reveal sensitive habits. Avoid sharing them broadly or importing another person’s report without permission. The app does not request contact details, age, research participation or advertising identifiers.")
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Policy and support")
                    if let privacy = PublicLinks.privacy { Link("Public privacy policy", destination: privacy).foregroundStyle(FireStyle.ember).frame(minHeight: 44) }
                    if let support = PublicLinks.support {
                        Link("Contact the developer", destination: support).foregroundStyle(FireStyle.ember).frame(minHeight: 44)
                        Text("Public support issues should contain synthetic reproductions only, without private reports, identifiers or secrets. Report sensitive vulnerabilities through the repository’s private security-report route.").font(.footnote).foregroundStyle(FireStyle.muted)
                    }
                    else { Text("A functioning public support contact must be configured before release.").foregroundStyle(FireStyle.muted) }
                }
            }
        }.navigationTitle("Privacy policy").accessibilityIdentifier("privacy-policy-screen")
    }
}

private struct PolicySection: View {
    let title: String
    let text: String
    var body: some View { FireCard { VStack(alignment: .leading, spacing: 12) { SectionHeading(title: title); Text(text).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true) } } }
}
