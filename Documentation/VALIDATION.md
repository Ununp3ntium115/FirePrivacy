# Validation record

The current hosted iPhone/iPad validation passed at
`48e8c45e31b03bfac5c5a65034595c9c86193825` in
[run 37548308269](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548308269).
The latest consumer upload attempt resolved the owner-confirmed main bundle ID,
then stopped because seven signing/API bindings were unavailable to Actions.
The owner reports having those credentials; their secure Actions configuration
and validity have not yet been demonstrated.

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
| Consumer upload preflight | [Run 37548094861](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548094861), revision `0f8d244`, passed all 39 signing-helper tests on hosted macOS. The consumer main ID resolved to `com.firesoftwaresolutions.FirePrivacy`; only seven signing/API bindings were unavailable. Credential preparation, signing, archive/export and upload did not run. No signed archive, IPA or Apple upload was produced. Exact names are in [CLOUD-RELEASE](CLOUD-RELEASE.md). |
| Apple app record and credentials | The owner reports creating [ASC app 6819892589](https://appstoreconnect.apple.com/apps/6819892589/distribution/ios/version/inflight) for that main ID and having the P12, profiles and API credentials. These are owner reports, not authenticated account or credential validation by this session. Actual Safari/App Group registration, profile grants and usable Actions bindings remain unverified. |
| Read-only Apple account tooling | The 18 genuine-P256/request-boundary helper cases passed. Actual [account preflight 37403403756](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37403403756) reported the three ASC bindings unavailable before any Apple request. The later upload presence check supplies the current seven-binding evidence. No authenticated Apple registration was performed by this cloud session. |
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

- Bind the owner's existing authorized signing/API material securely in Actions,
  validate matching main/Safari profiles and actual App Group/DNS grants, then
  produce a signed archive/upload and inspect App Store Connect processing.
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
