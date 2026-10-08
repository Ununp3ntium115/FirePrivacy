# Validation record

The current hosted iPhone/iPad validation passed at
`48e8c45e31b03bfac5c5a65034595c9c86193825` in
[run 37548308269](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548308269).
The latest October 8 upload attempt passed 43 signing-helper tests, resolved
the consumer main ID and stopped because seven signing/API bindings were
unavailable at that run. Name-only repository/environment Secrets and Variables queries all returned
HTTP 403, preventing a direct inventory; the fresh workflow establishes which
bindings were unavailable to its runner.
Multiple read-only Apple probes using uploaded/pasted candidate keys reached
Apple but returned HTTP 401 `NOT_AUTHORIZED`, without authentication or account
changes. Uploaded Safari-profile metadata is promising but does not establish
Apple signing trust; a separate main profile and distribution P12 are still
needed.

No signed distribution archive, IPA, App Store Connect upload, Apple review
approval or public App Store release has been demonstrated. Final store
screenshots have not yet been captured. Unsigned compilation and simulator tests do
not establish active OS protection, hardware security, operator deployment or
legal compliance.

## Current observed results

| Check | Observed result and scope |
| --- | --- |
| Portable checks in the latest hosted run | Each family passed 277 Core XCTest cases with zero failures and 137 Python release-tool tests. Project structure, manifests/icons and the privacy source guard passed. These checks include usage comparison/event-log import, signed rules/update envelopes, history/KB hardening and release helpers; they do not execute physical-device security. |
| iPhone native validation | Run 37548308269 compiled all three unsigned schemes: `FirePrivacy`, `FirePrivacyURL`, `FirePrivacyManaged`. Its consumer simulator ran 112 native cases: 110 passed, 2 skipped, zero failed; all 3 UI cases passed. Job completed `2026-10-06T23:54:38Z`. |
| iPad native validation | The same run compiled all three unsigned schemes. Its consumer simulator ran 112 native cases: 109 passed, 3 skipped, zero failed; all 3 UI cases passed. Job completed `2026-10-07T00:05:18Z`. |
| Deletion UI regression | Earlier [run 37540289734](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37540289734), revision `018902e7e4c3b766aad18343d94b5381914180d4`, failed the iPad Evidence navigation tap after Delete All confirmation, before checking the empty-evidence assertion. The test-only `48e8c45` fix waits for the completed deletion state and enabled/hittable navigation. `testDeletingDemoClearsPreviouslyOpenedEvidence` then passed on iPhone (38.483 seconds) and iPad (73.970 seconds). No production code was changed by that fix. |
| Simulator skips and model evidence | Both families skipped physical Data Protection and actual guided generation on eligible physical Apple Intelligence hardware. iPad additionally skipped the unavailable-only adapter rejection case because that simulator reported model readiness; iPhone exercised it successfully. Actual availability/coordinator fallback cases ran, but readiness does not establish usable generation assets or successful physical inference. |
| Screenshots and artifacts | Screenshot-capture steps were skipped on both families. Test-result retention and job cleanup passed. Existing UI diagnostic attachments are not asserted to be store-ready screenshots. |
| Consumer upload preflight | October 8 [run 37847693882](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37847693882), revision `f976de1`, passed all 43 signing-helper tests in 0.481 seconds on hosted macOS, then reported `missingBindings` for the same seven unavailable signing/API bindings, with no aggregate extension-profile alternative. The owner-confirmed main ID resolved; credential preparation, signing, archive/export and upload were skipped, and cleanup succeeded. No signed archive, IPA or Apple upload was produced. Exact binding names are in [CLOUD-RELEASE](CLOUD-RELEASE.md). |
| App record, Safari profile and remaining signing material | The owner reports ASC app 6819892589 for the confirmed main ID and an existing distribution identity on their Mac. The uploaded profile reports the expected Safari target/team/shared group, App Store distribution and an unexpired date; Safari does not require DNS entitlement. CMS cryptographic integrity was inspected without establishing Apple chain trust. macOS Apple trust/profile checks remain mandatory; a separate matching main profile and distribution P12/private key are still needed. |
| Read-only Apple account evidence | Multiple uploaded/pasted candidates parsed as P256 and signed successfully, but fresh read-only Apple requests returned HTTP 401 `NOT_AUTHORIZED`, `authenticated=false`. Both Team and Individual JWT forms were tried against a fixed app GET; a later differently named upload also failed with its exact filename-derived ID and supplied issuer. Verified TLS and aligned independent clock checks did not establish authentication. No account mutations occurred; controlled temporary signing material and the later owned downloaded copy were cleaned. No key/identifier/issuer values are published. |
| Current GitHub binding visibility | All four name-only repository/environment Secrets/Variables list requests returned HTTP 403. This does not establish absence or confirm added values. Fresh run 37847693882 directly established that the same seven bindings were unavailable to its runner; it does not expose stored secret values. |
| Required-reason API audit | Owned app-container rotation durability uses `Darwin.fstat`; the app manifest declares FileTimestamp reason `C617.1`. Current Apple text/source audit: [REQUIRED-REASON-API-AUDIT](REQUIRED-REASON-API-AUDIT.md). Signed-archive privacy reporting and Apple processing remain separate checks. |
| Public policy/support | The GitHub-rendered expanded consumer policy and public issue tracker returned unauthenticated HTTPS 200 on October 6, with the matching usage-comparison section visible. GitHub Pages metadata reports a built standalone deployment; this cloud instance's direct HTTPS check was blocked by proxy CONNECT 403, so standalone reachability is not asserted. |
| Apple requirement sources | Official Apple sources were retrieved with normal TLS and dated/digested evidence. See [APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md), [base source record](APPLE-SOURCE-VERIFICATION.json), [optional API source record](APPLE-OPTIONAL-SOURCE-VERIFICATION.json) and [usage sources](USAGE-COMPARISON-SOURCES.json). Retrieval is not Apple approval or legal certification. |

