import Foundation
import UniformTypeIdentifiers

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // An invalid, stale, revoked or absent artifact produces no blocking rules.
        // Safari never supplies browsing history or visited URLs to this handler.
        let data = (try? ProtectionArtifactStore().validatedSafari().1) ?? Data("[]".utf8)
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)
        let item = NSExtensionItem()
        item.attachments = [provider]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
