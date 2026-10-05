# Build, test, archive, and upload

This repository contains a native SwiftUI app for iPhone and iPad, a portable
Swift core package, generated Xcode project, local privacy/support website, and
release scripts. Linux can validate the core and repository configuration. A
Mac with Xcode is required to compile the native UI, run Apple-platform tests,
sign, archive, and upload an iOS/iPadOS binary.

Use the existing checkout. Each cloud task already has an isolated environment;
no additional Git worktree is needed unless explicitly requested.

## Toolchain and dependencies

The verified Apple requirements on October 5, 2026 require **Xcode 26+** and an
**iOS/iPadOS 26+ SDK** for uploads, and an iOS/iPadOS 13+ deployment target. This
project deploys to iOS/iPadOS 17+. The scripts check the selected Xcode and iOS
SDK. See [APPLE-REQUIREMENTS.md](APPLE-REQUIREMENTS.md) for the dated sources.

The app uses system SwiftUI, Foundation, CryptoKit, and Security APIs and the
in-repository `FirePrivacyCore` module. No CocoaPods, Carthage, external SwiftPM
package, account backend, remote model, VPN entitlement, network service, or
private SDK is required. The generator and validators use Python 3's standard
library. App icons are committed; regenerating them is optional and requires
Pillow 12.3.0.

## Linux/core validation

The supplied helper installs the pinned Swift 6.2.3 Debian 12 x86_64 toolchain
under `/workspace/toolchains`, using both a pinned SHA-256 and a verified Swift
release signature. It needs `curl`, `gpg`, `rg`, `tar`, and the runtime libraries
required by that official toolchain. Preserve certificate, checksum, and
signature validation when troubleshooting installation.

From the repository root:

```sh
bash scripts/install-swift-linux.sh
bash scripts/check-portable.sh
```

The portable script uses cache/config directories under ignored `.build/tooling/`,
so it works in this sandbox without writing to the home directory. It runs the
core build, tests, project audit, and privacy scan.

Core tests exercise report normalization and malformed/untrusted input. The
privacy scan is a source check for the actual shipping target; it does not
replace inspecting the final Apple binary or runtime network behavior. Current
results belong in [VALIDATION.md](VALIDATION.md), not as an assumed pass here.

## Native build and tests on a Mac

Install Xcode 26 or newer, complete its first-launch setup, and select it as the
active developer toolchain in Xcode Settings → Locations. Install an iOS
Simulator runtime with both iPhone and iPad device types in Xcode Settings →
Components. The scripts choose an available simulator running iOS 17 or later,
preferring large iPhone and iPad display families.

Open `FirePrivacy.xcodeproj` and use the shared `FirePrivacy` scheme. For
repeatable command-line validation:

```sh
python3 scripts/validate-project.py
bash scripts/build-ios.sh
bash scripts/test-ios.sh iphone
bash scripts/test-ios.sh ipad
bash scripts/capture-screenshots.sh
```

Simulator builds are unsigned. Test result bundles and native screenshot
captures are written below ignored `.build/apple/`. The screenshot command
launches the actual app with the clearly labeled synthetic demo. Capture
additional views and verify accepted pixel dimensions using
`AppStore/SCREENSHOTS.md`; merely running the capture command does not establish
a complete screenshot submission set.

The project can be regenerated with
`python3 scripts/generate-xcode-project.py`. Regeneration writes project
configuration, so use it when source/resource membership changes and inspect
the diff. Routine builds do not require it.

## Configure signing and public pages

The supplied signing team is `LYDVWU62G4`. A team ID does not grant credentials.
Sign in to the correct Apple Developer account in Xcode Settings → Accounts and
verify access to that team. Alternatively, configure the optional complete
`ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID` triple for an authorized App
Store Connect API key. The local `.p8` file stays outside the repository. Do not
paste private keys, passwords, or signing assets into chat, source, logs, or
metadata.

Register the final bundle identifier and create the corresponding iOS app
record in App Store Connect. Set `BUNDLE_ID` in the shell to that exact registered
identifier. `TEAM_ID` defaults to the supplied team. Set `APP_VERSION` and a
unique `BUILD_NUMBER` for the upload; defaults are `1.0` and `1`. The project's
development identifier is provisional and is not proof of a registered ID.