The counts are actual executed XCTest/unittest cases, recorded per family; do
not add targeted cases or repeated summary lines to these totals. The separate
Swift Testing runner's zero-case message does not replace XCTest results. The
current native result supersedes earlier passing `6f66780` and `a42b009` runs;
those are historical evidence with earlier helper/test counts. Any later app,
target, dependency or trust-anchor change needs matching validation.

Full run logs were retrieved through the official GitHub API ZIP. Temporary
logs, result bundles and production credentials are not published as repository
files. Failed preflight attempts do not establish that the owner lacks Apple
credentials; the latest attempt establishes that its runner lacked the named
bindings at that time.

The official Apple JWT guide shows a ten-character Key ID example but does not
state that exact length as a requirement. API Key ID validation now accepts
bounded, unchanged ASCII alphanumeric input of 1–64 characters;
team/prefix ten-character validation and issuer/profile/certificate gates remain.
This correction does not authenticate the rejected candidates. The targeted
checks passed 22 account-preflight and 43 cloud-signing cases (65 total), and
the full Python release suite passed 145 cases in 10.219 seconds. These counts
overlap and must not be added. Tests use genuine generated-key JWT signatures
and mocked GET responses, preserving exact Key IDs/filenames and verifying
cleanup and rejection of unsafe IDs; they do not establish real Apple account
authentication. App/Core source, targets and dependencies are unchanged, so
the passing native `48e8c45` run still matches the runtime. No extra native
rerun or successful Apple authentication is claimed. See
[APPLE-REGISTRATION](APPLE-REGISTRATION.md).

## Supporting coverage

The latest broad checks include the previously verified 36 rule/configuration
and envelope cases, 22 history cases, 22 KB cases plus real publisher
interoperability, bundled legal-notice checks, and 23 publisher Python cases.
The publisher signs all seven artifact families with isolated temporary real
Ed25519 keys and the Swift verifiers check canonical bytes, tampering and
restoration/equivocation. Nothing is published by those tests. Cloud signing
and profile tests use fixtures/mocked Apple tools; passing them does not prove
production signing authority or capability grants. Public-anchor parser tests
reject downloaded trust keys and malformed or conflicting build authority.

The production privacy guard restricts app-created networking to the approved
HTTPS worker and forbids tracking/web-view APIs. Optional approved requests and
OS-managed DNS/filtering exist; this structural check is not a runtime traffic
trace or a claim that the app never networks. The Linux Swift 6.2.3 toolchain
archive remains SHA-256 pinned with its historical release signature verified
against the official key set and signer.

## Remaining runtime and release checks

- Export the reported distribution identity as a password-protected P12, obtain
  the separate matching main App Store profile, validate the uploaded Safari
  profile through macOS Apple trust checks and obtain usable ASC authorization. Bind them securely in Actions, validate actual App Group/DNS grants,
  then produce a signed archive/upload and inspect App Store Connect processing.
- Use current physical iPhone/iPad Apple exports and supplied usage records to
  check parsing, evidence, history/comparison, retention, sharing/redaction,
  consent/revocation and deletion failures/recovery.
- On passcode-protected devices, verify complete file protection, locked-state
  Keychain/report/export access, backup exclusion and key-rotation recovery.
- Verify actual Safari/DNS activation/removal, stale/revoked dataset behavior,
  model inference/fallback on eligible hardware, request cancellation and
  TLS/pinning with the configured service. URL/managed editions also require
  their separate Apple capability/service or managed deployment prerequisites.
- Finish accessibility/layout checks and actual final screenshots. Match the
  policy, operator disclosures and App Privacy answers to the shipped edition;
  complete actual seller/review contact, rights/EULA, export, age, trader and
  territory fields before final App Review.

An initial TestFlight upload can supply the installable physical-QA build.
Complete that QA before App Review. Upload, review submission, approval and
public release are separate outcomes.

## Reproduce and continue

```sh
bash scripts/install-swift-linux.sh
bash scripts/check-portable.sh
```

Hosted macOS/Xcode 26.2 runs unsigned builds and simulator tests with:

```sh
bash scripts/build-ios.sh
bash scripts/test-ios.sh iphone
bash scripts/test-ios.sh ipad
```

Follow [CLOUD-RELEASE](CLOUD-RELEASE.md) and
[APPLE-REGISTRATION](APPLE-REGISTRATION.md) for secure bindings and the current
consumer app record. This chat continues in the cloud while GitHub supplies the
Mac runner. Record actual signing/processing/device results in the
[release checklist](RELEASE-CHECKLIST.md).
