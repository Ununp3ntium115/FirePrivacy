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
                    .foregroundStyle(FireStyle.flame)
                    .shadow(color: FireStyle.ember.opacity(0.22), radius: 22)
                    .padding(24)
                    .background(FireStyle.gold.opacity(0.09), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .accessibilityHidden(true)
                Spacer()
                Label("ON YOUR DEVICE", systemImage: "iphone.gen3")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .tracking(1)
                    .foregroundStyle(FireStyle.ember)
            }

            PageHeader(eyebrow: "Your personal privacy notebook", title: "Your privacy. In focus.", subtitle: "Explore recorded activity. Choose with clarity. Bring an App Privacy Report from Apple Settings to get started.")

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
                            .foregroundStyle(FireStyle.ember)
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
        let apps = report.apps
        let domains = report.domains
        ReportStatusBanner()
        Image(systemName: "flame.fill")
            .font(.system(size: 46, weight: .medium))
            .foregroundStyle(FireStyle.flame)
            .shadow(color: FireStyle.ember.opacity(0.22), radius: 20)
            .accessibilityHidden(true)
        PageHeader(eyebrow: "A historical snapshot", title: "Your privacy. In focus.", subtitle: "Explore recorded activity. Choose with clarity.")

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], alignment: .leading, spacing: 14) {
            MetricCard(value: apps.count, title: "App identifiers", symbol: "app", color: FireStyle.ember)
            MetricCard(value: domains.count, title: "Domains", symbol: "globe", color: FireStyle.ember)
            MetricCard(value: report.totalContacts, title: "Reported contacts", symbol: "arrow.up.right", color: FireStyle.gold)
            MetricCard(value: report.observations.filter { $0.category == .sensor }.count, title: "Sensor event records", symbol: "sensor", color: FireStyle.gold)
        }

        if apps.isEmpty {
            EmptyState(symbol: "app", title: "No app identifiers found", message: "The imported records do not contain recognized app activity.")
        } else {
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: "Recorded activity", detail: "Reported contact count · most contacts first")
                    ForEach(Array(apps.prefix(5).enumerated()), id: \.element.id) { index, app in
                        NavigationLink {
                            AppEvidenceView(app: app, report: report)
                        } label: {
                            ContactActivityRow(app: app, maximumContacts: apps.first?.contacts ?? 0)
                        }
                        .buttonStyle(.plain)
                        if index < min(apps.count, 5) - 1 { Divider().overlay(FireStyle.gold.opacity(0.07)) }
                    }
                    Text("Bars compare exported contact counts with the highest count in this report. They are not a risk score or data volume.")
                        .font(.caption).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        FireCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    SymbolBadge(symbol: "book")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Review your guidance").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                        Text("Understand what the report shows, and consider settings that fit your needs.").foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                NavigationLink { GuidanceView() } label: {
                    Label("View guidance", systemImage: "arrow.right")
                        .font(.system(.headline, design: .rounded))
                        .padding(.vertical, 15)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(FireStyle.ink)
                        .background(LinearGradient(colors: [FireStyle.gold, FireStyle.ember], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }

        VStack(spacing: 12) {
            Label("Analyzed on this device", systemImage: "lock.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(FireStyle.text)
                .padding(14).frame(maxWidth: .infinity)
                .background(FireStyle.gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FireStyle.gold.opacity(0.12), lineWidth: 1))
            Label("Contacts do not reveal what data was sent.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(FireStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
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
            VStack(alignment: .leading, spacing: 8) {
                Label("SAMPLE DATA · NOT YOUR DEVICE", systemImage: "sparkles")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(FireStyle.gold)
                    .accessibilityIdentifier("demo-report-badge")
                Text("Fictional apps and domains. This sample is not saved as your report.")
                    .font(.caption).foregroundStyle(FireStyle.muted)
                if model.hasSavedReport {
                    Button("Return to saved report") { Task { await model.restoreSavedReport() } }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(FireStyle.ember)
                        .padding(.vertical, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FireStyle.gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FireStyle.gold.opacity(0.19), lineWidth: 1))
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 30).accessibilityHidden(true)
                    metricText
                }
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(color).accessibilityHidden(true)
                    metricText
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var metricText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
            Text(title).font(.caption).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ContactActivityRow: View {
    let app: AppSummary
    let maximumContacts: Int

    private var fraction: CGFloat {
        guard maximumContacts > 0 else { return 0 }
        return CGFloat(min(1, max(0, Double(app.contacts) / Double(maximumContacts))))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SymbolBadge(symbol: "app")
            VStack(alignment: .leading, spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: app.bundleID).font(.subheadline.weight(.medium)).foregroundStyle(FireStyle.text)
                        Spacer(minLength: 0)
                        Text(app.contacts.formatted()).font(.headline).foregroundStyle(FireStyle.text)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: app.bundleID).font(.subheadline.weight(.medium)).foregroundStyle(FireStyle.text)
                        Text("\(app.contacts.formatted()) reported contacts").font(.caption).foregroundStyle(FireStyle.muted)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FireStyle.gold.opacity(0.09))
                        Capsule().fill(FireStyle.flame).frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(FireStyle.muted).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
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
            Text(number.formatted()).font(.system(.headline, design: .rounded)).foregroundStyle(FireStyle.ember)
                .frame(width: 34, height: 34).background(FireStyle.ember.opacity(0.12), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline).foregroundStyle(FireStyle.text)
                Text(detail).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
