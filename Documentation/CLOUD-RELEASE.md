# Release from the cloud

Keep this chat cloud based. GitHub Actions supplies macOS/Xcode for tests,
signing and App Store Connect upload; no local Mac session is required to run
it. Actual Apple authorization is still required. A team identifier is not a
certificate/private key, profile, capability grant or upload credential.

[APPLE-REGISTRATION](APPLE-REGISTRATION.md) records the owner-confirmed consumer
main ID/app record, remaining Safari/App Group checks, shared-browser blocker
and Apple's supported registration routes.

The owner has now reported creating [App Store Connect app 6819892589](https://appstoreconnect.apple.com/apps/6819892589/distribution/ios/version/inflight)
for `com.firesoftwaresolutions.FirePrivacy`. This main ID is the consumer
workflow fallback; registered Actions overrides still take precedence. Other
editions continue to require their exact registered ID in Actions variables.
The app record alone does not supply distribution credentials, extension/group
registration or profile capability grants. The report is not an authenticated
account verification by this cloud session.

Keep browser tabs for [PR #2](https://github.com/Ununp3ntium115/FirePrivacy/pull/2),
[Actions](https://github.com/Ununp3ntium115/FirePrivacy/actions) and
[App Store Connect](https://appstoreconnect.apple.com/). The existing public
[policy](https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md)
and [support](https://github.com/Ununp3ntium115/FirePrivacy/issues) returned HTTP 200
without login on October 6, 2026. The expanded consumer policy is published;
the matching usage-comparison section is visible on the GitHub-rendered route.
Pages metadata now reports a built standalone deployment; its direct HTTPS
check in this instance was blocked by proxy CONNECT403. Use the verified
GitHub policy route until standalone reachability is verified.

## Select the actual edition

| Edition | Embedded provider targets | Extra deployment conditions |
| --- | --- | --- |
| `consumer` | `SafariContentBlocker` | Registered App Group/app+Safari IDs/profiles; app dns-settings capability; actual Safari/DNS Settings enablement |
| `url-filter` | `SafariContentBlocker`, `URLFilterControl` | iOS 26, url-filter-provider capability; operating registered PIR/PrivacyPass/OHTTP service and Apple relay validation before non-development distribution, including TestFlight |
| `managed` | `SafariContentBlocker`, `ManagedFilterData`, `ManagedFilterControl` | Granted content-filter capabilities and eligible supported supervised/MDM deployment/operator |

Consumer archives exclude URL/managed providers. Use the correct registered base
identifier and ASC app record for the chosen product; do not infer another
edition's authority from a successful consumer archive. Full legal/capability
conditions are in [APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md).

## Secure settings and real Apple prerequisites

Verify active membership/agreements/role for team LYDVWU62G4, the exact registered
base/extension IDs and App Group, and a matching App Store Connect app record.
The runner needs an authorized Apple Distribution `.p12` containing its private
key, matching App Store profiles for the selected targets, and an authorized
ASC `.p8`, key ID and issuer ID for upload. A certificate without its private key cannot
sign. Each profile must be unexpired, explicit App Store distribution, match the
team/ID/group/capabilities, and share the selected valid signing certificate.

After its signing-helper unit tests, the release workflow runs
`cloud-signing.py check-bindings` before opening credentials. This reports all
missing binding names together without opening keys/profiles, creating
private files, signing, or contacting Apple. It accepts the existing aggregate
extension-profile alternative as present; the later signing preparation still
validates its exact selected-target coverage and credential contents. Presence
does not establish valid credentials, registered identifiers or upload access.
The existing configuration, native-test, profile/signature and archive/export
checks remain required before upload.

Latest consumer **upload-mode** [run 37548094861](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548094861)
at `0f8d244` passed all 39 signing-helper tests on macOS and resolved the
owner-confirmed main ID `com.firesoftwaresolutions.FirePrivacy`. Only these
seven signing/API bindings were unavailable to that runner:
`APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD`,
`APPLE_PROVISION_PROFILE_BASE64`, `APPLE_SAFARI_PROVISION_PROFILE_BASE64`,
`ASC_PRIVATE_KEY_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`. No aggregate
extension-profile alternative was available. Credential preparation, signing,
archive/export and upload were skipped; cleanup passed. No signed archive,
IPA or Apple upload was produced.

The owner now reports having the P12, profiles and API credentials. Whether
those existing materials are securely configured and usable in Actions remains
unverified. Configure or verify the seven Secrets bindings at repository level
or in environment `app-store`, reusing valid existing materials. The consumer
main ID already has a workflow fallback; set `APP_BASE_BUNDLE_ID` only to
supply an intended registered override. Verify actual Safari/App Group grants
from the matching profiles, then rerun in `upload` mode with the intended
marketing version and an unused build number. A logged-in Apple browser tab
alone does not bind credentials to Actions.

Use repository Settings → Secrets and variables → Actions or environment `app-store`.
Existing environment protections are honored; the workflow adds no invented
approval gate. Never put secrets in chat/commits/issues/screenshots/workflow
inputs or ordinary variables. This integration's secret/variable metadata
requests returned HTTP 403 and could not inventory Secrets. The later runner
check establishes which bindings were unavailable at that attempt; it does not
establish whether the owner has since configured them. Reuse valid existing
credentials rather than generating replacements unnecessarily.

Historical read-only account [preflight 37403403756](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37403403756)
passed 18 genuine-token/request-boundary tests, then stopped because its three
ASC bindings were unavailable. No Apple request or registration occurred. The
latest upload-mode check above provides the newer seven-binding evidence.

| Secret | Purpose |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64 password-protected `.p12` with private key |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Matching password |
| `APPLE_PROVISION_PROFILE_BASE64` | Base64 selected main-app `.mobileprovision` |
| `APPLE_SAFARI_PROVISION_PROFILE_BASE64` | Base64 Safari profile; every edition |
| `APPLE_URL_PROVISION_PROFILE_BASE64` | Base64 URL provider profile; URL edition |
| `APPLE_MANAGED_DATA_PROVISION_PROFILE_BASE64` | Base64 managed data profile; managed edition |
| `APPLE_MANAGED_CONTROL_PROVISION_PROFILE_BASE64` | Base64 managed control profile; managed edition |
| `ASC_PRIVATE_KEY_BASE64` | Base64 authorized `.p8`; upload authentication |
| `ASC_KEY_ID` | That key's ID |
| `ASC_ISSUER_ID` | That account's issuer ID |

An alternative extension binding is `APPLE_EXTENSION_PROFILES_BASE64`: despite
its name, its value is a **raw JSON object**, with target names as keys and each
value a base64 profile. Valid keys are `SafariContentBlocker`, `URLFilterControl`,
`ManagedFilterData`, `ManagedFilterControl`. Include every selected target; do
not mix an aggregate map with individual secrets for the selected targets.
Prefer individual secrets to avoid GitHub's per-secret size limit. Base64 is
encoding, not encryption: all of these values belong in Secrets.

Archive mode needs the signing/profile bindings for its selected edition.
Upload also needs the complete ASC triple. A partially configured ASC triple
cannot authenticate and is rejected rather than silently ignored. Temporary
files/keychain stay outside the checkout and are cleaned; private keys/passwords/
source profiles are excluded from artifacts. Signed apps naturally contain public
signatures and embedded profiles as required by Apple.

| Non-secret Actions variable | Value |
| --- | --- |
| `APP_BASE_BUNDLE_ID` | Exact registered base ID override; consumer defaults to owner-confirmed `com.firesoftwaresolutions.FirePrivacy`; URL/managed require this or legacy `APP_BUNDLE_ID` |
| `APPLE_TEAM_ID` | Optional override; default LYDVWU62G4 |
| `FIREPRIVACY_APP_GROUP_ID` | Actual registered group; provisional default `group.com.firesoftwaresolutions.FirePrivacy.protection` |
| `FIREPRIVACY_PIR_SERVER_URL` | Actual service URL; URL edition only |
| `FIREPRIVACY_PRIVACY_PASS_ISSUER_URL` | Actual issuer URL; URL edition only |
| `FIREPRIVACY_PIR_CONFIGURATION_IDENTITY` | Exact approved configuration identity; URL edition only |
| `PRIVACY_POLICY_URL`, `SUPPORT_URL` | Optional HTTPS overrides; default public GitHub routes above |
| `FIREPRIVACY_KB_PUBLIC_KEYS_JSON` | Optional raw JSON key-ID → lowercase 64-hex public-key map for maintained KB/revocation/rule updates |
| `FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON` | Optional matching filter-publisher public-key map, propagated to the app and every included provider |

These dataset values are public build authority, not Apple signing secrets or
private dataset keys. Empty maps preserve bootstrap data for consumer use;
maintained operator updates need the publisher's actual matching public key
deployed before the download is accepted. The publisher emits exact public
variable names/JSON in `public-key-reference.json`; see
[DATASET-PUBLISHING](DATASET-PUBLISHING.md). No key is learned from a download.
Build/preflight/archive checks reject duplicate IDs, malformed maps, changed
pins, knowledge/filter ID collisions or different app/provider filter maps.

## Manual archive or upload

The [Signed App Store build](https://github.com/Ununp3ntium115/FirePrivacy/actions/workflows/release.yml)
workflow is registered and active on main. Latest
[native run 37548308269](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548308269)
passed both families at `48e8c45`, including the iPad deletion/navigation
regression. Exact per-family counts and simulator limitations are in
[VALIDATION](VALIDATION.md). The latest upload attempt stopped at the seven
missing bindings above; no signing or upload success is implied.

In Actions → Signed App Store build → Run workflow:

1. Choose the tested source branch/revision and `edition` (default `consumer`).
2. Choose `mode`: `archive` creates/exports the signed build; `upload` also sends
   it to App Store Connect.
3. Set numeric `version` (default 1.0) and a positive unique `build_number`
   (default 1; increment for a newly accepted upload).
4. Leave `capture_screenshots=false` while core functionality/native controls are
   being validated. Later enable only to capture actual synthetic build screens.
5. Run and inspect actual step results, errors and Apple processing.

Hosted tooling uses macos-26/Xcode 26.2. Binding inventory and identifier checks
run before credentials are opened. Matching credential/profile validation,
portable checks and native iPhone/iPad tests precede the archive. Failed checks
stop release; no test bypass is provided. Exact edition/embedded-target/profile/
entitlement identities are validated again before export. Optional screenshots are prepared before upload
when requested, but App Store screenshots are not a prerequisite for initial
TestFlight upload.

The artifact is `fireprivacy-<edition>-<version>-<build_number>`, retained seven
days, with the signed archive ZIP, IPA when produced, available test results/logs
and optional screenshots. Cleanup/artifact steps run even after failure, so an
artifact is not proof of a successful job. Failure after upload does not undo the
upload: inspect ASC before retrying or choosing a new build number.

## Validation and after upload

Current portable/native results, their exact source revisions and later pending
changes are recorded in
[VALIDATION](VALIDATION.md). Earlier MVP native results do not validate new
architecture/edition targets. No signed expanded archive/upload/approval is
established by workflow source or source-test results.

A successful upload sends a binary; wait for Apple processing and verify the
actual build in TestFlight. Physical QA can follow that initial upload but must
finish before final App Review: real current reports, history/export/delete,
key/protection/backup/locked state, Safari/DNS activation/removal, supported model
inference/fallback, accessibility and layouts. Complete final policy/App Privacy/
export/age/trader/content-rights/contact/metadata and actual screenshots. Select
the processed build, Add for Review, then Submit for Review. Approval and public
release remain separate statuses. See [RELEASE-CHECKLIST](RELEASE-CHECKLIST.md).
