# Building Fire Privacy

## Requirements

- Xcode with an iOS 18 SDK or later (iOS 26 SDK for the URL filter work).
- Swift 6 toolchain. Every target builds in Swift 6 language mode with strict
  concurrency.

## The packages

```bash
swift build
swift test
```

The domain modules have no Apple-only dependencies except where guarded:
CryptoKit, NetworkExtension, FoundationModels and SwiftUI are all behind
`#if canImport(...)`, so `swift test` runs the parser, normalizer, knowledge
base, rules engine, scoring, advisor validation and export tests on Linux CI as
well as on macOS.

Two consequences worth knowing:

- On a platform without CryptoKit, `CryptoBox` throws rather than storing
  anything, and signature verification **fails closed**. Storage tests are
  compiled out; correctness tests are not.
- SwiftUI views compile only where SwiftUI exists. They are all inside
  `#if canImport(SwiftUI)`.

## The app

The iPhone app is an Xcode target assembled from:

- `Apps/FirePrivacyApp/` — the app sources, including the two files that touch
  Apple frameworks the packages deliberately avoid:
  - `FoundationModelsBridge.swift` (Foundation Models)
  - `SystemURLFilterBridge.swift` (`NEURLFilterManager`)
- the local Swift package (add this repository's root as a local package
  dependency and link `FirePrivacyUI`);
- `Apps/FirePrivacyApp/Supporting/Info.plist`;
- `Apps/FirePrivacyApp/Supporting/FirePrivacy.entitlements`;
- `Resources/PrivacyInfo.xcprivacy`.

Both bridges currently report their capability as unavailable. That is
deliberate: until the entitlement and the SDK calls are verified on a device, the
app must say "not available in this build" rather than offer a control that
cannot work. Each has a `TODO(Gate n)` marking exactly what has to be verified.

## Privacy regression

```bash
./Tests/PrivacyRegression/no-network-in-local-analysis.sh
```

This must pass before every release. It proves the local-analysis modules link
no networking API, the knowledge base cannot load code, the advisor never
interpolates input into instructions, and the store never writes to the App
Group.

## Regenerating bundled data

The demo report and the bundled knowledge base are generated, then embedded as
Swift string literals so no resource bundle is needed:

- `Resources/DemoReports/demo-report.ndjson` → `DemoReport.swift`
- `Resources/BundledKnowledgeBase/knowledge-base.json` → `BundledKnowledgeBase.swift`

Regenerate the JSON first, then re-embed. The embedded copy and the file must
match; `BundledKnowledgeBaseTests` decodes the embedded copy on every run.
