import SwiftUI

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

struct TrustCenterView: View {
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Trust is something you can inspect", title: "Private by design.\nClear by choice.", subtitle: "Your report is a sensitive record. Here is how this build handles it, without hidden switches or vague promises.")
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        SymbolBadge(symbol: "iphone.gen3")
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Analysis stays on this device").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                            Text("The app makes no network requests to import, analyze, or save a report. There are no accounts, advertising SDKs, telemetry, or AI services in this build.")
                                .foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.07))
                    TrustFact(symbol: "lock", title: "One encrypted report", detail: "Normalized observations are encrypted with AES-GCM in protected app storage. The encryption key is kept in the device-only Keychain and is available only while the device is unlocked. The saved report is excluded from iCloud/device backups.")
                    TrustFact(symbol: "doc", title: "No raw file retention", detail: "The selected file is read in memory. Your original stays in Files and is never modified. An iCloud or other Files provider may download that original under its own policies.")
                    TrustFact(symbol: "square.and.arrow.up", title: "Sharing is your decision", detail: "An export includes sensitive normalized report information. You choose its destination. A temporary decrypted export is protected and removed after the share sheet closes or at the next launch.")
                    TrustFact(symbol: "trash", title: "Delete with a visible result", detail: "Delete All removes saved app data, temporary exports, and the report encryption key. Errors are shown. Originals and copies already shared elsewhere remain outside the app’s control.")
                }
            }

            SectionHeading(title: "What the evidence means")
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    TrustFact(symbol: "globe", title: "Contact is not content", detail: "A contacted domain does not reveal payloads, prove personal information was sent, or establish harmful behavior. Counts show reported contact frequency, not data volume.")
                    TrustFact(symbol: "sensor", title: "History is not current permission", detail: "Sensor records describe exported events. Begin/end events can belong to the same access. This app cannot see another app’s current permission choices.")
                    TrustFact(symbol: "questionmark.circle", title: "Unknown stays unknown", detail: "App identifiers are not an installed-app inventory. Domain ownership, tracking classification, and risk scores are not provided in this build.")
                }
            }

            SectionHeading(title: "Available in this build")
            FireCard {
                VStack(spacing: 16) {
                    DetailRow(label: "Report import", value: "On device")
                    DetailRow(label: "Evidence & settings guides", value: "Available")
                    DetailRow(label: "Network / URL filtering", value: "Not included")
                    DetailRow(label: "VPN / live monitoring", value: "Not included")
                    DetailRow(label: "AI explanation", value: "Not included")
                    DetailRow(label: "Analytics & advertising", value: "None")
                }
            }

            NavigationLink { PrivacyPolicyView() } label: {
                Label("Read the privacy policy", systemImage: "doc.text")
                    .font(.headline).foregroundStyle(FireStyle.ember).padding(.vertical, 12)
            }
            .accessibilityIdentifier("privacy-policy-link")
            if let support = PublicLinks.support {
                Link(destination: support) {
                    Label("Support in your browser", systemImage: "arrow.up.right.square")
                        .font(.headline).foregroundStyle(FireStyle.ember).padding(.vertical, 12)
                }
                Text("Opening an external policy or support link uses your browser and the website’s privacy practices.")
                    .font(.footnote).foregroundStyle(FireStyle.muted)
            }
        }
        .accessibilityIdentifier("trust-screen")
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

    private var savedState: String {
        if model.savedReportUnavailable { return "Saved data could not be opened" }
        if model.hasSavedReport { return model.isDemo ? "Saved report retained; sample shown" : "One report on this device" }
        return model.isDemo ? "Sample only; no report saved" : "No report saved"
    }

    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Your data, your decisions", title: "Keep what you need.", subtitle: "Import a fresh report, share deliberately, or remove saved app data. No account or subscription is required.")
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: "Your report")
                    DetailRow(label: "Saved data", value: savedState)
                    DetailRow(label: "Storage", value: "Encrypted; excluded from backup")
                    PrimaryButton(title: "Import privacy report", symbol: "square.and.arrow.down") { model.requestImport() }
                    NavigationLink { ImportGuideView() } label: {
                        Label("How to export from Settings", systemImage: "questionmark.circle").foregroundStyle(FireStyle.ember).padding(.vertical, 8)
                    }
                    QuietButton(title: "Explore a sample", symbol: "sparkles") { model.showDemo() }
                    if model.hasSavedReport {
                        QuietButton(title: model.isDemo ? "Return to saved report" : "Reload saved report", symbol: "arrow.clockwise") { Task { await model.restoreSavedReport() } }
                    }
                }
            }

            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Export with care", detail: "Export the report currently displayed as normalized JSON. App identifiers, domains, event categories, and timestamps can be sensitive.")
                    if model.isDemo {
                        Text("You are viewing a fictional sample. Its export will be labeled as synthetic demo data.")
                            .font(.subheadline).foregroundStyle(FireStyle.gold)
                    }
                    QuietButton(title: "Export displayed report", symbol: "square.and.arrow.up") { showExportConfirmation = true }
                        .disabled(model.report == nil)
                        .opacity(model.report == nil ? 0.5 : 1)
                        .accessibilityIdentifier("export-report-button")
                    Text("After you choose a destination, that destination may transmit or retain the file. Fire Privacy cannot delete copies you share.")
                        .font(.footnote).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }

            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "A clean slate", detail: "Delete saved app data, temporary exports, and the report encryption key. This also clears a sample from the screen.")
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Label("Delete all Fire Privacy data", systemImage: "trash")
                            .font(.headline)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(FireStyle.gold)
                            .background(FireStyle.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("delete-all-button")
                    Text("Your original report in Files and any copies you have already shared are not deleted.")
                        .font(.footnote).foregroundStyle(FireStyle.muted)
                }
            }

            FireCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "About Fire Privacy")
                    DetailRow(label: "Version", value: appVersion)
                    DetailRow(label: "Report import limit", value: "16 MB")
                    NavigationLink { PrivacyPolicyView() } label: {
                        Label("Privacy policy", systemImage: "doc.text").foregroundStyle(FireStyle.ember).padding(.vertical, 8)
                    }
                    if let support = PublicLinks.support {
                        Link(destination: support) {
                            Label("Contact & support", systemImage: "arrow.up.right.square").foregroundStyle(FireStyle.ember).padding(.vertical, 8)
                        }
                    } else {
                        Text("A public support address has not been configured for this development build.").font(.footnote).foregroundStyle(FireStyle.muted)
                    }
                }
            }
        }
        .accessibilityIdentifier("settings-screen")
        .confirmationDialog("Share this report?", isPresented: $showExportConfirmation, titleVisibility: .visible) {
            Button("Prepare export & choose destination") { Task { await model.prepareExport() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The decrypted export contains app identifiers, contacted domains, sensor event categories, and timestamps. Your chosen destination may send it outside your device. Share only with people and services you trust.")
        }
        .confirmationDialog("Delete all Fire Privacy data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete all app data", role: .destructive) { Task { await model.deleteAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the saved report, temporary exports, and its encryption key. You cannot undo it. Your original in Files and copies already shared elsewhere remain.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return version + " (" + build + ")"
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Privacy policy · This app build", title: "Your report belongs to you.", subtitle: "Fire Privacy is a local report viewer and settings guide for iPhone and iPad. This policy describes the features present in this build.")
            PolicySection(title: "Information you choose to import", text: "When you select an App Privacy Report, the app reads its contents on your device. Recognized records can include app bundle identifiers, contacted domains, network contact counts, sensor categories, event types, and timestamps. Import notes record skipped lines and reasons. No raw copy of the selected file is retained by the app.")
            PolicySection(title: "Local processing and storage", text: "The app does not send imported report information to a developer server or an analytics, advertising, or AI service. It has no user accounts or advertising identifiers. One normalized report is saved in encrypted app storage using AES-GCM. The device-only Keychain key is available while the device is unlocked, and the saved report is protected and excluded from device backups. There is no app-controlled cloud sync.")
            PolicySection(title: "Files providers and external links", text: "The original file you select remains in its original Files location. If you use iCloud Drive or another provider, that provider may store or download the original under its own policies. Optional public policy and support links open in your browser. The website and browser apply their own privacy practices; report contents are not attached to those links by the app.")
            PolicySection(title: "Exporting and sharing", text: "Sharing is optional and initiated by you. The export contains the normalized report, including sensitive activity information, and indicates whether it is synthetic demo data. A protected temporary decrypted file is created for the system share sheet and removed when the sheet closes or at the next app launch. The destination you choose may transmit or retain the export. Fire Privacy cannot control or delete those external copies.")
            PolicySection(title: "Retention and deletion", text: "Your saved report remains until you replace it, use Delete All, or remove the app. Delete All removes saved app data, temporary exports, and the encryption key, with any failure shown to you. It does not delete the original in Files or copies shared elsewhere. Fictional demo data is shown in memory and is not saved as your imported report.")
            PolicySection(title: "Children and sensitive information", text: "The app does not request personal profiles, contact details, research participation, or age information. Report activity can reveal sensitive habits. Avoid sharing it broadly or importing another person’s report without their permission.")
            PolicySection(title: "Accuracy and your choices", text: "Reports are historical records, not proof of harmful behavior, personal data transmission, or current permission states. The app offers descriptive evidence and general settings steps. You decide whether to import, replace, export, or delete a report, and you make any permission changes yourself in Apple Settings.")
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Policy and support")
                    if let privacy = PublicLinks.privacy {
                        Link(destination: privacy) { Label("Public privacy policy", systemImage: "arrow.up.right.square").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                    }
                    if let support = PublicLinks.support {
                        Link(destination: support) { Label("Contact the developer", systemImage: "arrow.up.right.square").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                    } else {
                        Text("A developer contact has not yet been configured for this development build. A functioning public support contact is required before release.")
                            .foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle("Privacy policy")
        .accessibilityIdentifier("privacy-policy-screen")
    }
}

private struct PolicySection: View {
    let title: String
    let text: String

    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: title)
                Text(text).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
