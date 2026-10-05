import SwiftUI
import FirePrivacyCore

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FirePage {
            if let report = model.report {
                reportOverview(report)
            } else {
                welcome
            }
        }
        .accessibilityIdentifier("overview-screen")
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Image(systemName: "flame.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(FireStyle.orange)
                    .padding(24)
                    .background(FireStyle.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .accessibilityHidden(true)
                Spacer()
                Label("ON YOUR DEVICE", systemImage: "iphone.gen3")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .tracking(1)
                    .foregroundStyle(FireStyle.teal)
            }

            PageHeader(eyebrow: "Your personal privacy notebook", title: "A clearer picture.\nA quieter mind.", subtitle: "Turn your iPhone or iPad’s App Privacy Report into evidence you can understand, one app at a time.")

            FireCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 14) {
                        SymbolBadge(symbol: "doc.badge.arrow.up")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Start with your report").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                            Text("No account. No analytics. Analysis happens here.").foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    PrimaryButton(title: "Import privacy report", symbol: "square.and.arrow.down") { model.requestImport() }
                        .accessibilityIdentifier("import-report-button")
                    QuietButton(title: "Explore a sample", symbol: "sparkles") { model.showDemo() }
                    NavigationLink {
                        ImportGuideView()
                    } label: {
                        Label("How to export from Settings", systemImage: "questionmark.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FireStyle.teal)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("import-guide-button")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], alignment: .leading, spacing: 16) {
                PromiseCard(symbol: "doc.text.magnifyingglass", title: "Evidence, clearly", detail: "Explore domain contacts and recorded sensor events. See exactly what each observation supports.")
                PromiseCard(symbol: "hand.raised", title: "You stay in control", detail: "Follow practical steps in Apple Settings. Fire Privacy does not change another app’s permissions.")
                PromiseCard(symbol: "lock", title: "Local by design", detail: "Saved reports are encrypted on this device. Sharing happens only when you choose to export.")
            }
        }
    }

    @ViewBuilder
    private func reportOverview(_ report: PrivacyReport) -> some View {
        ReportStatusBanner()
        PageHeader(eyebrow: "Your privacy, in focus", title: "Follow the evidence.", subtitle: "A historical snapshot from your imported report. A contact tells you that a domain was contacted, not what data was sent.")

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], alignment: .leading, spacing: 14) {
            MetricCard(value: report.apps.count, title: "App identifiers", symbol: "app", color: FireStyle.teal)
            MetricCard(value: report.domains.count, title: "Domains", symbol: "globe", color: FireStyle.teal)
            MetricCard(value: report.totalContacts, title: "Reported contacts", symbol: "arrow.up.right", color: FireStyle.orange)
            MetricCard(value: report.observations.filter { $0.category == .sensor }.count, title: "Sensor event records", symbol: "sensor", color: FireStyle.orange)
        }

        FireCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    SymbolBadge(symbol: "checkmark.shield")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Understand first. Choose next.").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                        Text("Review recorded activity and consider the settings that fit your needs. This report does not establish harm or show current permission states.").foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                NavigationLink {
                    GuidanceView()
                } label: {
                    Label("Review your guidance", systemImage: "arrow.right")
                        .font(.headline)
                        .foregroundStyle(FireStyle.teal)
                        .padding(.vertical, 6)
                }
            }
        }

        SectionHeading(title: "Most reported contacts", detail: "Sorted by exported contact count. Counts are not data volume or a risk score.")
        if report.apps.isEmpty {
            EmptyState(symbol: "app", title: "No app identifiers found", message: "The imported records do not contain recognized app activity.")
        } else {
            FireCard {
                VStack(spacing: 0) {
                    ForEach(Array(report.apps.prefix(5).enumerated()), id: \.element.id) { index, app in
                        NavigationLink {
                            AppEvidenceView(app: app, report: report)
                        } label: {
                            AppSummaryRow(app: app)
                        }
                        .buttonStyle(.plain)
                        if index < min(report.apps.count, 5) - 1 { Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 12) }
                    }
                }
            }
        }

        FireCard {
            VStack(alignment: .leading, spacing: 14) {
                DetailRow(label: model.isDemo ? "Sample created" : "Imported", value: report.importedAt.formatted(date: .abbreviated, time: .shortened))
                DetailRow(label: "Recognized records", value: report.observations.count.formatted())
                DetailRow(label: "Skipped records", value: report.issues.count.formatted())
                Text("The report is limited to the activity and time span Apple exported. It is not a live monitor or an inventory of all installed apps.")
                    .font(.footnote).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }

        QuietButton(title: "Import another report", symbol: "square.and.arrow.down") { model.requestImport() }
    }
}

struct ReportStatusBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isDemo {
            VStack(alignment: .leading, spacing: 10) {
                Label("SAMPLE DATA · NOT YOUR DEVICE", systemImage: "sparkles")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(FireStyle.orange)
                    .accessibilityIdentifier("demo-report-badge")
                Text("These apps and domains are fictional. The sample is not saved as your report.")
                    .font(.subheadline).foregroundStyle(FireStyle.muted)
                if model.hasSavedReport {
                    Button("Return to saved report") { Task { await model.restoreSavedReport() } }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(FireStyle.teal)
                        .padding(.vertical, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FireStyle.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct PromiseCard: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 14) {
                SymbolBadge(symbol: symbol)
                Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(FireStyle.text)
                Text(detail).font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MetricCard: View {
    let value: Int
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
                Text(value.formatted()).font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                Text(title).font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct ImportGuideView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "A minute in Settings", title: "Bring your own report.", subtitle: "Apple controls what gets recorded. You decide what to share with Fire Privacy.")
            FireCard {
                VStack(alignment: .leading, spacing: 24) {
                    InstructionStep(number: 1, title: "Open Apple Settings", detail: "Go to Privacy & Security → App Privacy Report on your iPhone or iPad.")
                    InstructionStep(number: 2, title: "Let activity accumulate", detail: "Turn on App Privacy Report if needed, then use your apps. Apple records activity after the feature is enabled; a new report can be empty.")
                    InstructionStep(number: 3, title: "Export to Files", detail: "Open App Privacy Report, tap the share button, and save the exported report to Files. The exact controls may vary with your iOS or iPadOS version.")
                    InstructionStep(number: 4, title: "Choose the exported file", detail: "Return here and import the report. Fire Privacy reads newline-delimited JSON up to 16 MB, keeps recognized observations, and shows any skipped records.")
                }
            }
            PrimaryButton(title: "Choose report from Files", symbol: "folder") { model.requestImport() }
            FireCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your original file stays where it is", systemImage: "doc").font(.headline).foregroundStyle(FireStyle.text)
                    Text("Fire Privacy does not keep a raw copy or modify your original. One normalized report is saved in encrypted app storage. If your original is in iCloud Drive or another provider, that provider’s storage and download behavior applies.")
                        .foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("Import a report")
    }
}

struct InstructionStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number.formatted()).font(.system(.headline, design: .rounded)).foregroundStyle(FireStyle.teal)
                .frame(width: 34, height: 34).background(FireStyle.teal.opacity(0.12), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline).foregroundStyle(FireStyle.text)
                Text(detail).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
