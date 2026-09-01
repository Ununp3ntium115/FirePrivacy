import Foundation

/// An action Fire Privacy can offer.
///
/// Actions are a closed catalog with stable IDs. Findings reference them by ID,
/// the UI resolves them, and generated explanations may only cite IDs that exist
/// here — a model cannot invent a settings screen that iOS does not have
/// (AI-006, AI-007).
public struct Recommendation: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case reviewPermission
        case reviewApp
        case enableProtection
        case reviewDomain
        case learnMore
        case noAction
    }

    public let id: String
    public let title: String
    public let detail: String
    public let kind: Kind
    /// Minimum iOS version, when the action depends on one. `nil` means the
    /// action is just guidance and works everywhere.
    public let minimumOSVersion: Int?
    /// True for the "keep it as it is" option every recommendation set must
    /// offer (PER-004).
    public var isNoAction: Bool { kind == .noAction }

    public init(id: String, title: String, detail: String, kind: Kind, minimumOSVersion: Int? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.minimumOSVersion = minimumOSVersion
    }
}

public enum RecommendationCatalog {
    public static let reviewLocationPermission = Recommendation(
        id: "rec.review-location-permission",
        title: "Review this app's location access",
        detail: "Open Settings › Privacy & Security › Location Services and decide whether this app needs your position, and whether Precise Location is necessary. Fire Privacy cannot read or change the setting for you.",
        kind: .reviewPermission
    )

    public static let reviewSensorPermission = Recommendation(
        id: "rec.review-sensor-permission",
        title: "Review this app's access in Settings",
        detail: "Open Settings › Privacy & Security, choose the category, and decide whether this app still needs it. Fire Privacy cannot read or change another app's permissions.",
        kind: .reviewPermission
    )

    public static let reviewAppNecessity = Recommendation(
        id: "rec.review-app-necessity",
        title: "Decide whether you still want this app",
        detail: "If the app's purpose does not explain the data it reaches for, removing it is the only change that is fully under your control.",
        kind: .reviewApp
    )

    public static let reviewDomainDetail = Recommendation(
        id: "rec.review-domain-detail",
        title: "Look at what this domain is",
        detail: "Open the domain's detail screen to see its owner, category, the apps that contacted it, and the sources behind that classification.",
        kind: .reviewDomain
    )

    public static let enableStandardFilter = Recommendation(
        id: "rec.enable-standard-filter",
        title: "Turn on the Standard privacy filter",
        detail: "On iOS 26 and later, iOS can check requests against Fire Privacy's list of known tracking destinations without telling Fire Privacy which addresses you visited.",
        kind: .enableProtection,
        minimumOSVersion: 26
    )

    public static let enableSafariContentBlocker = Recommendation(
        id: "rec.enable-safari-blocker",
        title: "Turn on Safari content blocking",
        detail: "Safari can block known tracking resources on the web. This does not affect what apps do outside Safari.",
        kind: .enableProtection
    )

    public static let markDomainTrusted = Recommendation(
        id: "rec.mark-domain-trusted",
        title: "Mark this domain as expected on this device",
        detail: "If you know why this contact happens, record that here. The note stays on this device and lowers how prominently the domain is shown.",
        kind: .reviewDomain
    )

    public static let learnAboutCrossApp = Recommendation(
        id: "rec.learn-cross-app",
        title: "Learn what cross-app collection means",
        detail: "One company receiving activity from several unrelated apps can link those activities together. What is combined, and for how long, is not visible in the report.",
        kind: .learnMore
    )

    public static let learnAboutReportLimits = Recommendation(
        id: "rec.learn-report-limits",
        title: "Learn what this report can and cannot show",
        detail: "App Privacy Report records which domains an app contacted, not what was sent. Absence from the report is not proof that nothing was collected.",
        kind: .learnMore
    )

    public static let importFreshReport = Recommendation(
        id: "rec.import-fresh-report",
        title: "Export a newer App Privacy Report",
        detail: "The report you imported covers a past window. Exporting a new one from Settings › Privacy & Security › App Privacy Report shows what has happened since.",
        kind: .learnMore
    )

    public static let keepAsIs = Recommendation(
        id: "rec.keep-as-is",
        title: "Keep things as they are",
        detail: "This is a legitimate choice. Fire Privacy records that you reviewed it and stops raising it as a priority.",
        kind: .noAction
    )

    public static let all: [Recommendation] = [
        reviewLocationPermission,
        reviewSensorPermission,
        reviewAppNecessity,
        reviewDomainDetail,
        enableStandardFilter,
        enableSafariContentBlocker,
        markDomainTrusted,
        learnAboutCrossApp,
        learnAboutReportLimits,
        importFreshReport,
        keepAsIs,
    ]

    private static let byID: [String: Recommendation] = Dictionary(
        all.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    public static func recommendation(id: String) -> Recommendation? { byID[id] }

    public static func exists(id: String) -> Bool { byID[id] != nil }

    /// The actions available on this device, used to reject a suggested action
    /// the user cannot actually take (AI-007).
    public static func available(osMajorVersion: Int) -> [Recommendation] {
        all.filter { ($0.minimumOSVersion ?? 0) <= osMajorVersion }
    }
}
