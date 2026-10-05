# Apple submission requirements and source status

Prepared October 5, 2026. This is a traceable submission plan, not a legal
opinion or a claim of Apple approval. The account holder supplies accurate legal,
tax, export, and business declarations in App Store Connect. Apple makes the
review decision.

## Official sources verified October 5, 2026

The official Apple sources below were successfully retrieved over HTTPS on
October 5, 2026 with ordinary certificate verification enabled. The retrieval
log is [APPLE-SOURCE-VERIFICATION.json](APPLE-SOURCE-VERIFICATION.json). Earlier
attempts failed with the cloud proxy's HTTP 403; retrieval succeeded after the
network configuration changed. TLS, certificate, or signature verification was
not disabled.

Apple's [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
states:

> Since April 28, 2026: Apps uploaded to App Store Connect must be built with
> Xcode 26 or later using an SDK for iOS 26, iPadOS 26, tvOS 26, visionOS 26,
> or watchOS 26.

> Since September 9, 2026: iOS and iPadOS apps uploaded to App Store Connect
> must target iOS 13 or later.

This project targets iOS/iPadOS 17, so its deployment target meets the second
requirement. Xcode 26+ with iOS/iPadOS 26+ SDK remains a separate build
requirement. The updated age-rating questionnaire is required since January 31,
2026. Confirm these sources and the real account's required fields again on
submission day; a source retrieval does not prove that the app passes review.

