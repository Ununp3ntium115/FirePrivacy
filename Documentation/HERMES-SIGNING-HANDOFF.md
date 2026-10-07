# Complete the existing Apple signing setup

The owner relayed Hermes's local Mac inspection: a valid Apple Distribution
identity exists for team `LYDVWU62G4`, but the inspected profiles belong to a
different app, no App Store Connect `.p8` was found, and no GitHub Secrets were
added. This cloud session has not inspected those local files. Keep the build
and upload on GitHub Actions; use the Mac for private credential preparation.

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
3. Generate and download two **App Store Connect / iOS App Store** distribution
   profiles, one per exact bundle ID, selecting the same existing valid
   distribution certificate. Check their Apple-signed entitlements, team,
   expiry and certificate association. Preserve the other app's profiles.
4. Export the existing Apple Distribution identity **with its private key** as
   a password-encrypted `.p12` using Keychain Access. A `.cer` alone cannot
   sign. Export only the intended identity; no new CSR or certificate is needed
   if that identity and private key are usable.
5. Reuse a suitable available App Store Connect team API key, or have an Admin
   generate an appropriately authorized Team Key under **Users and Access →
   Integrations → App Store Connect API**. Record its Key ID and Issuer ID and
   download the `.p8` immediately: Apple permits one download and keeps no copy.
   Xcode does not create this key. Upload authorization and provisioning access
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
