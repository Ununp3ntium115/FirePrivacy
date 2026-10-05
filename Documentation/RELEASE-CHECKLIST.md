# Release checklist

All unchecked items are pending. Use the actual command logs and App Store
Connect statuses as evidence. A native source build, passing test run, signed
archive, uploaded/processed build, review submission, approval, and public
release are separate results.

## Build and product

- [x] Current-instance Linux/core build and 34 tests pass; see `VALIDATION.md`.
- [x] Current-instance portable project, asset, plist, and privacy checks pass.
- [x] Hosted Mac CI uses Xcode 26.2 and iOS/iPadOS 26.2 SDK; verify current Apple minima
      using [APPLE-REQUIREMENTS.md](APPLE-REQUIREMENTS.md).
- [x] `scripts/build-ios.sh` succeeds on both hosted Mac jobs at `d44a996`.
- [x] `scripts/test-ios.sh iphone` and `scripts/test-ios.sh ipad` succeed at `d44a996`;
      the separate hardware-protection test is skipped in Simulator.
- [ ] Final local lifecycle/accessibility/release-helper changes pass a new native run.
- [ ] A real Apple-generated App Privacy Report from a current iPhone imports.
- [ ] A real Apple-generated App Privacy Report from a current iPad imports.
- [ ] No-activity, unsupported-record, malformed, oversized, truncated,
      non-UTF-8, and canceled-import flows give accurate outcomes.
- [ ] Demo, populated-report, empty-report, and error screens work in portrait,
      landscape, iPad split view, and compact widths.
- [ ] Export produces the intended readable file, the system share sheet works,
      and temporary exports are cleaned up after use or relaunch.
- [ ] Delete removes the stored report and Keychain key, including after restart.
      It accurately explains that the original and already shared files remain.
- [ ] The Keychain/encryption/file-protection behavior works on a physical device.
- [ ] On passcode-protected physical iPhone and iPad, the report, device-only
      Keychain key, and temporary exports respect the locked state and reopen
      correctly after unlock. Verify complete file-protection metadata on those
      devices; simulator filesystems cannot validate hardware Data Protection.
- [ ] Device backup behavior matches the policy; stored report/key are not
      accidentally backed up or synced to iCloud.
- [ ] No imported report content appears in production logs or crash annotations.
- [ ] Release network inspection confirms no app-created request during demo,
      import, browsing, delete, and export preparation.
- [ ] VoiceOver names/values/order work; 200%+ text does not hide controls;
      meaningful color has a text/shape equivalent; contrast and reduced motion
      work. Record only verified accessibility labels in App Store Connect.

## Account, legal, and privacy

- [ ] Apple Developer team `LYDVWU62G4` is accessible to the signing account.
- [ ] Membership and relevant current Apple agreements are active/accepted.
- [ ] The final bundle identifier is registered and matches project, signing
      profile, App Store Connect record, archive, and export configuration.
- [ ] Actual seller identity, copyright holder, app/icon/code/asset rights, and
      review contact are accurate. No placeholder personal or business data.
- [ ] Apple's standard EULA is used, or any chosen custom EULA is valid for the
      selected rights holder and territories.
- [ ] Account enrollment type and the applicability of App Review 5.1.1(ix) to
      the optional local report workflow are reviewed; no unverified LLC claim.
- [ ] Export compliance questionnaire matches Apple CryptoKit/Keychain-only
      encryption; record the applicable exemption and any documentation needed.
- [ ] Trader/non-trader status is declared in App Store Connect, including if
      distribution excludes the EU. For EU trader distribution, the required
      contact information is verified and availability matches that decision.
- [ ] Price, territories, age-rating questionnaire, category, and content rights
      answers describe the actual build.
- [ ] A public HTTPS privacy policy and support page are deployed and return 200
      without login, from an ordinary network outside this workspace.
- [ ] App Store Connect URLs match the deployed pages; the in-app policy/link
      works and matches the source policy.
- [ ] Support route is reachable by an ordinary user; private reports are not
      requested in public issues. No unverified email/domain is displayed.
- [ ] App Privacy answers are reviewed against the final app and dependencies.
- [ ] `PrivacyInfo.xcprivacy` parses, is bundled, and agrees with used APIs;
      generate/review Xcode's privacy report and final processing warnings.
- [ ] Any third-party SDK or asset change has a documented privacy/license review.

## App Store Connect submission

- [ ] App record, primary language, SKU, and final name are configured.
- [ ] Version/build number are unique for upload; Release configuration is used.
- [ ] Review the draft metadata in `AppStore/` against the exact shipping build.
- [ ] Current required iPhone and iPad screenshot classes have actual-build
      screenshots with synthetic data. Text, orientation, cropping, and privacy
      are checked; no conceptual render is submitted as a screenshot.
- [ ] TestFlight install and launch succeed on physical iPhone and iPad;
      import/export/delete and offline use pass on the uploaded build.
- [ ] Signed archive succeeds and passes local archive validation.
- [ ] Upload to App Store Connect succeeds; processing finishes without blockers.
- [ ] Select the processed build in the version record; all required fields and
      declarations are complete; add review notes and contact details.
- [ ] Submit for review and record the exact App Store Connect submission status.
- [ ] Address any App Review issue with verified behavior and accurate metadata.
- [ ] Release only after the selected release option and Apple status allow it;
      verify the public store listing and download before reporting it live.

## Evidence log

Record evidence, not an assumed pass. Do not attach a real report, credentials,
private key, provisioning profile, device identifier, or private personal data.

| Check | Build/version | Date | Evidence/result |
| --- | --- | --- | --- |
| Core tests | Candidate 1.0 | October 5, 2026 | 34 XCTest cases, 0 failures; portable script exit 0 |
| Apple-platform build and tests | `d44a996`, candidate 1.0 | October 5, 2026 | Both native build/test steps passed in run 37378242655; hardware protection skipped in Simulator; final local changes await rerun |
| Real report compatibility | Pending | Pending | OS version and anonymized result |
| Storage/delete/backup/device tests | Pending | Pending | Physical-device result |
| Public policy/support reachability | Pending | Pending | Exact deployed HTTPS URLs/status |
| Current Apple requirements | Pending | Pending | Retrieval date and requirement text |
| Signing/archive/upload | Pending | Pending | Archive result and processing status |
| App Review/release | Pending | Pending | Actual App Store Connect state |