| Requirement | Official source | Action for this app |
| --- | --- | --- |
| Current submission SDK, Xcode, and deployment minimums | [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) | Xcode 26+ and iOS/iPadOS 26+ SDK are required since April 28, 2026; deployment target iOS 13+ is required since September 9, 2026. This app targets iOS/iPadOS 17. Recheck on submission day. |
| Complete build and honest metadata | [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.1 and 2.3 | Ship working import, browsing, export, and delete flows. Use screenshots of the actual build. Do not advertise VPN, filtering, AI, tracker detection, or unavailable protections. |
| Public APIs and useful native functionality | [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 2.5 and 4.2 | Use document import, SwiftUI, CryptoKit, Keychain, and the system share sheet. Verify the app has useful report exploration beyond a static page or website wrapper. |
| Data security, permission minimization, privacy policy | [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 1.6 and 5.1 | Provide a working privacy URL in App Store Connect and a visible policy in the app. Describe storage, deletion, and user-initiated sharing. Request access only to the selected file. No sensor or network-extension permission is needed. |
| Accurate App Privacy answers | [App privacy details](https://developer.apple.com/app-store/app-privacy-details/) | Proposed answer: **Data Not Collected**, only if the final binary and all bundled dependencies keep report data on-device. Review external support handling separately. |
| Required-reason APIs | [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) and [privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) | Apps using covered APIs without a declared approved reason have not been accepted since May 1, 2024. Audit the final app and dependencies. The current target uses no `UserDefaults`/`@AppStorage`, so no app-preference reason is declared. |
| Third-party SDK signatures and manifests | [Third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/) | This MVP should have no third-party app SDK. Recheck the dependency tree and Xcode privacy report if this changes. |
| Encryption declarations | [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/), [documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/), and [encryption declaration guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) | Apple's table says encryption limited to the Apple operating system requires no documentation in App Store Connect. This app uses CryptoKit AES-GCM and Keychain only; `ITSAppUsesNonExemptEncryption = false` represents that exemption, not an absence of encryption. The account holder confirms the actual questionnaire and any separate reporting/territory obligations. |
| Current age-rating questionnaire | [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) | Complete the current questionnaire against the app's actual behavior. A low age rating is a proposal, not a rating assigned by this repository. No chat, unrestricted web browsing, in-app purchases, gambling, or mature material is built in. |
| iPhone and iPad screenshots | [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) | Provide 1–10 JPEG/PNG images without transparency. iPhone: accepted 6.9-inch sizes, or 6.5-inch if 6.9-inch images are absent. iPad: 13-inch screenshots required. Exact dimensions are in `AppStore/SCREENSHOTS.md`. Use actual-build screens and synthetic data. |
| Accessibility declarations | [Accessibility nutrition labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/) | Apple's retrieved page says labels are currently voluntary and will become required later. Validate VoiceOver, 200%+ larger text, contrast, reduced motion, and iPad layout before declaring support; advertise only verified features. |
| EU Digital Services Act trader status | [EU trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/) | Trader status must be declared even without EU distribution. Traders distributing in the EU must verify the contact information Apple displays. Actual enrolled type determines address/contact requirements. Free pricing alone does not determine trader status. |
| Active membership and current agreements | [Apple Developer terms](https://developer.apple.com/support/terms/) | Verify active enrollment, accepted current agreements, seller identity, content rights, and availability choices in the real account. App Store Connect also determines whether banking/tax agreements are needed for the selected business model. |
| Customer license agreement | [Provide a custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/) | Apple's retrieved page says its standard EULA applies in all countries/regions when no custom EULA is provided. Use that default for this free MVP unless the verified rights holder requires custom terms; do not invent a company license. |
| Upload and submit in the correct service | [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) and [submit for review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/) | Build/sign in Xcode on a Mac, upload to **App Store Connect**, wait for processing, select that build, complete metadata, and submit for review. The developer portal is used for membership/certificates/profiles, not as the binary upload destination. |

## Local processing and the privacy label

Apple's verified privacy-details page defines collection as:

> “Collect” refers to transmitting data off the device in a way that allows
> you and/or your third-party partners to access it for a period longer than
> what is necessary to service the transmitted request in real time.

Merely importing an App Privacy Report does not mean the developer collects its
contents when processing and storage stay on-device. The final label still
depends on the final binary and every bundled dependency.

The proposed label relies on source and runtime evidence: no analytics,
advertising, third-party reporting SDK, web view, update endpoint, remote model,
or application network request in the shipping target. A system share sheet
lets the user choose a recipient; describe that clearly in the policy. A public
support issue is separate voluntary communication and may contain information
the person submits. Apple's optional-disclosure provision requires **all** its
listed conditions: no tracking/advertising/other-purpose use, infrequent and
optional collection outside the primary functionality, clear submission
information including the person's displayed account name, and affirmative
submission each time. Do not automatically exempt a new in-app support form.
Do not publish personal reports in support tickets.

## Required-reason API audit

The privacy manifest and source audit must agree with the actual app. No
`UserDefaults`/`@AppStorage` is used in the current target, so adding an app-only
preference reason would misdescribe this build. A file's contents and mere
existence are different from access to covered file-timestamp APIs. Audit
attributes, creation/modification dates, disk-space queries, system uptime, and
keyboard queries separately if any are introduced. The current app reads
`.fileSizeKey`/`.isRegularFileKey` and sets file-protection attributes; those are
not in Apple's retrieved FileTimestamp list. It does not call `stat`/`lstat` or
read creation/modification timestamps. Test-only protection assertions do not
ship in the app target.

The official [API-category reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
does explicitly list `stat`, `fstat`, `fstatat`, and `lstat` as covered even if a
caller is interested only in another file property. If those are added, use an
approved reason that matches the scope: `C617.1` for app-container metadata or
`3B52.1` for a file the user explicitly granted access to. Do not infer exemption
from not displaying a timestamp.

Do not fabricate a reason for a dependency. Xcode's generated privacy report,
archive validation, and App Store processing are required evidence; a static
source scan is an early check rather than proof of the final binary's behavior.

## Export classification

The app's implemented encryption should remain limited to Apple-provided
CryptoKit and Security APIs. AES-GCM protects stored reports; the key is
device-local and no app-to-server encryption protocol is implemented. Exporting
a readable JSON summary intentionally gives the recipient readable content.

Apple's verified documentation table says:

> Your app uses encryption limited to that within the Apple operating system:
> No documentation required in App Store Connect.

Before upload, compare this implementation with the actual export questionnaire
in App Store Connect. Record the exemption/classification and territories.
Apple's verified Security guidance says exempt encryption **might** still
require a year-end U.S. self-classification report. Its compliance overview also
identifies French controls on secure-storage applications. Determine the actual
seller's applicable reporting/import obligations rather than treating the plist
key as a legal determination. If a dependency introduces its own cryptography
or the app adds a remote protocol, redo the classification.

## Legal identity and rights

The repository's old text mentions a company. That does not establish the
enrolled seller's legal name, company ownership, trademark rights, or authority
to accept contracts. Use the verified identity in the Apple account for seller,
copyright, trader, tax, and review-contact fields. The team identifier supplied
for signing is `LYDVWU62G4`; it is an identifier, not a legal verification.

The public policy uses the product name **Fire Privacy** and does not invent a
company address or email. The GitHub API verifies that this repository is public
and its issue tracker is enabled; actual monitoring, policy hosting, and review
contact details still need to be established. App Review 5.6.2 requires
verifiable, current developer identity and contact information. Guideline
5.1.1(ix) also says apps requiring sensitive user information should be submitted
by a legal entity. Record the enrolled account type and evaluate that provision
for the optional local-report import flow; do not infer a company from old text.

Check rights to the final app name, icon, code, assets, and exported sample data.
The bundled demo is synthetic and must remain clearly labeled. No purchase or
subscription is proposed, so no payment flow or paywall is represented in the
submitted metadata.
