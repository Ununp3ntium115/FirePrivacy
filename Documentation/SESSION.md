# Continue this session in the cloud

The chat and `/workspace/FirePrivacy` workspace run in the cloud. Keep the same
chat URL in a browser to continue. If Orca Desktop can open it, that is another
view; no session-transfer integration has been verified. Cloning/downloading
source does not transfer this workspace or conversation.

The durable app source is on `main`, merged in [PR #2](https://github.com/Ununp3ntium115/FirePrivacy/pull/2).
It includes the expanded core architecture,
three edition targets, coordinator/storage integration, policies and cloud
release helpers. Source existence does not prove native availability. GitHub
preserves commits, not uncommitted workspace files or chat context.

The owner reports the main App Store Connect record is now created:
[app 6819892589](https://appstoreconnect.apple.com/apps/6819892589/distribution/ios/version/inflight),
using `com.firesoftwaresolutions.FirePrivacy`. The release workflow uses that
confirmed consumer ID by default while preserving registered Actions overrides.
Safari/App Group registration, profile grants and signing/upload credentials
remain separate prerequisites; the cloud session has not authenticated to Apple.

Current portable/native results and their exact source revisions are tracked in
[VALIDATION](VALIDATION.md). Final run 37401191529 passed both families at
`6f66780` (277 Core / 111 Python; all three builds;109 native passes/3 skips and 3 UI
passes per family). Merge commit `c66f2a5` has the identical tree. Actual device
controls, signing, upload and review remain separate. Screenshot work is
paused while the requested underlying functionality is engineered and validated.

[GitHub Actions](https://github.com/Ununp3ntium115/FirePrivacy/actions) supplies
hosted macOS/Xcode runners. [CLOUD-RELEASE](CLOUD-RELEASE.md) describes selected
edition profiles, secure signing settings and archive/upload execution without
moving this chat to a local Mac. Signed App Store build is registered/active
with archive/upload choices. Its actual archive preflight 37402216199 stopped
on empty `APP_BASE_BUNDLE_ID` before credentials/signing; no upload is asserted.

Team `LYDVWU62G4` and provisional base ID
`com.firesoftwaresolutions.FirePrivacy` must match real registered identifiers,
profiles, App Group and App Store Connect records. Use the consumer edition for
ordinary Safari/DNS release; the URL-filter and managed editions require their
own capability/operator/deployment prerequisites. Keep signing and API-key
material in secure settings, outside chat/source. HTTP403 metadata access means
existing secret bindings are unknown, not absent.

[APPLE-REGISTRATION](APPLE-REGISTRATION.md) describes the authorized Apple account
setup. The official shared-browser launcher was found, but activation failed
because the platform has not provisioned `NODE_REPL_AUTH_TOKEN`. No shared
sign-in window exists yet; the local Apple tab is not accessible here. Enable
the platform browser capability rather than sharing passwords or runtime tokens.

Account [preflight 37403403756](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37403403756)
passed its 18 helper tests on macOS, then reported all three ASC bindings missing
in environment `app-store`. API fallback is blocked too; no Apple request or
registration was made. Subsequent native run 37403396390 passed both families
at `a42b009`, including 277 Core/129 Python and 109 native passes/3 skips plus
3 UI passes per family. The app/runtime source has not changed since that run.

The upload workflow now checks all required bindings before identifier
validation or credential preparation. Full Python tooling passes 137 tests.
Actual consumer upload-mode [run 37540319978](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37540319978)
passed all 39 signing-helper cases on macOS, then reported eight missing
bindings: registered base ID, distribution P12/password, app/Safari profiles,
and the three ASC bindings. Exact names and secure setup are in
[CLOUD-RELEASE](CLOUD-RELEASE.md). No signing, archive or upload occurred. Browser
token/socket/control tools are still absent; a desktop Apple tab is not shared
with this cloud agent. Resume from the real settings rather than invented IDs
or guessed credentials.

An initial signed TestFlight upload can precede physical QA and supplies the
installable build. Finish real iPhone/iPad report import, evidence/export/delete,
protection activation/removal, advisor availability, accessibility, locked-state
and backup checks before final App Review. Simulator results cannot establish
hardware Data Protection. Revised public policy/metadata must match that build.
