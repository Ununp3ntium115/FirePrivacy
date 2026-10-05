import Foundation

extension PrivacyReport {
    /// Fictional apps and IANA-reserved example domains. No real user activity.
    public static var demo: PrivacyReport {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        return PrivacyReport(importedAt: date, observations: [
            Observation(bundleID: "example.weather", domain: "weather.example", category: .network, accessType: "networkActivity", count: 24, timestamp: date),
            Observation(bundleID: "example.weather", domain: "metrics.example", category: .network, accessType: "networkActivity", count: 8, timestamp: date),
            Observation(bundleID: "example.journal", domain: "sync.example", category: .network, accessType: "networkActivity", count: 12, timestamp: date),
            Observation(bundleID: "example.reader", domain: "metrics.example", category: .network, accessType: "networkActivity", count: 5, timestamp: date),
            Observation(bundleID: "example.weather", category: .sensor, accessType: "location", count: 1, timestamp: date, eventKind: "intervalBegin"),
            Observation(bundleID: "example.weather", category: .sensor, accessType: "location", count: 1, timestamp: date.addingTimeInterval(20), eventKind: "intervalEnd"),
            Observation(bundleID: "example.journal", category: .sensor, accessType: "camera", count: 1, timestamp: date, eventKind: "intervalBegin")
        ])
    }
}
