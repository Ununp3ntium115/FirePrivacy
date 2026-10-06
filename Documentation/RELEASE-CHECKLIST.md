# Expanded implementation release checklist

Unchecked items remain pending. Source, portable tests, native SDK builds,
signed archives, upload/processing, TestFlight QA, review approval and public
release are separate results. Earlier MVP native results do not validate the
expanded architecture. Screenshots are paused until functionality is verified.

## Current evidence

- [x] Final portable source passed 277 Core XCTest and 111 cloud-release Python
      cases on October 6; project/manifests/privacy guard passed. See
      [VALIDATION](VALIDATION.md) for exact native revisions and later results.
- [x] Official current Apple requirements and optional-feature/usage documentation
      were retrieved with normal TLS; see [APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md)
      and [USAGE-COMPARISON](USAGE-COMPARISON.md).
- [x] Matching expanded consumer policy, including usage comparisons, is published
      on gh-pages. GitHub-rendered policy/support routes returned HTTPS 200.
- [x] Expanded rules/AI/cleanup checkpoint `a77b574` passed all three edition builds
      and both consumer simulator families. Later usage source needs its own run.
- [x] Final source `6f66780` passed all three native edition builds and consumer
      storage/coordinator/UI tests on both families in run 37401191529.
- [x] PR #2 merged on main; Signed App Store build is registered/active with
      archive/upload modes. Actual preflight 37402216199 stopped on the empty
      registered-bundle variable before signing. Upload is not demonstrated.

## Actual product and privacy behavior

- [ ] Current real Apple-generated iPhone and iPad reports import correctly.
      Unsupported/malformed/oversized/cancelled cases retain accurate outcomes.
- [ ] Evidence provenance, facts/inferences/uncertainty, dataset status, profile
      relevance, manual audits, score coverage, comparison and absence wording
      match source data. No current-permission/payload/causal/legal claims.
- [ ] Encrypted history, optional source copy, retention quotas, key rotation,
      corrupt/missing-key states and migration work on the native implementation.
- [ ] Session deletion/retention failures are retryable; no decryptable orphan is
      silently omitted from accounting. Late operations cannot repopulate data.
- [ ] Independent disclosure receipts are persisted protected/encrypted. Decline
      leaves local analysis usable; revoke/cancel/version/config/report changes
      invalidate pending approvals and reject stale output.
- [ ] Exact remote preview shows every transmitted field and destination. Test
      HTTPS trust/hostname/date, pin mismatch, redirects, header injection,
      streaming size bounds, expiry/replay, cancellation and revoked completion
      with an authorized synthetic endpoint. No raw/stable report identifiers
      escape the minimized advisor DTO. No automatic cloud fallback.
- [ ] Dataset tamper/schema/semantic/expiry/downgrade/revocation checks reject
      updates and preserve valid state. Real publisher keys, endpoint/retention,
      citations/licenses and signed revocation operations are documented.
- [ ] Model availability/fallback is truthful; invalid output cannot add facts,
      IDs/actions/commands or change decisions. Test inference on an eligible
      physical Apple Intelligence device before advertising that support.
- [ ] Full/redacted JSON/CSV/Markdown exports, diagnostics and share-sheet cleanup
      work. Redaction is not advertised as anonymity. External copies are disclosed.
- [ ] Generic reminders require consent and OS permission and contain no activity.
- [ ] Delete-all removes private files/key and retries owned OS removal after
      restart from the feature-name-only queue. No false completed-removal state.
- [ ] Production network inspection shows no app request on local analysis,
      imports, history, deletion or export preparation. Optional destinations
      agree with dynamic disclosures/event history; no payload/token logging.
- [ ] Physical passcode-protected iPhone/iPad verify locked-state key/report/
      export behavior, complete protection, backup exclusion and no iCloud sync.
- [ ] Working expanded controls/layout/VoiceOver/200%+ text/contrast/reduced
      motion/rotation/split view are verified. Capture actual synthetic screenshots
      only after these flows work; declare only tested accessibility support.

## Consumer Safari and encrypted DNS

- [ ] Registered App Group and consumer+Safari App IDs/profiles/certificate match.
      Main target grants dns-settings; Safari target/embedded resources are valid.
- [ ] Safari rule install, user Settings enablement, local allowances, actual
      enabled state, expired/revoked data, cached-rule reload failure and Settings
      removal work. No claim of universal coverage or autonomous cache expiry.
- [ ] Resolver choice discloses operator, queried names, metadata, logging,
      retention, jurisdiction, blocking/failure behavior and coverage limits.
      Save/enabled/change/removal states match NEDNSSettingsManager on device.
- [ ] The consumer archive contains no URL/managed provider or those capabilities.

## Separate URL-filter / managed gates

- [ ] URL edition: actual iOS 26 device, url-filter-provider capability/profile,
      App Group, signed Apple-format data, live PIR/Privacy Pass/OHTTP resources,
      correct configuration identity and actual running/removal state.
- [ ] URL operator: Apple Identity & Trust registration and relay validation
      completed before any non-development distribution, including TestFlight.
      Actual service/publisher policies, revocations and coverage are disclosed.
- [ ] Managed edition: eligible operator, granted content-filter capability,
      matching provider App IDs/profiles, supported supervised/MDM deployment,
      signed policy and no unauthorized consumer activation or flow retention.
- [ ] Any offered MDM/configuration-profile service meets App Review 5.5 capability,
      eligible-entity, disclosure and restricted-data-use requirements. No VPN
      service/organization requirement is inferred merely from Safari/DNS.

## Account, legal and App Store Connect

- [ ] Active team LYDVWU62G4 membership, current agreements, authorized signing/
      upload roles and exact registered edition IDs/ASC app records are confirmed.
- [ ] Real seller/copyright/review contact, app/icon/code/data/license rights,
      standard/custom EULA and App Review 5.1.1(ix) applicability are resolved.
- [ ] Export answers match the actual native cryptography and any reporting/
      territorial obligations. Plist exemption is not absence of encryption.
- [ ] Trader status/EU contact verification, price/territories, current age-rating
      questionnaire, category and content-rights answers match the actual edition.
- [ ] Revised public policy is published and returns HTTP 200 without login. In-app/ASC
      URLs match it; monitored support and actual review contact are available.
- [ ] App Privacy answers review every enabled/optional endpoint, operator access
      and retention. Optional toggles alone do not exempt data from disclosure.
- [ ] Every shipped app/extension manifest and required-reason/SDK attribution
      agrees with actual APIs; Xcode privacy report and processing are reviewed.
- [ ] Draft AppStore text is replaced with exact verified consumer feature labels;
      no inactive edition or untested native capability is advertised.
- [ ] Exact signed archive and unique version/build pass release validation and
      upload to App Store Connect; Apple processing finishes without blockers.
- [ ] Initial TestFlight install supplies physical QA where needed; finish that
      QA before selecting the final build/metadata for App Review.
- [ ] Actual required iPhone/iPad screenshots use the final binary and synthetic
      data. Review contact/notes/declarations are complete; Add for Review and
      Submit for Review statuses are recorded separately.
- [ ] Review issues are resolved; release selection/status and public listing/
      download are verified before reporting the app live.

Record exact revision/run IDs and statuses in [VALIDATION](VALIDATION.md). Never
attach private reports, keys, profiles, account details or device identifiers as
evidence. GitHub secret/variable metadata HTTP 403 means unknown, not absent; a team
identifier and workflow source do not prove usable signing authorization.
