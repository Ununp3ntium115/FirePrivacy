# Validation record — October 6, 2026

The expanded privacy architecture has passing portable tests and a successful
hosted iPhone/iPad native run. Later source changes still need their own results.
This record distinguishes the revision tested from the working source; earlier
local-report MVP results do not establish readiness of the expanded app.

No signed distribution archive, App Store Connect upload, Apple review approval
or public App Store release has been demonstrated. Screenshots remain deferred
at the user's direction while underlying functionality is engineered and
validated. Source existence and unsigned compilation do not establish active
OS protection, hardware security, operator deployment or legal compliance.

## Observed results

| Check | Observed result and scope |
| --- | --- |
| Current full portable workflow | `bash scripts/check-portable.sh` completed with exit 0 on October 6: Swift 6.2.3 executed 277 core XCTest cases with 0 failures; 111 cloud-release Python tests passed; project structure/manifests/icons and privacy guard passed. This includes 37 usage comparison/event-log cases alongside rules, update envelopes, legal notices and history/KB hardening. It does not execute native Apple APIs. |
| Earlier expanded checkpoint | 173 core XCTest and 77 Python cases passed before the later additions. This historical checkpoint is superseded by the current full portable result, not a count for the final native build. |
| Rule configuration and download-envelope tests | A later targeted run passed 36 XCTest cases covering closed declarative configuration, eight compiled detectors, bounded thresholds, genuine signatures, expiry, authority/revocation, full-manifest restoration/equivocation, disabled-detector posture and duplicate/bounded update-envelope parsing. This is portable Core evidence, not native coordinator proof. |
| Finding lifecycle/history tests | A later targeted run passed 22 XCTest cases for bounded history, identity/revisions, lifecycle/comparison and deletion of baselines. Native persistence/deletion behavior is checked separately. |
| KB restore hardening and publisher interoperability | A later targeted run passed 22 KnowledgeBaseTests plus 1 real publisher interoperability test, 23 total. Exact accepted raw-manifest identity is required for KB restoration; ambiguous signer IDs and same-sequence changes are rejected. A legacy high-water mark without its manifest fingerprint cannot authorize restoration. |
| Publisher interoperability scope | The actual CLI signed all seven artifact families with unique temporary OpenSSL Ed25519 keys, and the Swift verifiers accepted the correct bytes. The test compares canonical bytes and rejects payload/signature tampering and a genuinely re-signed rule metadata change at the same sequence. Keys/artifacts are removed; nothing is published. |
| Bundled third-party notices | 1 targeted Core test passed for readable complete bundled upstream notices. This checks included notices, not ownership of every proposed production dataset/service or the account holder's legal identity. |
| Dataset-publisher Python suite | 23 tests passed with real Ed25519 signing/public verification, closed schemas, HTTPS/time/size/version/source-review bounds, sticky revocations, safe private-key handling, preserved existing outputs and sanitized errors. The helper creates local artifacts only. |
| Cloud signing/public-anchor helper suite | The current full workflow passed 111 Python cases, including the 23 publisher tests. Configuration, profiles, archive consistency, public authority maps and cleanup use fixtures/mocked Apple tools; the publisher uses real temporary-key Ed25519. These results do not prove real production profiles, entitlement grants, signing or upload. |
| Native public-anchor parser source | All 11 native parser/real-signature/provider cases passed on each family in run 37396159587. Downloads cannot install a new trusted key. |
| Hosted expanded iPhone/iPad run | [Run 37394131493](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37394131493), commit `b9fa05113fd1b764d302b8d13fd5d3528e437027`, completed successfully. Each family passed 196 Swift package tests and 107 Python tests; all three unsigned edition builds (`FirePrivacy`, `FirePrivacyURL`, `FirePrivacyManaged`) compiled. Each consumer simulator ran 79 native cases: 78 passed, 1 hardware-only protection case skipped, 0 failed; 2 additional UI cases passed. Screenshot capture was skipped on both. |
| Expanded rules/AI/cleanup native validation | [Run 37396159587](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37396159587), commit `a77b57475e87e04baf1fd71597a5fcbcb8e8a55e`, passed both families: 240 package tests, 111 Python tests, all three edition builds, 109 native tests (107 passed, two skipped, zero failed), and two UI tests. Skips are physical-device Data Protection and real guided model generation; the actual model reported Apple Intelligence disabled. The three runtime availability/rejection/fallback cases passed. Screenshots were skipped. |
| Usage comparison native validation | Pending at its own source revision. New private timeline persistence/comparison controls, JSON/event-log import, report binding, Charts and native/UI regressions require matching hosted results. Earlier successful runs do not cover these later additions. |
| Privacy source guard | The current full workflow checked 56 production Swift files. It forbids app-created networking outside the single approved HTTPS worker, plus tracking/web-view APIs. Optional approved requests and OS-managed DNS/filtering exist; this is not a claim that the whole app never networks. A structural check is not a runtime traffic trace. |
| Required-reason API audit | Current rotation durability code uses `Darwin.fstat` for owned app-container file/directory metadata. The app manifest declares FileTimestamp reason `C617.1`; the current Apple text and source-path audit are in [REQUIRED-REASON-API-AUDIT](REQUIRED-REASON-API-AUDIT.md). Final archive/Xcode privacy reporting and App Store processing remain separate checks. |
| Apple requirement sources | Official Apple sources were retrieved with normal TLS and dated/digested evidence. See [APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md), [base retrieval record](APPLE-SOURCE-VERIFICATION.json) and [optional-feature/current API record](APPLE-OPTIONAL-SOURCE-VERIFICATION.json). Retrieval is not Apple approval or legal certification. |
| Public policy/support | The GitHub-rendered expanded consumer policy and public issue tracker returned unauthenticated HTTPS 200 on October 6. The later usage-comparison disclosure still needs publication and matching-policy verification before distribution. Standalone `gh-pages` site source exists, but Pages enabling was denied to this integration. |
| Visual direction/screenshots | The owner approved the charcoal/ember concept and flame icon; source styling exists. Earlier MVP demo captures are historical evidence only. Expanded screenshots are deferred, and no new store-ready capture is asserted. |
| Signed archive/upload | Not demonstrated. Team `LYDVWU62G4` is configured; registered IDs/App Group, edition-matching capabilities/profiles, Apple signing credentials, ASC authorization/app record and actual results remain to be verified. HTTP 403 on secret/variable metadata means bindings are unknown, not absent. |

