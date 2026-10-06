# Apple submission requirements and evidence

Prepared October 5, 2026 for the expanded source. Official documentation was
retrieved using ordinary TLS/certificate verification; account declarations,
entitlement grants, service approval, signing, review and release are separate
external facts. This file does not certify legal compliance or Apple acceptance.
The account holder supplies accurate legal/business/export answers.

Evidence: [base source log](APPLE-SOURCE-VERIFICATION.json) and
[optional-feature source log](APPLE-OPTIONAL-SOURCE-VERIFICATION.json).
No certificate, signature or checksum verification was disabled.

## Current build and submission rules

Apple's [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
states that uploads require **Xcode 26+ with an iOS/iPadOS 26+ SDK since
April 28, 2026**, and **iOS/iPadOS deployment target 13+ since September 9, 2026**.
The consumer/managed app targets 17; URL-filter targets 26. Hosted tooling pins
Xcode 26.2. Source settings do not establish a successful build. Recheck the
current minima and actual account fields on submission day.

The updated age-rating questionnaire is required since January 31, 2026. Use the
actual current questionnaire rather than a repository-assigned rating.

| Requirement | Official source | Application |
| --- | --- | --- |
| Complete working app and honest metadata | [App Review 2.1/2.3](https://developer.apple.com/app-store/review/guidelines/) | Complete native controls/tests first. Advertise only the working submitted edition; source or an inactive bridge is not proof of availability. Use actual screens and synthetic data. |
| Public APIs and useful native behavior | [App Review 2.5/4.2](https://developer.apple.com/app-store/review/guidelines/) | Document import, evidence/history/export/delete and optional public platform APIs must work. No private APIs or arbitrary executable dataset updates. |
| Security and privacy | [App Review 1.6/5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy) | Easily accessible live policy in-app and ASC; accurate data purposes/retention/deletion, minimal permissions, independent optional consent and withdrawal. |
| Transmission and AI sharing | [App Review 5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing) | Clearly disclose where data is sent, including third-party AI, and obtain explicit permission first. User-configured/self-hosted is not a blanket permission exemption. |
| Collection/retention and App Privacy | [Privacy details](https://developer.apple.com/app-store/app-privacy-details/) | Review every optional operator/endpoint and dependency. On-device processing alone is not collection; transmitted derived data must be assessed separately. Do not copy the old unconditional Data Not Collected draft. |
| Required-reason APIs/manifests | [Required reasons](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) / [manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) | Every shipped app/extension manifest must match actual covered APIs. Covered undeclared APIs have been rejected since May 1, 2024. Review Xcode's generated privacy report and processing. |
| Third-party software | [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/) | Check the final native dependency graph against Apple's listed SDK requirements and license rights, including bundled PSL and Apple sample notices. Linux SwiftCrypto is not evidence that a native binary uses custom crypto. |
| Encryption | [Export overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) / [table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/) | Review actual native CryptoKit/Security/TLS/NetworkExtension use per edition. Apple's OS-only provision requires no ASC documentation; false plist value means exempt, not no encryption. Owner verifies questionnaires/reporting/territories. |
| Age rating | [Current definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) | Answer for real optional model/protection functions and content; no guessed rating. Model input/output is constrained; there is no chat or unrestricted model prose in this implementation. |
| Screenshots | [Specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) | 1–10 nontransparent JPEG/PNG. Accepted 6.9-inch iPhone sizes or 6.5-inch fallback; 13-inch iPad required. See AppStore/SCREENSHOTS.md. Capture is paused until functionality/native checks complete. |
| Accessibility | [Nutrition labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/) | Retrieved guidance describes labels as voluntary pending a later requirement. Verify VoiceOver, 200%+ text, contrast, reduced motion and layout before declaring support. |
| EU trader | [DSA requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/) | Declare trader status even without EU distribution. EU traders verify displayed contact details. Free price alone does not determine status. |
| Membership, legal identity/rights | [Terms](https://developer.apple.com/support/terms/) / App Review 5.2/5.6 | Active membership/current agreements/roles, real seller/contact, content/code/icon/dataset rights and territories. Team LYDVWU62G4 identifies a team, not a verified legal entity. |
| License | [EULA](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/) | Apple's standard EULA applies when no custom one is provided; use actual rights-holder terms if choosing a custom agreement. |
| Upload/review | [Upload](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) / [submit](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/) | Signed archive→App Store Connect→processing→TestFlight/physical QA→complete metadata→Add for Review→Submit for Review. Upload alone is not review submission or publication. |

## Collection, consent and the actual privacy label

Apple defines collection as transmitting off device in a way that lets the
developer/partners access data longer than servicing the request in real time.
On-device-only processing is not collection. Apple's FAQ says immediately
discarded authentication/IP/request data need not be declared under this label
rule; retained data must be classified by actual use.

Consumer networking is optional: dataset GETs have no report body but expose
connection metadata; self-hosted requests transmit minimized user-derived
rule/action/count/confidence information; DNS sends queried names to the chosen
resolver. Actual operator access/logging/retention and partner relationships
control App Privacy answers. Avoid both assuming all traffic is label collection
and assuming optional/self-hosted traffic is exempt. A digest or ordinal reference
is not an anonymity guarantee.

The optional-disclosure exception requires all listed conditions, including
infrequent/non-primary optional collection, clear submission with displayed
user/account identity and affirmative submission each time. An optional advisor
or DNS toggle alone does not meet it. Review any built-in provider's practices
and equal-protection obligations under 5.1.1(i). A generic user-owned endpoint's
hosting/operator practices cannot be guaranteed by TLS or a privacy claim.

The app has no advertising/cross-app-ad attribution purpose; report analysis is
not itself ATT tracking. Add an ATT flow only if actual tracking as Apple defines
it is introduced. No account is created, so an account-deletion flow is not
required merely because optional networking exists.

## Platform and edition conditions

| Feature | Verified official source | Concrete gate/disclosure |
| --- | --- | --- |
| Apple on-device advisor | [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) / [usage](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) | iOS/iPadOS 26+, eligible device/region, Apple Intelligence enabled and model assets ready. Keep explicit SystemLanguageModel local path and fallback. The whole current framework also has newer server providers; do not describe all framework use as offline. |
| Model use/safety | [Acceptable-use terms](https://developer.apple.com/support/terms/acceptable-use-requirements-for-the-foundation-models-framework) / [safety](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output) | Prohibited privacy violations/unauthorized access/safety circumvention/high-risk unsupervised decisions apply. Apple advises keeping untrusted input out of instructions. Guided generation guarantees structure, not truth; closed output/reference validation is an app guardrail. |
| Self-hosted HTTPS | [ATS](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity) / [local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | No production HTTP/trust bypass. Local-LAN connections need truthful NSLocalNetworkUsageDescription and OS permission; declare Bonjour types only if actually browsing/advertising. Exact payload/destination consent before sending. |
| Safari blocker | [Creating a blocker](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker) | Containing app+extension/AppGroup/profiles, user Settings enablement and actual SFContentBlockerManager state. Safari rules receive no visit history. No universal coverage or autonomous cache expiry claim. Safari alone does not impose VPN organization enrollment. |
| Consumer encrypted DNS | [DNS settings](https://developer.apple.com/documentation/networkextension/dns-settings) / [manager](https://developer.apple.com/documentation/networkextension/nednssettingsmanager) | NEDNSSettingsManager iOS 14+ and dns-settings entitlement; user enables in Settings. Resolver receives names; disclose operator/logging/retention/jurisdiction/coverage/failure behavior. Saving is not activation. |
| URL-filter edition | [URL filters](https://developer.apple.com/documentation/networkextension/url-filters) / [entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) | iOS 26+, url-filter-provider, correct control extension/signed Apple-format data, NSPIRConfiguration and actual running state. WebKit/URLSession and voluntary participation coverage; not every packet. |
| URL service distribution | [WWDC25/234](https://developer.apple.com/videos/play/wwdc2025/234/) / [Identity&Trust](https://icloud.developer.apple.com/dashboard/identity) | Apple validates OHTTP relay server configuration before App Store, TestFlight, ad-hoc, Developer ID or enterprise distribution; development-signed builds are exempt. Real PIR/PrivacyPass/OHTTP operator infrastructure and approval are prerequisites, not source booleans. |
| Managed providers | [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) | DNS proxy requires supervised or iOS 16+ managed per-app deployment. Content filter uses supervised, supported managed per-app, or approved child Screen Time path. This source's managed edition needs actual supported supervised/MDM installation/capabilities; ordinary individual ScreenTime authorization does not grant child content-filter eligibility. |
| MDM/profile services | [App Review 5.5](https://developer.apple.com/app-store/review/guidelines/#mobile-device-management) | If actually offering MDM/configuration-profile services, request capability; eligible commercial/educational/government or limited security/parental-control entities, prior data disclosure and restricted data uses. Consuming managed policy is not automatically an MDM enrollment service. |
| VPN services | [App Review 5.4](https://developer.apple.com/app-store/review/guidelines/#vpn-apps) / [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) | Actual VPN services require NEVPNManager, organization enrollment, prior collection disclosure, restricted uses and applicable local license. Do not misuse a packet tunnel as generic inspection/DNS interception. This app has no VPN service. |

[`NEURLFilterManager.reportEndpoint`](https://developer.apple.com/documentation/networkextension/neurlfiltermanager/reportendpoint)
is an iOS/iPadOS 27 reporting API available only on supervised devices.
This iOS 26 URL-filter implementation does not configure that reporting API or
claim to receive URL-report feeds.

Apple's URL-service distribution statement is explicit:

> Apple will validate your server configuration for Oblivious HTTP Relay before
> approval. This must be completed before you can distribute your app on the
> App Store, with TestFlight, ad-hoc, developer-ID, or enterprise-signed builds.
> Development-signed builds are exempt from this requirement.

## Required reasons and cryptography

Current app preferences/consent/events use encrypted files, not UserDefaults.
RotationDurability now calls Darwin.fstat to verify owned app-container file/
directory types before durable synchronization. Apple explicitly lists fstat in
NSPrivacyAccessedAPICategoryFileTimestamp; reason C617.1 covers app/App Group/
CloudKit-container timestamps, size or other metadata, including this st_mode
check. No timestamps are transmitted. The app manifest must declare that actual
reason. The October 6 source audit found no direct covered API on picker-selected
external files; 3B52.1 is not added without that use. fileSizeKey/isRegularFileKey
and setting protection attributes alone are not in the retrieved list. Verify
final app and each extension after all changes. See the dated
[required-reason audit](REQUIRED-REASON-API-AUDIT.md).

If introduced: app-only defaults use CA92.1; same-AppGroup defaults 1C8F.1;
com.apple.configuration.managed/feedback.managed use AC6B.1. Covered stat/fstat/
fstatat/lstat require appropriate container C617.1 or user-granted-file 3B52.1
scope even when only another metadata property is wanted. Test-only assertions
are not shipped code. Do not invent a reason for a dependency.

Consumer native encryption uses Apple CryptoKit/Security and OS TLS/DNS APIs.
The verifier uses CryptoKit Ed25519; Linux uses the vetted SwiftCrypto backend
for portable tests. Review the actual archive graph and edition before declaring
Apple's OS-only exemption. ITSAppUsesNonExemptEncryption=false does not mean no
encryption. Apple notes exempt encryption may still require annual U.S.
self-classification reporting and French secure-storage controls; account-holder
territorial/reporting duties remain actual operator declarations.

## Identity, publication and validation

Use the verified Apple seller, copyright holder, review contact and trader
identity. App Review 5.1.1(ix) addresses services in regulated fields or requiring
sensitive user information; evaluate actual optional report/service behavior and
enrolled type. A repository company name does not prove legal ownership.

The existing policy/support URLs returned public HTTP 200 on October 5, 2026.
The live policy describes the earlier MVP and must be republished with the new
matching policy before expanded distribution. GitHub Pages source exists but
standalone Pages hosting was not enabled by this integration. The readable
GitHub policy/support route remains usable; active support monitoring and private
review contact still need real operator facts.

Portable source tests do not prove native SDK availability, OS activation,
hardware protection, signing, upload or review. Initial TestFlight upload can
precede physical QA; real-report/protection/storage/accessibility checks must
finish before final App Review. See [RELEASE-CHECKLIST](RELEASE-CHECKLIST.md).
