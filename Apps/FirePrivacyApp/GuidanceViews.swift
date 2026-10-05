import SwiftUI
import FirePrivacyCore

struct GuidanceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Small choices, made deliberately", title: "Make room for privacy.", subtitle: "Practical guidance you can follow in Apple Settings. Fire Privacy cannot read or change another app’s current permissions.")
            if let report = model.report {
                SectionHeading(title: "From your report", detail: "Descriptive observations with a direct evidence trail. They are not a diagnosis, threat score, or claim that an app did something wrong.")
                if report.findings.isEmpty {
                    EmptyState(symbol: "doc.text", title: "No guidance from these records", message: "You can still review the general settings below. The absence of findings does not establish that a device is protected.")
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(report.findings) { finding in
                            NavigationLink { FindingDetailView(finding: finding, report: report) } label: {
                                FireCard {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(alignment: .top, spacing: 12) {
                                            SymbolBadge(symbol: finding.id.hasPrefix("domain:") ? "globe" : "slider.horizontal.3")
                                            Text(verbatim: finding.title).font(.system(.headline, design: .rounded)).foregroundStyle(FireStyle.text).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right").foregroundStyle(FireStyle.muted).accessibilityHidden(true)
                                        }
                                        Text(verbatim: finding.detail).font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                                        Label("\(finding.evidenceIDs.count.formatted()) supporting records", systemImage: "doc.text.magnifyingglass")
                                            .font(.caption.weight(.medium)).foregroundStyle(FireStyle.ember)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                EmptyState(symbol: "slider.horizontal.3", title: "Start with a useful setting", message: "General guidance works without a report. Import a report when you want to connect recorded activity to specific app identifiers.")
            }
            SectionHeading(title: "Your settings toolkit", detail: "Choose a setting that fits how you use your device. Paths and available choices may vary with your iOS or iPadOS version.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(SettingsGuide.all) { guide in
                    NavigationLink { SettingsGuideView(guide: guide) } label: {
                        FireCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SymbolBadge(symbol: guide.symbol)
                                Text(guide.title).font(.system(.headline, design: .rounded)).foregroundStyle(FireStyle.text)
                                Text(guide.summary).font(.subheadline).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                                Label("View steps", systemImage: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(FireStyle.ember)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("guidance-screen")
    }
}

struct FindingDetailView: View {
    let finding: Finding
    let report: PrivacyReport

    private var evidence: [Observation] {
        let ids = Set(finding.evidenceIDs)
        return report.observations.filter { ids.contains($0.id) }
    }

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Evidence → Understanding → Choice", title: finding.title, subtitle: finding.detail)
            FireCard {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeading(title: "What you can do")
                    ForEach(Array(finding.recommendedSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)").font(.headline).foregroundStyle(FireStyle.ember).frame(width: 28).accessibilityHidden(true)
                            Text(verbatim: step).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            SectionHeading(title: "Supporting evidence", detail: "These are the imported records behind this observation. Report history does not establish current permissions or what data was sent.")
            LazyVStack(spacing: 12) {
                ForEach(evidence) { observation in ObservationCard(observation: observation) }
            }
        }
        .navigationTitle("Guidance details")
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
        .init(id: "report", title: "Keep a useful history", symbol: "doc.text.magnifyingglass", summary: "Return to Apple’s original report and compare activity over time.", steps: ["Open Settings → Privacy & Security → App Privacy Report.", "Review Apple’s network activity and data/sensor access entries.", "Export a fresh report after normal use if you want to review a more recent snapshot in Fire Privacy."], tradeoff: "The report begins recording after it is enabled and covers the period Apple makes available. Fire Privacy imports one report at a time and does not monitor future activity.")
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
