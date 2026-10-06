import Foundation

public enum ActionKind: String, Codable, Equatable, Sendable {
    case manualSettings, education, appControl, keepAsIs
}

/// A closed catalog: analysis and advisors may reference these actions, never invent settings.
public struct CatalogAction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let steps: [String]
    public let tradeoffs: [String]
    public let kind: ActionKind
    public let prerequisites: [String]

    public init(id: String, title: String, detail: String, steps: [String] = [],
                tradeoffs: [String] = [], kind: ActionKind, prerequisites: [String] = []) {
        self.id = id; self.title = title; self.detail = detail; self.steps = steps
        self.tradeoffs = tradeoffs; self.kind = kind; self.prerequisites = prerequisites
    }
}

public enum ActionCatalog {
    public static let version = "actions-1.0.0"
    public static let reviewLocation = CatalogAction(
        id: "rec.review-location-permission", title: "Review location access",
        detail: "Only Settings can show or change another app's current location permission.",
        steps: ["Open Settings > Privacy & Security > Location Services.",
                "Choose the app. Review its access level and Precise Location option if available."],
        tradeoffs: ["Reducing location access can affect navigation, reminders, weather, or other location features."],
        kind: .manualSettings)
    public static let reviewSensor = CatalogAction(
        id: "rec.review-sensor-permission", title: "Review access in Settings",
        detail: "Recorded access describes the report window; it does not show current permission settings.",
        steps: ["Open Settings > Privacy & Security.", "Choose the relevant category and review the app."],
        tradeoffs: ["Removing access may stop a feature that depends on it. Available choices vary by category and iOS version."],
        kind: .manualSettings)
    public static let reviewApp = CatalogAction(
        id: "rec.review-app-necessity", title: "Review why you use this app",
        detail: "Compare the app's features and privacy policy with the recorded activity.",
        steps: ["Consider which features you use and whether their access makes sense.",
                "Choose whether to keep the app, adjust permissions in Settings, or remove it yourself."],
        tradeoffs: ["Removing an app can remove local data and access to its features. It does not delete data previously held by its provider."],
        kind: .education)
    public static let reviewDomain = CatalogAction(
        id: "rec.review-domain-detail", title: "Review this destination",
        detail: "Inspect the contributing records and any reviewed sources for the destination.",
        tradeoffs: ["A domain contact does not show request contents, purpose, or harm. Unknown ownership means unknown."],
        kind: .education)
    public static let learnCrossApp = CatalogAction(
        id: "rec.learn-cross-app", title: "Understand shared destinations",
        detail: "Several apps can contact the same service for ordinary infrastructure or other reasons. Shared contacts alone do not prove that their activity was linked.",
        kind: .education)
    public static let learnLimits = CatalogAction(
        id: "rec.learn-report-limits", title: "Understand report limits",
        detail: "The export records contacts and sensor events, not transmitted payloads, current permission state, or complete activity from every networking implementation.",
        kind: .education)
    public static let importFresh = CatalogAction(
        id: "rec.import-fresh-report", title: "Import a newer report",
        detail: "A new export provides a later observation window; it is not continuous monitoring.",
        steps: ["Open Settings > Privacy & Security > App Privacy Report.", "Export a report and import that file into Fire Privacy."],
        kind: .manualSettings)
    public static let enableURLFilter = CatalogAction(
        id: "rec.enable-standard-filter", title: "Review URL filtering",
        detail: "When this build has a working URL filter, the system can check supported URL requests against its list.",
        tradeoffs: ["Coverage is limited to supported networking. Blocking can break features; you can disable the filter."],
        kind: .appControl, prerequisites: ["iOS or iPadOS 26 or later", "Working entitlement, approved service configuration, and verified filter dataset"])
    public static let enableSafari = CatalogAction(
        id: "rec.enable-safari-blocker", title: "Review Safari content blocking",
        detail: "A Safari content blocker can block matching browser resources after you enable the installed extension in Settings.",
        tradeoffs: ["Safari rules do not control other apps' networking and may affect website features."],
        kind: .appControl, prerequisites: ["Installed Safari content blocker with validated rules"])
    public static let markExpected = CatalogAction(
        id: "rec.mark-domain-trusted", title: "Record this contact as expected",
        detail: "A local note changes review priority; it does not change the imported evidence or establish that a destination is safe.",
        kind: .appControl)
    public static let keepAsIs = CatalogAction(
        id: "rec.keep-as-is", title: "Keep things as they are",
        detail: "You can review the evidence and choose to make no change.", kind: .keepAsIs)

    public static let all: [CatalogAction] = [reviewLocation, reviewSensor, reviewApp, reviewDomain,
        learnCrossApp, learnLimits, importFresh, enableURLFilter, enableSafari, markExpected, keepAsIs]

    public static func action(id: String) -> CatalogAction? { all.first { $0.id == id } }
    public static func contains(_ id: String) -> Bool { action(id: id) != nil }
}
