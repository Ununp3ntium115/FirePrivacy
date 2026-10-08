# Complete the existing Apple signing setup

The owner earlier relayed Hermes's local Mac inspection: a valid Apple Distribution
identity exists for team `LYDVWU62G4`, but the inspected profiles belong to a
different app, no App Store Connect `.p8` was found, and no GitHub Secrets were
added. This cloud session has not inspected those local files. Keep the build
and upload on GitHub Actions; use the Mac for private credential preparation.

The October 8 cloud upload preflight
[37847693882](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37847693882)
at `f976de1` passed 43 signing-helper cases in 0.481 seconds, then again reported
seven missing signing/API bindings. Signing/archive/export/upload were skipped
and cleanup succeeded. Multiple uploaded/pasted P256 candidates signed
successfully over verified TLS but read-only Apple calls returned HTTP 401
`NOT_AUTHORIZED`, `authenticated=false`. Team and Individual JWT fixed-app GETs
both failed, including a later filename-derived candidate. Clock checks aligned;
no account mutations occurred and controlled temporary material/owned copies
were cleaned. No real identifier, issuer or key material is recorded here.

An uploaded profile reports the expected Safari target/team/shared group,
App Store distribution and unexpired status; Safari does not need DNS grants.
Its CMS cryptographic integrity was inspected without establishing Apple chain
trust. macOS Apple trust/profile verification remains mandatory; the separate
main profile and distribution P12/private key are still required.

All four name-only repository/environment Secrets/Variables list calls returned
HTTP 403. This session cannot confirm current bindings or infer their absence;
fresh run 37847693882 directly reports the same seven bindings unavailable to
its runner, with no aggregate extension-profile alternative. File upload here
is not an Actions Secret write.

Confirm the exact matching Key ID and Issuer ID for the same authorized team
key/private key, and confirm the intended team. Copy values unchanged into
secure settings; do not include them in a public report. Apple's JWT guide
uses a ten-character Key ID example without imposing that length. Local Key ID
validation now accepts bounded unchanged ASCII alphanumeric input of 1–64
characters; the ten-character team/prefix and issuer/profile/certificate/native
checks remain. The correction does not establish authentication for the
rejected candidates. The full 145-case Python helper suite passed with real
generated-key JWT/mocked-request, filename/cleanup and unsafe-ID checks; app/
Core source, targets and dependencies remain unchanged from the passing native
run. See [Apple registration](APPLE-REGISTRATION.md) and
[validation](VALIDATION.md) for source and evidence.

## Exact consumer requirements

| Target | Explicit bundle ID | Required profile grants |
| --- | --- | --- |
| App | `com.firesoftwaresolutions.FirePrivacy` | App Group below; Network Extension `dns-settings` |
| Safari | `com.firesoftwaresolutions.FirePrivacy.SafariContentBlocker` | Same App Group; no Network Extension entitlement |

Shared App Group: `group.com.firesoftwaresolutions.FirePrivacy.protection`.
Existing owner-reported App Store Connect record: **6819892589**. Reuse it.

The actual source grants are in [the consumer entitlements](../Apps/FirePrivacyApp/FirePrivacy.entitlements)
and [the Safari entitlements](../Extensions/SafariContentBlocker/FirePrivacy.entitlements).
Both profiles must be distinct, unexpired iOS App Store distribution profiles
for the exact targets and team, authorizing the same existing distribution
certificate. Development, ad hoc and another app's profiles cannot satisfy
these checks. A legacy App ID prefix may differ from the team ID; do not edit
Apple-signed profiles to force a match.

## Prepare through the owner's authenticated Apple session

1. Have the owner sign in and complete MFA in the supported local browser.
   Inspect the existing identifiers before creating missing registrations.
2. Register or verify the shared group and assign it to **both** IDs. Verify the
   main ID grants DNS Settings. A generic Network Extensions switch is not
   proof that the generated profile grants `dns-settings`.
3. Obtain the missing main **App Store Connect / iOS App Store** distribution
   profile and validate the supplied Safari profile through macOS Apple trust
   checks. Create or renew a profile only if needed. Both must select the same
   existing valid distribution certificate and match the exact target, signed
   entitlements, team, expiry and certificate association. Preserve the other
   app's profiles.
4. Export the existing Apple Distribution identity **with its private key** as
   a password-encrypted `.p12` using Keychain Access. A `.cer` alone cannot
   sign. Export only the intended identity; no new CSR or certificate is needed
   if that identity and private key are usable.
5. Reuse a suitable available App Store Connect team API key, or have an Admin
   generate an appropriately authorized Team Key under **Users and Access →
   Integrations → App Store Connect API**. Record its Key ID and Issuer ID and
   download the `.p8` immediately: Apple permits one download and keeps no copy.
   Use its original download filename to help identify the matching Key ID,
   then confirm that ID and Issuer ID against the same authorized team key row;
   renaming a file cannot establish that association. Xcode does not create this key. Upload authorization and provisioning access
   are separate; individual API keys cannot use Provisioning endpoints.

## Store the existing workflow bindings securely

Use the authenticated local GitHub CLI or repository Actions Secrets UI for
`Ununp3ntium115/FirePrivacy`. Keep file contents/passwords out of chat, command
arguments, shell tracing, GitHub Actions variables, source and screenshots. The owner
can give Hermes local file paths; this cloud workspace cannot read Mac paths.
Use hidden local input for passwords and pipe secret values into `gh secret set`
instead of printing them. Preserve existing unrelated secrets.

| GitHub Actions Secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64 contents of the exported `.p12` |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Export password, unchanged |
| `APPLE_PROVISION_PROFILE_BASE64` | Base64 contents of the app's App Store profile |
| `APPLE_SAFARI_PROVISION_PROFILE_BASE64` | Base64 contents of the Safari App Store profile |
| `ASC_PRIVATE_KEY_BASE64` | Base64 contents of the `.p8` |
| `ASC_KEY_ID` | Key ID, unchanged |
| `ASC_ISSUER_ID` | Issuer ID, unchanged |

Verify names only with `gh secret list --repo Ununp3ntium115/FirePrivacy`.
Report which names were configured and any sanitized validation error; do not
return values, private files or passwords to this chat. Base64 is encoding,
not encryption, and those contents still belong in Secrets.

Then this cloud agent can run **Signed App Store build**, `main`, `consumer`,
`upload`, with the intended version and an unused build number. The workflow
checks binding presence and identifiers, validates actual credentials/profiles,
tests both families, signs, validates the archive and uploads. Do not spoof a
GitHub runner or bypass those gates to run signing preparation locally.
Upload goes to App Store Connect; processing, physical QA and App Review
remain separate from upload success.

See [Apple registration](APPLE-REGISTRATION.md), [cloud release](CLOUD-RELEASE.md)
and [validation](VALIDATION.md) for official sources and actual run evidence.
