#if canImport(SwiftUI)
import SwiftUI
import FindingEngine
import ObservationCore

/// Severity shown as symbol + word + color, never color alone (§11.10).
public struct SeverityBadge: View {
    public let severity: Severity
    public let confidence: Double?

    public init(severity: Severity, confidence: Double? = nil) {
        self.severity = severity
        self.confidence = confidence
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: severity.symbolName)
                .imageScale(.small)
            Text(severity.displayName)
                .font(.caption.weight(.semibold))
            if let confidence {
                Text("· \(Int(confidence * 100))% confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "Severity \(severity.displayName)"
        if let confidence { text += ", confidence \(Int(confidence * 100)) percent" }
        return text
    }

    private var tint: Color {
        switch severity {
        case .info: .secondary
        case .low: .teal
        case .medium: .orange
        case .high: .red
        case .critical: .purple
        }
    }
}

/// One posture dimension, with its own text alternative (DASH-001, §11.10).
public struct DimensionCard: View {
    public let title: String
    public let value: Double
    public let higherIsBetter: Bool
    public let explanation: String

    public init(title: String, value: Double, higherIsBetter: Bool = false, explanation: String) {
        self.title = title
        self.value = value
        self.higherIsBetter = higherIsBetter
        self.explanation = explanation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(String(format: "%.0f", value))
                .font(.title2.weight(.bold))
                .monospacedDigit()
            ProgressView(value: min(1, max(0, value / 100)))
                .tint(.accentColor)
                .accessibilityHidden(true)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(Int(value)) out of 100. \(higherIsBetter ? "Higher is better." : "Higher means more exposure.")")
        .accessibilityHint(explanation)
    }
}

/// A labelled fact row used throughout the evidence screens.
public struct FactRow: View {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Shown whenever results come from the synthetic dataset (IMP-011).
public struct DemoDataBanner: View {
    public init() {}

    public var body: some View {
        Label(
            "Demo data — nothing here came from your device",
            systemImage: "theatermasks"
        )
        .font(.footnote.weight(.semibold))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The uncertainty block that appears under every finding (DET-003).
public struct UncertaintyList: View {
    public let items: [String]

    public init(items: [String]) {
        self.items = items
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("What this does not establish", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                ForEach(items, id: \.self) { item in
                    Text("• \(item)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
