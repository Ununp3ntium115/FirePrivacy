# Continue this session in the cloud

This chat and `/workspace/FirePrivacy` run in the cloud. Keep the same chat URL
to continue; opening it in another browser or desktop view does not transfer the
workspace. GitHub preserves committed source, not uncommitted files or chat
context.

The source is on `main`, merged in
[PR #2](https://github.com/Ununp3ntium115/FirePrivacy/pull/2), with the expanded
analysis architecture, encrypted history, supplied-usage comparisons,
coordinator, three edition targets and cloud release helpers.

Latest [native run 37548308269](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548308269)
passed at `48e8c45e31b03bfac5c5a65034595c9c86193825`. Each family passed 277
Core and 137 Python cases, all three unsigned builds and 3 UI cases. Native
results differ by simulator: iPhone 110 passed/2 skipped, iPad 109 passed/3
skipped, both out of 112 with zero failures. The iPad deletion/navigation
regression passed after a test-only wait fix. Exact evidence and physical/model
limits are in [VALIDATION](VALIDATION.md). Final store screenshots have not yet
been captured.

The owner reports creating
[App Store Connect app 6819892589](https://appstoreconnect.apple.com/apps/6819892589/distribution/ios/version/inflight)
for `com.firesoftwaresolutions.FirePrivacy`. The consumer release workflow uses
that main ID by default; registered Actions overrides take precedence. Safari
and App Group registration/profile grants remain unverified. Team
`LYDVWU62G4` is configured, but this cloud session has not authenticated to Apple.
URL-filter/managed editions require their own registered IDs and separate
capability/operator/deployment conditions.

[GitHub Actions](https://github.com/Ununp3ntium115/FirePrivacy/actions) supplies
macOS/Xcode without moving this chat to a local Mac. The registered
[Signed App Store build](https://github.com/Ununp3ntium115/FirePrivacy/actions/workflows/release.yml)
workflow supports archive and upload modes. Latest consumer upload attempt
[37548094861](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548094861)
at `0f8d244` passed 39 signing-helper tests and resolved the main ID, then
reported seven unavailable signing/API bindings. It produced no signed archive,
IPA or upload.

The newer owner-relayed Hermes report says the Mac has Xcode 26.5 and a valid
Apple Distribution identity for `LYDVWU62G4`, but its local profiles belong to
another app, no ASC `.p8` was found, and `gh secret list` was empty. Hermes did
not add Actions secrets. This is an external report; the cloud session has not
inspected those Mac materials or run another upload.

Export that identity as a password-protected P12, obtain matching main/Safari
App Store profiles and locate or create an authorized ASC team API key. Populate
the seven Secrets names in [CLOUD-RELEASE](CLOUD-RELEASE.md), then rerun consumer
upload with the intended version/unused build number. Keep credential contents
outside chat/source. The latest actual runner check still establishes seven
unavailable bindings; no secrets or usable profiles are asserted configured.

[APPLE-REGISTRATION](APPLE-REGISTRATION.md) covers the owner-reported record and
remaining registration checks. Shared-browser activation was blocked by missing
platform `NODE_REPL_AUTH_TOKEN`; this agent cannot control the owner's local
Apple tab. No runtime token, password or browser profile should be shared in
chat. The read-only account probe also stopped before Apple requests because
its three ASC bindings were unavailable at that run.

After secure bindings are available, run the checked cloud upload and verify
Apple processing/TestFlight availability. An initial TestFlight upload can
supply physical QA. Finish actual iPhone/iPad report/usage import, evidence,
exports/deletion, Safari/DNS activation/removal, supported model behavior,
accessibility, locked-state and backup checks before App Review. Complete
matching policy/store declarations and final screenshots. No signed upload,
review approval or public App Store release is asserted yet.
