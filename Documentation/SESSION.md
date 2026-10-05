# Continue this session in the cloud

The Codex chat and `/workspace/FirePrivacy` workspace run in the cloud. Use
the same chat URL in a browser tab to continue this conversation. If Orca
Desktop can open that web session, it is another view of the same chat;
there is no verified Orca integration that can transfer a running session.
Downloading or cloning the repository is useful for a local copy but does
not transfer this cloud workspace or its conversation.

The durable source handoff is [draft pull request #2](https://github.com/Ununp3ntium115/FirePrivacy/pull/2),
branch `codex/fireprivacy-app-mvp`. Keep that link with the chat URL. The
branch includes the native iPhone/iPad app, approved charcoal-and-ember
design, privacy documentation, and release helpers. GitHub stores committed
source; it does not preserve uncommitted cloud files or chat context.

GitHub authentication temporarily failed with HTTP 401 and has now recovered.
The cloud signing workflow and final lifecycle/accessibility corrections were
prepared locally after the approved-design push. Check `git status` and
`git log origin/codex/fireprivacy-app-mvp..HEAD` before assuming the public PR
contains every change. If access fails again, refresh the existing platform GitHub connection; do
not request or paste a personal token.

[GitHub Actions](https://github.com/Ununp3ntium115/FirePrivacy/actions) runs
Apple builds on hosted Macs. Linux runs the portable Swift analysis tests;
Apple builds need Xcode on a Mac runner. This keeps your development and
release execution cloud based. See [cloud release instructions](CLOUD-RELEASE.md)
for the secure signing setup and the manual build/upload workflow.

Apple Developer team: `LYDVWU62G4`. The provisional bundle ID in the source
is `com.firesoftwaresolutions.FirePrivacy`; confirm or replace it with the
registered identifier and matching App Store Connect app record. Keep
signing files and API keys in GitHub Actions secrets, outside this chat and
the repository. The workflow cannot use a browser login from another device.

The current observed check results and remaining physical-device/release
requirements are recorded in [VALIDATION.md](VALIDATION.md) and
[RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md).
