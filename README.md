# Fire Privacy

A native iPhone and iPad privacy report reader. Import an App Privacy Report exported from Settings, explore recorded domain contacts and sensor events, and get clear steps for reviewing privacy settings. Reports are analyzed on the device. No account, advertisements, tracking SDKs, or app-operated network requests.

## The first release

- An adaptive SwiftUI dashboard, app and domain detail, linked evidence, and settings guidance.
- Bounded newline-delimited JSON import with visible rejected-record counts. Supported records and limits are documented in [BUILDING](Documentation/BUILDING.md).
- One normalized report encrypted with CryptoKit AES-GCM, using a device-only Keychain key and file protection.
- Explicit sharing and deletion controls, with a warning before exporting readable report data.
- A clearly labeled synthetic demo that works without an account or a personal export.
- An in-app Trust Center that explains storage, sharing, and the limits of the evidence.

A recorded domain contact does not reveal its payload or prove harm. Historical sensor events do not show current permissions. App identities are exported bundle identifiers, not an inventory of installed apps. This release does not block traffic, change other apps’ settings, classify tracking vendors, or use AI.

The original repository described a broader product. [FEATURE-COVERAGE](Documentation/FEATURE-COVERAGE.md)
maps those concepts to this candidate and records missing knowledge-base,
versioned analysis/scoring, filtering, private-advisor, and managed-edition work.

## Develop

Open `FirePrivacy.xcodeproj` in a supported Xcode on macOS. The app targets iOS/iPadOS 17 or later; App Store submission must use Apple's currently required SDK. See [BUILDING](Documentation/BUILDING.md) for simulator, device, archive, and upload commands.

The portable analysis engine can also be built and tested on Linux with Swift 6:

```sh
swift build
swift test
./Tests/PrivacyRegression/no-network-in-local-analysis.sh
```

The app's UI, Keychain, CryptoKit storage, simulator checks, and signing require Apple platforms. A passing Linux suite does not validate those parts.

You can keep development cloud based: this chat uses the Linux workspace, and
GitHub Actions uses hosted Macs for the Apple toolchain. See
[SESSION](Documentation/SESSION.md) for the durable handoff and
[CLOUD-RELEASE](Documentation/CLOUD-RELEASE.md) for browser-driven signing and upload.

## Release

[RELEASE-CHECKLIST](Documentation/RELEASE-CHECKLIST.md) records the checks required before submission. Draft metadata and review notes live in `AppStore/`; deployed privacy and support links are listed in [CLOUD-RELEASE](Documentation/CLOUD-RELEASE.md), and standalone website source lives in `website/`. App Store Connect handles uploads and review; the Apple Developer site handles developer resources and signing capabilities.

Team `LYDVWU62G4` was supplied by the developer for signing. The proposed bundle identifier is a development default until it is registered for this app. Signing certificates, private keys, passwords, and App Store Connect API keys must never be committed.

The source implementation is a first-release candidate, not an assertion of App Store approval or legal compliance. See the validation record for completed tests and remaining checks.

## Structure

```text
Apps/FirePrivacyApp/        SwiftUI app and encrypted storage
Sources/FirePrivacyCore/   Portable parser, summaries, and descriptive findings
Tests/                    Core, Apple-platform, and privacy checks
Resources/                Synthetic demo report
FirePrivacy.xcodeproj/     Universal iPhone/iPad app project
scripts/                  Build, archive, and upload helpers
Documentation/            Architecture, validation, and release requirements
AppStore/                 Draft store listing and review material
website/                  Privacy and support pages ready to host
```

Read [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md), and [PRIVACY-ARCHITECTURE](PRIVACY-ARCHITECTURE.md) before changing privacy behavior.