The public [privacy policy](https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md)
and [support issue tracker](https://github.com/Ununp3ntium115/FirePrivacy/issues)
were verified as readable without authentication with HTTP 200 on October 5,
2026. They are the default `PRIVACY_POLICY_URL` and `SUPPORT_URL`. These are
built into the app's
`FirePrivacyPrivacyURL` and `FirePrivacySupportURL` fields. The app also displays
its local privacy explanation without a network connection. Use the same URLs
in App Store Connect. See [website/README.md](../website/README.md).

The standalone `website/` files are also published to `gh-pages`, but enabling
GitHub Pages returned HTTP 403 for this integration. The owner can enable the
site in repository settings or use another HTTPS static host. To change the
default URLs, set `PRIVACY_POLICY_URL` and `SUPPORT_URL` to verified public HTTPS
pages and rebuild. Do not modify an archive after signing. Contact monitoring and
the account's actual review-contact details remain submission requirements.

## Signed archive and upload option

The shortest workflow on the authenticated Mac is:

```sh
bash scripts/release-to-app-store.command
```

This runs the checks and signed archive, then opens the archive in Xcode
Organizer with the **Distribute App → App Store Connect** option. To use the
command-line upload option after those checks instead:

```sh
bash scripts/release-to-app-store.command --upload
```

The wrapper uses team `LYDVWU62G4`, the verified public URLs, and provisional
bundle identifier `com.firesoftwaresolutions.FirePrivacy`. That identifier must
be registered to the team and match the App Store Connect app record; override
`BUNDLE_ID` with the actual registered identifier if it differs. It does not
register an identifier or authenticate an account merely by printing its name.

On the configured Mac, with the registered `BUNDLE_ID` already set:

```sh
: "${BUNDLE_ID:?Set BUNDLE_ID to the exact registered identifier}"
export BUNDLE_ID
export TEAM_ID=LYDVWU62G4
bash scripts/archive-ios.sh
```

The archive script runs core tests, source privacy checks, and iPhone/iPad
Apple-platform tests before creating a signed Release archive. It verifies the
signature and records hashes of the executable, plist, privacy manifest, and
provisioning profile alongside the test results. Its output prints the absolute
archive path and writes `.build/apple/LatestArchive.txt`.

Upload the validated archive when ready:

```sh
archive_path="$(cat .build/apple/LatestArchive.txt)"
bash scripts/upload-app-store.sh "$archive_path"
```

The upload script verifies the archive against its recorded checks, bundle ID,
team, SDK, universal device support, signature, and configured public URLs. It
uses authenticated `xcodebuild -exportArchive` with export method
`app-store-connect` and destination `upload`. It does not create App Store
metadata or submit a version for review.

For an Xcode UI workflow, use Product → Archive, then Organizer → Distribute App
→ App Store Connect. Upload goes to **App Store Connect**, not the Apple
Developer membership portal. Inspect any validation/processing warnings before
moving forward.

## Processing, TestFlight, and submission

After Apple processes the upload, find it in App Store Connect → My Apps → the
app's TestFlight/Distribution pages. Test the uploaded build on physical iPhone
and iPad, including real Apple-generated report import, offline browsing,
export, delete, encryption/Keychain behavior, backup exclusion, and accessibility.

Complete the version's metadata using `AppStore/`, upload actual-build screenshots,
choose the processed build, and finish the privacy, export, age-rating, content
rights, trader, support, and review-contact fields. The required role for final
submission is Account Holder, Admin, or App Manager. Apple currently separates
**Add for Review** from **Submit for Review**: the first prepares a draft and
does not send it to App Review. Use the actual App Store Connect status as the
record of submission.

The signed archive, upload, completed metadata, review submission, review
approval, and public release are separate results. Track each in
[RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md); report the app as live only after the
public listing and download have been verified.

## Common failures

| Result | Diagnosis and next action |
| --- | --- |
| “This step needs a Mac” | The Linux environment cannot run Apple SDKs. Continue core checks here and run the native scripts on macOS. |
| Xcode/SDK below 26 | Select/install the required Xcode and SDK; do not lower the submission check to make upload pass. |
| No iPhone/iPad simulator | Install an iOS Simulator runtime and the corresponding device types in Xcode. |
| Provisioning or team error | Verify account role, registered bundle ID, team access, certificates, and profiles. The team ID alone does not authenticate. |
| Archive changed after validation | Rebuild through `archive-ios.sh`; do not edit a signed archive or fabricate a validation result. |
| Public page fails HTTPS/reachability | Fix the hosting/URL and retest without disabling TLS verification. App Store metadata requires reachable public policy/support pages. |
| Real report import differs from demo | Reproduce with a small synthetic fixture and fix compatibility before submission; demo success alone is insufficient. |
