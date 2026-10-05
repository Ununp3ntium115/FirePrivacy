# Release from the cloud

Keep this chat in the cloud workspace. GitHub Actions provides the macOS/Xcode
runner for native tests, signing, and upload; running that workflow does not
require switching this chat to a local Mac session. Apple signing authorization
is still required. A team identifier by itself is not a certificate, private
key, provisioning profile, or App Store Connect API key.

Open these browser pages alongside the chat:

- [App implementation PR #2](https://github.com/Ununp3ntium115/FirePrivacy/pull/2)
- [GitHub Actions](https://github.com/Ununp3ntium115/FirePrivacy/actions)
- [App Store Connect](https://appstoreconnect.apple.com/)

The public privacy policy and support routes already exist:

- [Privacy policy](https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md)
- [Support](https://github.com/Ununp3ntium115/FirePrivacy/issues)

Both were verified readable without authentication with HTTP 200 on October 5,
2026. The standalone website source is on `gh-pages`; enabling GitHub Pages was
denied to this scoped integration, so no separate Pages site is claimed.

## Prepare the real Apple account

In App Store Connect, create or verify the iOS app record for the exact bundle
identifier that is registered to team `LYDVWU62G4`. The project identifier
`com.firesoftwaresolutions.FirePrivacy` remains provisional until it matches that
registered record. The account needs active membership, current accepted
agreements, and permissions to upload builds.

The cloud runner needs an existing authorized Apple Distribution signing
identity, including its private key, exported as a password-protected `.p12`,
a matching App Store provisioning profile for that registered bundle ID/team,
and an authorized App Store Connect API key. The `.p8` key needs its matching key
ID and issuer ID. A downloaded certificate without its corresponding private
key cannot sign a build.

Configure these through GitHub's secure repository/environment secrets settings.
Do not put private material in chat, commits, issue comments, screenshots,
workflow inputs, or ordinary repository variables. This integration's GitHub
secret/variable metadata requests returned HTTP 403, so existing bindings are
**unknown**, not proven absent. Reuse existing authorized bindings where they
already provide the workflow's requirements.

## GitHub settings

Use repository Settings → Secrets and variables → Actions, or the existing
`app-store` environment's secrets settings. The workflow uses that environment
and honors any protections already configured there. The prepared workflow does
not add a new approval requirement.

| Secret name | Required value | Used for |
| --- | --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64-encoded password-protected `.p12`, including the authorized Apple Distribution private key | Signing an archive |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Password for that same `.p12` | Importing the signing identity |
| `APPLE_PROVISION_PROFILE_BASE64` | Base64-encoded matching App Store `.mobileprovision` file | Signing the registered app |
| `ASC_PRIVATE_KEY_BASE64` | Base64-encoded authorized App Store Connect `.p8` key | Upload authentication |
| `ASC_KEY_ID` | Key ID for that same API key | Upload authentication |
| `ASC_ISSUER_ID` | Issuer ID for that API key's account | Upload authentication |

The first three secrets are required for `archive` mode. All six are required
for `upload` mode. Base64 is an encoding, not encryption; put the encoded content
in GitHub **Secrets**, not in a normal variable. The runner imports credentials
into temporary files and a temporary keychain outside the checkout, and cleans
them up. Private keys, passwords, the source `.p12`, and the temporary keychain
are excluded from retained artifacts. The signed app/archive contains its public
signature and embedded provisioning profile as required by Apple's format.

| Non-secret Actions variable | Value |
| --- | --- |
| `APP_BUNDLE_ID` | Required: the exact registered bundle ID matching the App Store Connect app record and provisioning profile |
| `APPLE_TEAM_ID` | Optional override; defaults to supplied team `LYDVWU62G4` |
| `PRIVACY_POLICY_URL` | Optional override; defaults to the verified public GitHub policy URL above |
| `SUPPORT_URL` | Optional override; defaults to the verified public GitHub issue tracker above |

## Run the cloud archive or upload

The prepared workflow is `.github/workflows/release.yml`, named **Signed App
Store build**. Its manual-run availability depends on GitHub having the workflow
registered; a new workflow normally needs its definition on the default branch
before the browser exposes **Run workflow**. PR #2 contains the candidate source.
Use the tested candidate branch once the workflow is available, or the merged
default branch containing that same source. Do not mistake an absent browser
button for a completed or failed release run.

In Actions → **Signed App Store build** → **Run workflow**:

1. Choose the branch containing the tested release source.
2. Set `mode` to `archive` to produce the signed archive, or `upload` to also
   upload it to App Store Connect.
3. Set `version` to the intended numeric version, initially `1.0`.
4. Set `build_number` to a positive build number not already uploaded for that
   version. The initial form default is `1`; increase it for a new upload.
5. Run the workflow and inspect its actual job result.

The job uses the hosted `macos-26` runner and Xcode 26.2. It validates the bundle,
team, signing profile, and identity; runs portable checks and native iPhone/iPad
tests; then creates and verifies the signed archive. `upload` mode uses the
authenticated Apple exporter. Failed checks stop the job. There is no option to
skip tests or bypass archive validation.

The Actions artifact is named `fireprivacy-<version>-<build_number>` and retained
for seven days. It contains `FirePrivacy.xcarchive.zip`, an exported IPA when
produced, and available native test results/screenshots. Cleanup and artifact
retention run even after a failure, so an artifact by itself is not a successful
release result. Inspect the failing step and App Store Connect before retrying:
for example, cleanup or artifact-retention failure after the upload step does
not undo an upload. The workflow prepares screenshots and the archive artifact
before attempting upload.

These are build deliverables, not proof that Apple has processed or approved the
app. A missing or unusable credential is identified by its name; supply or fix it
through secure GitHub settings, then rerun the affected job after that
configuration change. Choose a new build number if Apple already accepted the
previous upload.

## Native validation and release status

The GitHub macOS 26/Xcode 26.2 runner compiled the approved-design native source
and passed the storage/UI test steps for both iPhone and iPad at `d44a996`.
Hardware Data Protection is a separately skipped simulator check. Final local
lifecycle/accessibility/release-helper changes await another native run; GitHub
authentication began returning HTTP 401 during this session. A distributable
archive and upload remain unverified. The dated results belong in
[VALIDATION.md](VALIDATION.md).

The release path must run portable checks and native iPhone/iPad tests before
signing/upload. Do not bypass a failing test or report the build as uploaded from
a workflow definition alone. Read the actual successful job, Apple processing
status, and TestFlight build before closing the corresponding release checks.

## After upload

Upload sends a signed binary to App Store Connect; it does not submit metadata
for App Review or publish the app. Wait for Apple processing, select the build,
and test the TestFlight installation on physical iPhone and iPad. Complete the
metadata in `AppStore/` and the privacy, export, age-rating, trader, content-rights,
review-contact, and screenshot fields. Apple separates **Add for Review** from
**Submit for Review**.

Physical-device checks remain necessary even when a cloud simulator suite passes.
Use passcode-protected iPhone and iPad devices to verify the Keychain/report/
temporary-export behavior while locked and after unlock, complete file-protection
metadata, backup exclusion, real Apple report compatibility, accessibility, and
user-visible export/delete behavior. Simulator filesystems cannot establish
hardware Data Protection behavior.

See [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) for the complete submission checks
and [BUILDING.md](BUILDING.md) for the optional authenticated-Mac command-line
workflow. Record actual archive, upload, review, and release results separately.