The XCTest counts above are actual executed cases. A separate Swift Testing
runner may print zero Swift Testing cases; it does not replace the XCTest
results. Targeted counts overlap the full suite and must not be added to its
277-case total. Native results cover the named committed revision; subsequent
working-source changes need their own hosted run.

The Linux Swift 6.2.3 archive is SHA-256 pinned and its historical signature was
verified against the official Swift key set and signer fingerprint. Its release
signature was made while the signing key was valid; the toolchain verification
was not disabled.

## Remaining runtime and release checks

- Run the full portable workflow and both native families on the final committed
  source, preserving the revision, logs and result bundles. Verify all included
  editions with the intended public anchors and target/capability configuration.
- Use current physical iPhone/iPad Apple exports to check parsing, evidence,
  history/comparison, retention, export/redaction, consent/revocation and deletion
  failures/recovery. Simulator fixtures are not current real-report compatibility.
- On passcode-protected devices, verify complete file protection, locked-state
  Keychain/report/export access, backup exclusion and key-rotation recovery.
  The hardware-only protection test is intentionally skipped on simulators.
- Verify actual Safari/DNS activation, expected configuration readback, coverage,
  stale/revoked dataset handling and removal failure/remediation. Model readiness,
  approved request cancellation, TLS/pinning and endpoint behavior need actual
  supported device/service testing. URL/managed editions also need their real
  Apple capability/service or managed deployment prerequisites.
- Complete accessibility, iPhone/iPad layout and working feature controls before
  matching screenshots. Publish the matching policy and accurate operator/data
  disclosures; complete the actual privacy, age, export, trader and legal fields.
- Produce a signed archive/upload with real authorized material, inspect ASC
  processing, then finish physical QA before App Review submission. An initial
  TestFlight upload can supply the installable QA build. Upload, review submission,
  approval and public release are distinct outcomes.

## Reproduce and continue

```sh
bash scripts/install-swift-linux.sh
bash scripts/check-portable.sh
```

On hosted macOS/Xcode 26.2, unsigned edition builds and consumer simulator tests
run through:

```sh
bash scripts/build-ios.sh
bash scripts/test-ios.sh iphone
bash scripts/test-ios.sh ipad
```

For the cloud signing/upload workflow, secure material and selected-edition
requirements, follow [CLOUD-RELEASE](CLOUD-RELEASE.md). The Linux chat session
continues independently of GitHub's hosted Mac runner. Finish the concrete
[release checklist](RELEASE-CHECKLIST.md) using actual Apple/device results.
