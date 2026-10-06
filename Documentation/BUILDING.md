# Build, test, archive and upload

The repository contains a portable Swift core, a native iPhone/iPad app, separate
protection editions, generated Xcode project, draft privacy/support site and
release scripts. Linux validates portable code and repository/signing contracts.
macOS/Xcode validates native APIs, simulator tests and signed archives. Hosted
GitHub Actions supplies that Mac; see [CLOUD-RELEASE](CLOUD-RELEASE.md) to keep
this session in the cloud. The local Mac commands below are an additional route.

## Dependencies and toolchain

Apple's verified October 5, 2026 upload minima are Xcode 26+, iOS/iPadOS 26+ SDK
and deployment target 13+. This project uses Xcode 26.2 in hosted workflows;
consumer/managed schemes target iOS 17+, and the URL-filter scheme targets 26+.
SystemLanguageModel additionally needs a ready, eligible iOS/iPadOS 26 device.
Source settings do not establish a native build or platform eligibility.

The native graph uses public Apple SwiftUI, Foundation, CryptoKit, Security,
SafariServices, NetworkExtension, UserNotifications and conditionally
FoundationModels APIs plus in-repository code. `Package.swift` pins Apple Swift
Crypto 3.15.1 for Linux hashing/signature verification; Apple platforms use
CryptoKit. Bundled resources include public-suffix and authenticated domain
knowledge data. Check final dependency/license attribution rather than assuming
an earlier MVP graph remains unchanged.

Project/signing validators use Python 3's standard library. The approved flame
artwork and opaque 1024-pixel icon are committed. The optional
`scripts/generate-app-icon.py` export helper uses ImageMagick or macOS `sips`
with `Design/FirePrivacy-icon-master.png`; it does not generate new artwork.

## Portable checks

From the existing checkout:

```sh
bash scripts/install-swift-linux.sh
bash scripts/check-portable.sh
```

The installer pins Swift 6.2.3 Debian 12 x86_64 under `/workspace/toolchains`,
verifying the release signature and SHA-256 with normal HTTPS verification.
Preserve all verification when troubleshooting. The check helper builds/tests
core code, runs the CloudRelease Python suite, validates the generated project
and scans the actual local-analysis/network boundaries. Sandbox caches/config
stay below ignored `.build/tooling/`.

Run the signing/configuration tests separately if needed:

```sh
python3 -m unittest discover -s Tests/CloudRelease -p 'test_*.py' -v
```

These tests use synthetic fixtures, owned temporary directories and mocked Apple
tools where appropriate. They do not establish an account's certificates,
profiles, capability approval or actual signing/upload. Dated counts and native
results belong in [VALIDATION](VALIDATION.md); a source privacy scan does not
replace binary inspection or runtime traffic testing.

## Native build and tests

Use Xcode 26.2+ with its first-launch setup complete, selected under Xcode
Settings → Locations. Install an iOS 26 simulator runtime with both iPhone/iPad
models for the full edition build. The generated schemes are `FirePrivacy`
(consumer), `FirePrivacyURL`, and `FirePrivacyManaged`.

```sh
python3 scripts/validate-project.py
bash scripts/build-ios.sh
bash scripts/test-ios.sh iphone
bash scripts/test-ios.sh ipad
```

The build helper compiles all three schemes separately with signing disabled.
Simulator test hosts use ad-hoc signing for Keychain behavior; no distribution
certificate is needed for those tests. `APP_EDITION` selects the tested/released
edition (`consumer`, `url-filter`, `managed`; default consumer). Test logs and
result bundles go under ignored `.build/apple/`.

Screenshots are paused until the underlying functionality and native controls
are verified. When that work is complete, `bash scripts/capture-screenshots.sh`
captures the actual app with synthetic demo activity. Verify every required
image/dimension against [SCREENSHOTS](../AppStore/SCREENSHOTS.md); a capture
command alone does not establish a complete submission set.

Regenerate source/resource/target membership with
`python3 scripts/generate-xcode-project.py` when membership changes, then inspect
the project diff. Routine builds do not require regeneration. Physical iPhone/
iPad QA is separate from simulator compilation/tests.

## Real identifiers, signing and public pages

The supplied team is `LYDVWU62G4`; the provisional base ID is
`com.firesoftwaresolutions.FirePrivacy`. Confirm actual registered edition/app/
extension identifiers, App Group, granted capabilities, matching profiles and
App Store Connect app record. Consumer includes only Safari; URL/managed editions
have additional selected profiles and external deployment/service gates. See
[CLOUD-RELEASE](CLOUD-RELEASE.md) for the exact cloud secret/variable schema and
[APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md) for those gates.

For a local automatic-signing route, authenticate an authorized Xcode account.
An optional complete `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` triple supplies
an authorized API key; the `.p8` stays outside the checkout. A team ID, API key
ID or certificate without its private key cannot itself sign. Keep signing keys,
passwords, profiles and model tokens out of chat, commits, logs and artifacts.

Set `BUNDLE_ID` or `APP_BASE_BUNDLE_ID` to the real registered base and
`APP_EDITION` to the chosen edition. `TEAM_ID` defaults to the supplied team;
`APP_VERSION` and `BUILD_NUMBER` default to 1.0 and 1. Use a unique build number
for a newly accepted upload. The provisional defaults register nothing.

The public [policy](https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md)
and [support](https://github.com/Ununp3ntium115/FirePrivacy/issues) returned HTTP
200 without authentication on October 5, 2026 and are default build/metadata
URLs. The live policy still describes the earlier MVP: publish the revised
matching policy before expanded distribution. `PRIVACY_POLICY_URL`/`SUPPORT_URL`
can override those defaults with verified public HTTPS pages. Rebuild after a
change; never modify an already signed archive. Standalone Pages hosting was
not enabled by this integration; see [website README](../website/README.md).

## Archive and upload

On a configured authenticated Mac, the wrapper runs required checks and signed
archive, then opens Xcode Organizer:

```sh
bash scripts/release-to-app-store.command
```

The explicit upload option runs the same checks before sending to ASC:

```sh
bash scripts/release-to-app-store.command --upload
```

For separate commands with identifiers/edition already configured:

```sh
bash scripts/archive-ios.sh
archive_path="$(cat .build/apple/LatestArchive.txt)"
bash scripts/upload-app-store.sh "$archive_path"
```

The archive helper runs core/Python/source checks and both native simulator
suites before creating a signed device archive. It verifies signing, selected
edition/embedded targets/profiles, SDK/configuration and records validation
hashes. Upload verifies the recorded archive and configured HTTPS URLs, then
uses `xcodebuild -exportArchive` with `app-store-connect` and destination upload.
The helpers do not create missing account records, complete metadata or submit
for review. Cloud execution uses the same helpers and selected-target validation.

In Xcode Organizer use Distribute App → App Store Connect. Upload goes to App
Store Connect, separate from the Developer membership portal. Inspect Apple
processing and the actual build; initial TestFlight upload can provide the
installable physical QA build. Finish real-report/storage/protection/model/
accessibility checks and final declarations/screenshots before App Review.
Upload, processing, TestFlight, Add for Review, Submit for Review, approval and
public release are separate statuses. See [RELEASE-CHECKLIST](RELEASE-CHECKLIST.md).
