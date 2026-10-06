# Fire Privacy

A native iPhone and iPad privacy control center built around the App Privacy Report you export from Settings. Import and analyze evidence on your device, compare encrypted report history, review cited findings, and choose supported protection and explanation features explicitly.

The app has no account, ads, tracking SDK, subscription, or report resale. A recorded contact does not prove what was transmitted or establish harm. Historical sensor records do not show another app’s current permissions. Unknown ownership stays unknown.

## Engineered concepts

- Bounded hostile-input import, exact reported fields, content-derived evidence IDs, source/line hashes, timestamp precision, public-suffix normalization and sensor begin/end distinctions.
- Signed, cited knowledge; versioned deterministic findings with separate facts, inferences, uncertainty, evidence, actions and explainable posture dimensions. Preferences change relevance rather than factual confidence.
- Profiles, self-reported permission audits, local domain overrides, encrypted session history, comparisons, weekly summaries and bounded analysis revisions.
- Local activity-versus-usage comparison with report-bound recollections, transcribed durations and supplied opened/closed logs; timestamp precision, gaps, device scope and unverified claims stay visible. See [USAGE-COMPARISON](Documentation/USAGE-COMPARISON.md).
- AES-GCM storage with a device-only unlocked Keychain key, optional encrypted source retention, retention limits, generation guards, recoverable key rotation, deletion and retryable cleanup.
- JSON/CSV/Markdown full or redacted exports and opt-in sanitized diagnostics. Originals and previously shared copies remain outside the app’s control.
- Persisted feature-specific consent, exact one-use network previews, cancellation/revocation and a bounded host/purpose/byte/status ledger. Local import and analysis need no network request.
- Offline guidance; optional Apple on-device presentation assistance and a user-operated HTTPS advisor. Models choose from grounded presentation options; authored facts and actions remain deterministic. No automatic cloud fallback.
- Safari content blocking and optional encrypted DNS with real OS activation checks. Separate URL-filter and managed editions contain their own providers and distribution gates.
- Local notification reminders and secure, explicitly retained endpoint credentials. Report data and credentials never enter the protection App Group.

[FEATURE-COVERAGE](Documentation/FEATURE-COVERAGE.md) maps the original concepts to source, integration and external prerequisites. [VALIDATION](Documentation/VALIDATION.md) separates portable tests, native SDK/simulator checks, signing and hardware QA. The expanded UI and native implementation are undergoing hosted validation; source presence is not App Store acceptance.

## Develop in the cloud

```sh
bash scripts/install-swift-linux.sh
bash scripts/check-portable.sh
```

The Linux workspace tests the portable core and release tooling. GitHub Actions uses hosted Macs for the Apple SDK, all three editions, encrypted storage, and iPhone/iPad UI tests. Screenshot capture is optional and disabled during underlying engineering.

On macOS, open `FirePrivacy.xcodeproj`. The consumer and managed app support iOS/iPadOS 17 or later; the separate URL-filter edition requires iOS/iPadOS 26. Build and release instructions are in [BUILDING](Documentation/BUILDING.md) and [CLOUD-RELEASE](Documentation/CLOUD-RELEASE.md). [SESSION](Documentation/SESSION.md) records the cloud handoff.

## Release and operation

The manual signed-build workflow can archive or upload a validated build to **App Store Connect**. It does not submit for review or release the app. Apple Developer manages identifiers, capabilities and signing; App Store Connect receives builds and handles TestFlight and review.

Team `LYDVWU62G4` was supplied by the developer. The proposed bundle identifier remains provisional until its registration and App Store Connect record are verified. Matching distribution credentials belong in the private GitHub Actions environment, never in source or chat.

[RELEASE-CHECKLIST](Documentation/RELEASE-CHECKLIST.md) covers the current Apple requirements and remaining release evidence. Draft listing/policy/review material is in `AppStore/`; standalone public-page source is in `website/`. Policies must match the exact edition before submission.

Runtime dataset updates require an operator’s deployed **public** trust anchors, maintained signed data/revocations, a real HTTPS endpoint and truthful retention disclosures. [DATASET-PUBLISHING](Documentation/DATASET-PUBLISHING.md) describes the local publisher. Private signing keys never ship in the app. URL protection also needs Apple-granted capability and a registered operating PIR/Privacy Pass/OHTTP service; managed protection needs an eligible supervised/MDM deployment. Those external services and approvals are not established by a passing simulator build.

## Structure

```text
Apps/FirePrivacyApp/       SwiftUI app, integration engine and protected storage
Sources/FirePrivacyCore/   Portable evidence, knowledge, analysis and consent
Extensions/               Safari, URL-control and managed providers
Tests/                    Core, native, UI, release and privacy checks
scripts/                  Build, dataset publishing, archive and upload helpers
Documentation/            Architecture, validation and release requirements
AppStore/                 Draft listing, privacy policy and review material
website/                  Privacy and support page source
```

Read [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md) and [PRIVACY-ARCHITECTURE](PRIVACY-ARCHITECTURE.md) before changing privacy behavior.
