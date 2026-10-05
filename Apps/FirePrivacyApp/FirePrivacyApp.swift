import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct FirePrivacyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            FirePrivacyRootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(FireStyle.ember)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case evidence = "Evidence"
    case guidance = "Guidance"
    case trust = "Trust"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .evidence: "doc.text.magnifyingglass"
        case .guidance: "slider.horizontal.3"
        case .trust: "checkmark.shield"
        case .settings: "gearshape"
        }
    }
}

private struct SidebarNavigationIdentity: Hashable, Sendable {
    let section: AppSection
    let reportID: UUID?
}

struct FirePrivacyRootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: AppSection = .overview
    @State private var selectedSidebar: AppSection? = .overview
    @State private var presentedExportURL: URL?

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    sidebar
                        .navigationTitle("Fire Privacy")
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 310)
                } detail: {
                    NavigationStack { sectionView(selectedSidebar ?? .overview) }
                        .id(SidebarNavigationIdentity(section: selectedSidebar ?? .overview, reportID: model.report?.id))
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(AppSection.allCases) { section in
                        NavigationStack { sectionView(section) }
                            .id(model.report?.id)
                            .tabItem { Label(section.rawValue, systemImage: section.symbol).accessibilityIdentifier(section.rawValue.lowercased() + "-tab") }
                            .tag(section)
                    }
                }
            }
        }
        .disabled(model.isWorking)
        .overlay {
            if model.isWorking {
                ZStack {
                    FireStyle.ink.opacity(0.72).ignoresSafeArea()
                    VStack(spacing: 16) {
                        if reduceMotion {
                            Image(systemName: "hourglass").font(.largeTitle).foregroundStyle(FireStyle.ember).accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.large).tint(FireStyle.ember)
                        }
                        Text(model.workingMessage).font(.headline).foregroundStyle(FireStyle.text)
                    }
                    .padding(32)
                    .background(FireStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                    .padding(24)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .overlay {
            if scenePhase != .active {
                ZStack {
                    FireStyle.ink.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(FireStyle.ember)
                        Text("Fire Privacy").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .task { await model.load() }
        .onOpenURL { model.openDocument($0) }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.json, .plainText, .data], allowsMultipleSelection: false) { result in
            Task { await model.handleImport(result) }
        }
        .confirmationDialog("Replace your saved report?", isPresented: $model.showReplaceConfirmation, titleVisibility: .visible) {
            Button("Import replacement report") { model.confirmImport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("One report is saved at a time. Your existing report is replaced only after the new report is read and saved successfully.")
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(verbatim: notice.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $model.sharedReport, onDismiss: {
            if let url = presentedExportURL {
                presentedExportURL = nil
                Task { await model.removeExport(url) }
            }
        }) { item in
            ReportShareSheet(url: item.url) {
                model.sharedReport = nil
            }
            .onAppear { presentedExportURL = item.url }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSidebar) {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(FireStyle.flame)
                        .shadow(color: FireStyle.ember.opacity(0.25), radius: 14)
                        .accessibilityHidden(true)
                    Text("Clarity, on\nyour device.")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(FireStyle.text)
                }
                .padding(.vertical, 20)
            }
            .listRowBackground(Color.clear)
            Section {
                ForEach(AppSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .padding(.vertical, 8)
                        .tag(section)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(section.rawValue)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier(section.rawValue.lowercased() + "-tab")
                        .foregroundStyle(selectedSidebar == section ? FireStyle.text : FireStyle.muted)
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: selectedSidebar == section ? [FireStyle.ember.opacity(0.34), FireStyle.gold.opacity(0.12)] : [.clear, .clear], startPoint: .leading, endPoint: .trailing))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(FireStyle.ember.opacity(selectedSidebar == section ? 0.45 : 0), lineWidth: 1))
                        )
                }
            }
            Section {
                Label("Local analysis", systemImage: "iphone.gen3")
                    .font(.footnote)
                    .foregroundStyle(FireStyle.muted)
                    .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(FireBackdrop())
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        Group {
            switch section {
            case .overview: OverviewView()
            case .evidence: EvidenceView()
            case .guidance: GuidanceView()
            case .trust: TrustCenterView()
            case .settings: AppSettingsView()
            }
        }
        .toolbarBackground(FireStyle.ink, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: "flame.fill").foregroundStyle(FireStyle.flame).accessibilityHidden(true)
                    Text("Fire Privacy").font(.system(.headline, design: .rounded)).foregroundStyle(FireStyle.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct ReportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: @MainActor @Sendable () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onComplete() }
        }
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        // SwiftUI presents the controller as a sheet on both iPhone and iPad.
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
