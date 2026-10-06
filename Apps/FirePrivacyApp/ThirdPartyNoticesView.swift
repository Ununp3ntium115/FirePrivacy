import SwiftUI
import FirePrivacyCore

struct ThirdPartyNoticesView: View {
    @State private var notices: [BundledLegalNotice] = []
    @State private var failed = false
    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Bundled distribution notices", title: "Credit, preserved.", subtitle: "These third-party license texts are included in this app and are readable offline. Opening a public reference uses your browser; no reference is fetched automatically.")
            if failed {
                EmptyState(symbol: "exclamationmark.triangle", title: "Bundled notices could not be opened", message: "This build’s license resources need attention. A complete readable notice bundle is required for distribution.")
            }
            ForEach(notices) { notice in
                FireCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeading(title: notice.title, detail: notice.componentDescription)
                        DetailRow(label: "Bundled resource origin", value: notice.resourceOrigin)
                        if let source = referenceURL(notice.sourceReference) { Link("Public source reference", destination: source).foregroundStyle(FireStyle.ember).frame(minHeight: 44) }
                        if let license = referenceURL(notice.licenseReference) { Link("Public license reference", destination: license).foregroundStyle(FireStyle.ember).frame(minHeight: 44) }
                        Text(verbatim: notice.text).font(.system(.footnote, design: .monospaced)).foregroundStyle(FireStyle.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }.navigationTitle("Third-party notices").accessibilityIdentifier("third-party-notices-screen")
        .task {
            do { notices = try BundledLegalNotices.load() }
            catch { failed = true }
        }
    }
    private func referenceURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
