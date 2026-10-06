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
registration was made. The full Python release-tool suite now passes 129 tests.

An initial signed TestFlight upload can precede physical QA and supplies the
installable build. Finish real iPhone/iPad report import, evidence/export/delete,
protection activation/removal, advisor availability, accessibility, locked-state
and backup checks before final App Review. Simulator results cannot establish
hardware Data Protection. Revised public policy/metadata must match that build.
