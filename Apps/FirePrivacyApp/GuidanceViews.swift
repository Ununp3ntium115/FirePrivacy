import SwiftUI
import FirePrivacyCore

struct GuidanceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var includeHidden = false
    private var findings: [RuleFinding] {
        let values = model.engine.lifecycle?.current ?? model.analysis?.findings ?? []
        return includeHidden ? values : values.filter { $0.status != .ignored }
    }

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Evidence, with room for uncertainty", title: "Choose with clarity.", subtitle: "Versioned rules keep facts, interpretations and practical actions separate. Your profile changes relevance, never the recorded evidence.")
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    DetailRow(label: "Profile", value: model.preferences.profile.name)
                    if let analysis = model.analysis { DetailRow(label: "Ruleset", value: analysis.rulesetVersion) }
                    NavigationLink { PrivacyProfileView() } label: { Label("Choose your privacy priorities", systemImage: "slider.horizontal.3").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                    NavigationLink { AdvisorSettingsView() } label: { Label("Explanation advisor", systemImage: "text.bubble").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
                }
            }
            if let report = model.report, model.analysis != nil {
                SectionHeading(title: "From this snapshot", detail: "Review priority is not a threat verdict. Every finding includes its rule version, supporting records and limitations.")
                Toggle("Include findings hidden by me", isOn: $includeHidden).tint(FireStyle.ember)
                if findings.isEmpty {
                    EmptyState(symbol: "doc.text", title: "No visible findings", message: "Review hidden findings or the general settings below. The absence of findings does not establish that a device is protected.")
                }
                ForEach(findings) { finding in
                    NavigationLink { RuleFindingDetailView(finding: finding, report: report) } label: { RuleFindingRow(finding: finding) }.buttonStyle(.plain)
                }
                if let previous = model.engine.lifecycle?.previousOnly, !previous.isEmpty {
                    TextListCard(title: "Earlier findings", strings: previous.map { $0.title + " · " + $0.status.displayName } + ["Absence in this export does not establish that a finding is resolved or an app stopped acting."])
                }
            } else {
                EmptyState(symbol: "slider.horizontal.3", title: "Start with a useful setting", message: "General guidance works without a report. Import a report to connect recorded activity to versioned findings.")
            }
            SectionHeading(title: "Your settings toolkit", detail: "Choose a setting that fits how you use your device. Paths and available choices vary with iOS or iPadOS.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(SettingsGuide.all) { guide in
                    NavigationLink { SettingsGuideView(guide: guide) } label: {
                        FireCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SymbolBadge(symbol: guide.symbol)
                                Text(guide.title).font(.headline).foregroundStyle(FireStyle.text)
                                Text(guide.summary).font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                                Label("View steps", systemImage: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(FireStyle.ember)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            NavigationLink { ManualPermissionAuditView() } label: { Label("Record a manual permission review", systemImage: "checklist").foregroundStyle(FireStyle.ember).padding(.vertical, 12) }
        }.accessibilityIdentifier("guidance-screen")
    }
}

struct SettingsGuide: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let steps: [String]
    let tradeoff: String

    static let all: [SettingsGuide] = [
        .init(id: "location", title: "Location, on your terms", symbol: "location", summary: "Review which apps need your location and when they need it.", steps: ["Open Settings → Privacy & Security → Location Services.", "Choose an app and review the available access options. Select a narrower option if it still supports the feature you use.", "Review Precise Location for that app. If approximate location is enough, consider turning Precise Location off."], tradeoff: "Navigation, nearby services, safety features, and background location features may work differently when access is restricted. Fire Privacy does not know your current choices."),
        .init(id: "camera", title: "Camera & microphone", symbol: "mic", summary: "Give recording access to the features you actually use.", steps: ["Open Settings → Privacy & Security → Camera or Microphone.", "Review the listed apps and consider whether each app feature needs access.", "Change a switch yourself if you want to restrict access. Re-enable it later if a feature you need stops working."], tradeoff: "Video calls, voice messages, scanning, and recording may stop working without the relevant permission. Recorded begin/end events may describe a single access."),
        .init(id: "photos", title: "A smaller photo library", symbol: "photo.on.rectangle.angled", summary: "Consider sharing selected photos rather than your whole library.", steps: ["Open Settings → Privacy & Security → Photos.", "Choose an app and review its available photo access options.", "If the app and system offer limited or selected-photo access, choose only the photos needed for your task."], tradeoff: "Photo pickers and permission choices vary by app and system version. Restricting library access can affect backup, editing, and gallery features."),
        .init(id: "tracking", title: "Review tracking requests", symbol: "hand.raised", summary: "Review Apple’s permission for tracking across other companies’ apps and websites.", steps: ["Open Settings → Privacy & Security → Tracking.", "Review the apps shown and the Allow Apps to Request to Track setting.", "Choose whether apps may request tracking permission, and review any choices available for listed apps."], tradeoff: "Apple’s tracking permission does not block every domain contact or all first-party data collection. A report contact alone does not prove tracking."),
        .init(id: "report", title: "Keep a useful history", symbol: "doc.text.magnifyingglass", summary: "Return to Apple’s original report and compare activity over time.", steps: ["Open Settings → Privacy & Security → App Privacy Report.", "Review Apple’s network activity and data/sensor access entries.", "Export a fresh report after normal use if you want to review a more recent snapshot in Fire Privacy."], tradeoff: "The report begins recording after it is enabled and covers the period Apple makes available. Fire Privacy keeps imported snapshots within your retention limits and does not continuously monitor future activity.")
    ]
}

struct SettingsGuideView: View {
    let guide: SettingsGuide

    var body: some View {
        FirePage {
            PageHeader(eyebrow: "A choice you make", title: guide.title, subtitle: guide.summary)
            FireCard {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        InstructionStep(number: index + 1, title: index == 0 ? "Find the setting" : "Review your choice", detail: step)
                    }
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Consider the trade-off", systemImage: "scale.3d").font(.headline).foregroundStyle(FireStyle.gold)
                    Text(guide.tradeoff).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Fire Privacy provides guidance. You make changes in Apple Settings; this app does not silently adjust permissions or open another app’s settings page.")
                .font(.footnote).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle("Settings guide")
    }
}
