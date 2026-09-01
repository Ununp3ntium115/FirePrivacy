import SwiftUI
import FirePrivacyUI
import ObservationStore
import ConsentKit
import AdvisorKit
import ProtectionKit
import KnowledgeBaseKit

/// The iPhone app.
///
/// Everything the app can do is assembled here, so the dependency graph is
/// readable in one place: which advisor is registered, which filter bridge is
/// used, and where local data lives.
@main
struct FirePrivacyApp: App {
    @State private var model: AppModel?
    @State private var startupFailure: String?

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
            } else if let startupFailure {
                SafeModeView(message: startupFailure)
            } else {
                ProgressView("Preparing…")
                    .task {
                        do {
                            model = try await Self.makeModel()
                        } catch {
                            startupFailure = "Fire Privacy could not open its local database. Nothing has been lost — reinstalling or freeing storage usually resolves this."
                        }
                    }
            }
        }
    }

    @MainActor
    private static func makeModel() async throws -> AppModel {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

        let directory = URL.applicationSupportDirectory.appending(path: "FirePrivacy", directoryHint: .isDirectory)
        let keyProvider = KeychainDataKeyProvider(service: "com.firesoftwaresolutions.fireprivacy.datakey")
        // A store that cannot be created means no analysis can be stored. Safe
        // mode uses a temporary directory so the app still opens and the Trust
        // Center still works (§18.3).
        let store: EncryptedObservationStore
        if let primary = try? EncryptedObservationStore(directory: directory, keyProvider: keyProvider) {
            store = primary
        } else {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("FirePrivacySafeMode", isDirectory: true)
            store = try EncryptedObservationStore(directory: fallback, keyProvider: keyProvider)
        }

        let advisor = AdvisorCoordinator(osVersion: osVersion, appVersion: appVersion)
        await advisor.register(TemplatePrivacyAdvisor())
        await advisor.register(BridgedModelAdvisor(bridge: FoundationModelsBridge()))

        let filter = URLFilterController(
            bridge: SystemURLFilterBridge(),
            makeConfiguration: { profile in
                URLFilterConfiguration(
                    profile: profile,
                    pirServerURL: FilterEndpoints.privateLookup,
                    privacyPassIssuerURL: FilterEndpoints.privacyPassIssuer,
                    controlProviderBundleIdentifier: "com.firesoftwaresolutions.fireprivacy.urlfilter"
                )
            }
        )

        return AppModel(
            knowledgeBase: KnowledgeBaseService(appVersion: appVersion),
            store: store,
            consent: ConsentStore(appVersion: appVersion, osVersion: osVersion),
            advisor: advisor,
            urlFilter: filter,
            appVersion: appVersion,
            osVersion: osVersion,
            osMajorVersion: osMajor
        )
    }
}


/// Shown when local storage cannot be opened, so the app still launches and the
/// user can reach an explanation rather than a crash (§18.3).
struct SafeModeView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Fire Privacy is in safe mode", systemImage: "exclamationmark.shield")
        } description: {
            Text(message)
        }
    }
}

/// Placeholders until the URL filter capability is granted (Gate 0/Gate 3).
///
/// They are read only when the entitlement is present, which it is not in this
/// build, so the app makes no request to them.
enum FilterEndpoints {
    static let privateLookup = URL(string: "https://filter.fireprivacy.example/pir")
        ?? URL(fileURLWithPath: "/dev/null")
    static let privacyPassIssuer = URL(string: "https://filter.fireprivacy.example/issuer")
        ?? URL(fileURLWithPath: "/dev/null")
}
