import SwiftUI

enum FireStyle {
    static let ink = Color(red: 16 / 255, green: 12 / 255, blue: 10 / 255)
    static let surface = Color(red: 35 / 255, green: 25 / 255, blue: 19 / 255)
    static let raised = Color(red: 48 / 255, green: 31 / 255, blue: 21 / 255)
    static let ember = Color(red: 1, green: 128 / 255, blue: 85 / 255)
    static let gold = Color(red: 1, green: 190 / 255, blue: 104 / 255)
    static let text = Color(red: 1, green: 246 / 255, blue: 235 / 255)
    static let muted = Color(red: 207 / 255, green: 191 / 255, blue: 177 / 255)
    static var flame: LinearGradient { LinearGradient(colors: [gold, ember], startPoint: .top, endPoint: .bottom) }
}

struct FireBackdrop: View {
    var body: some View {
        ZStack {
            FireStyle.ink
            LinearGradient(colors: [FireStyle.surface.opacity(0.75), FireStyle.ink], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [FireStyle.ember.opacity(0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [FireStyle.gold.opacity(0.045), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 440)
        }
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
            .background(LinearGradient(colors: [FireStyle.raised.opacity(0.84), FireStyle.surface.opacity(0.94)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(FireStyle.gold.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
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
                .foregroundStyle(FireStyle.ember)
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
    var color: Color = FireStyle.ember
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
                .background(LinearGradient(colors: [FireStyle.gold, FireStyle.ember], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: FireStyle.ember.opacity(0.15), radius: 14, y: 4)
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
                .background(FireStyle.gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(FireStyle.gold.opacity(0.13), lineWidth: 1))
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
