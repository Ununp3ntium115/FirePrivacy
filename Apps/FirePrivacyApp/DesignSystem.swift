import SwiftUI

enum FireStyle {
    static let ink = Color(red: 0.025, green: 0.055, blue: 0.085)
    static let surface = Color(red: 0.060, green: 0.105, blue: 0.150)
    static let teal = Color(red: 0.42, green: 0.91, blue: 0.82)
    static let orange = Color(red: 1.00, green: 0.64, blue: 0.42)
    static let text = Color(red: 0.96, green: 0.98, blue: 0.99)
    static let muted = Color(red: 0.69, green: 0.76, blue: 0.83)
}

struct FireBackdrop: View {
    var body: some View {
        LinearGradient(colors: [FireStyle.surface, FireStyle.ink, FireStyle.ink], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct FireCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FireStyle.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
    }
}

struct PageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow.uppercased())
                .font(.system(.caption, design: .rounded).weight(.bold))
                .tracking(2)
                .foregroundStyle(FireStyle.teal)
            Text(verbatim: title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(FireStyle.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: subtitle)
                .font(.body)
                .foregroundStyle(FireStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(FireStyle.text)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(FireStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SymbolBadge: View {
    let symbol: String
    var color: Color = FireStyle.teal
    var body: some View {
        Image(systemName: symbol)
            .font(.system(.title3).weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 48, height: 48)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(.headline, design: .rounded))
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .foregroundStyle(FireStyle.ink)
                .background(FireStyle.teal, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct QuietButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(.headline, design: .rounded))
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .foregroundStyle(FireStyle.text)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(label).foregroundStyle(FireStyle.muted)
                Spacer(minLength: 4)
                Text(verbatim: value).foregroundStyle(FireStyle.text).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).foregroundStyle(FireStyle.muted)
                Text(verbatim: value).foregroundStyle(FireStyle.text)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 14) {
                SymbolBadge(symbol: symbol)
                Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(FireStyle.text)
                Text(message).foregroundStyle(FireStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FirePage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 12)
        }
        .background(FireBackdrop())
    }
}
