# Apple account registration

Prepared October 6, 2026. The user authorized registration under team
`LYDVWU62G4` and subsequently reported creating the App Store Connect record
after receiving the main bundle ID below. Record ID: **6819892589**.
[Owner-provided app version page](https://appstoreconnect.apple.com/apps/6819892589/distribution/ios/version/inflight).
This is owner confirmation; no authenticated Apple API/browser verification has
occurred in this cloud session. Safari/App Group registration, capabilities and
distribution-profile grants remain unconfirmed. The earlier owner-relayed Hermes
report says Xcode 26.5 and a valid Apple Distribution identity for this team are
on the Mac, but its local profiles belong to another app, no ASC `.p8` was found,
and `gh secret list` was empty. Hermes did not add Actions secrets. This is an
external report, not authenticated verification by this cloud session.

Use the [Hermes signing handoff](HERMES-SIGNING-HANDOFF.md) for the exact local
preparation order, target grants and secure Secret mappings.

| Item | Consumer value |
| --- | --- |
| Main explicit App ID | `com.firesoftwaresolutions.FirePrivacy` (owner-confirmed) |
| App Store Connect app ID | `6819892589` (owner-reported) |
| Safari explicit App ID | `com.firesoftwaresolutions.FirePrivacy.SafariContentBlocker` (expected; registration unverified) |
| Shared App Group | `group.com.firesoftwaresolutions.FirePrivacy.protection` (configured default; registration unverified) |
| Team | `LYDVWU62G4` |
| App Store app name | Fire Privacy, subject to availability |
| Platform | iOS, with the existing universal iPhone/iPad target |

The release workflow now uses the owner-confirmed main ID as its consumer
fallback, so the GitHub variable is optional for this consumer app. Existing
Actions identifier overrides take precedence. URL/managed editions still need
their separately registered ID; no fallback is inferred for them. Apple app ID
`6819892589` is a numeric record reference, not a bundle identifier or credential.

The Safari suffix comes from `scripts/release-validation.py`; use the same base
and actual registered group in the build. The app needs App Groups and the
Network Extensions **DNS Settings** capability. Safari needs App Groups. Assign
the shared group to both explicit IDs. Consumer distribution includes no URL or
managed provider targets.

## Shared cloud browser

This cloud instance has Chromium and the official shared-browser launcher, but
activation failed with `NODE_REPL_AUTH_TOKEN must be provisioned before browser
activation`. Its browser management socket is absent and no browser-control tool
is exposed. This is a platform provisioning prerequisite, separate from Apple
authentication. A desktop Apple tab does not provide this cloud agent access.
No shared sign-in window or authenticated Apple session has been created.

Enable the platform's shared browser capability before attempting activation
again; do not invent a runtime token or ask for one in chat. Once available, the
user signs in and completes MFA themselves, then the agent can continue the
authorized registration through supported browser tools. Browser profiles,
cookies and credentials are private runtime state; use those APIs, never inspect
or copy profile files. Supported file exchange is `/workspace/shared`.

## Read-only cloud account check

[Apple account preflight](https://github.com/Ununp3ntium115/FirePrivacy/actions/workflows/apple-account.yml)
uses the existing secure `ASC_PRIVATE_KEY_BASE64`, `ASC_KEY_ID` and `ASC_ISSUER_ID`
bindings in GitHub Actions environment `app-store`. It checks binding presence,
signs a five-minute ES256 token, and reads the exact consumer/Safari IDs and
capability types. It never registers, edits or uploads anything. Missing binding
names and closed error codes are logged; keys, tokens and raw Apple responses
are not. An App ID prefix match is not proof of team membership or agreements.
Capability types do not prove the actual App Group association or `dns-settings`
entitlement; inspect matching distribution profiles before signing.

Run it against the intended base ID. A key that uploads builds may lack
Provisioning access: Apple requires an authorized **team API key** for
Provisioning endpoints; individual keys cannot use them. Supply missing values
through GitHub Actions Secrets, never chat or normal workflow inputs.

Historical [preflight 37403403756](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37403403756)
passed all 18 token/request-boundary cases on macOS, then reported the three ASC
bindings unavailable before any Apple API request.

Latest consumer upload-mode [run 37847693882](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37847693882)
on October 8 at `f976de1` passed 43 signing-helper cases in 0.481 seconds and
resolved the owner-confirmed main ID. The same seven signing/API bindings were
unavailable. Credential preparation, signing, archive/export and upload were
skipped; cleanup succeeded. This run did not produce an IPA or contact Apple
for a signed upload. Exact Secrets names are in [CLOUD-RELEASE](CLOUD-RELEASE.md).

Multiple October 8 read-only probes with uploaded/pasted candidate keys parsed
and signed as P256 over verified TLS but returned HTTP 401 `NOT_AUTHORIZED`,
`authenticated=false`. Team and Individual JWT forms against a fixed app GET
both failed; a later differently named upload also failed using its exact
filename-derived ID and supplied issuer. Independent clock checks were aligned.
No account mutations occurred; controlled temporary signing material and the
later owned downloaded copy were cleaned. Real identifiers, issuer values and
key material are excluded from these public records. Matching usable ASC
credentials and team authority remain unverified.

The uploaded profile reports the expected consumer Safari target, team, shared
group, App Store distribution and unexpired status. No DNS entitlement is
expected for Safari. CMS cryptographic integrity was inspected without Apple
chain trust; mandatory macOS trust/profile checks remain outstanding. A
separate matching main profile and distribution P12/private key are still needed.

All four name-only repository/environment Secrets and Variables list calls
returned HTTP 403. Current bindings cannot be inventoried by this integration;
do not infer absence or claim they were added. Fresh run 37847693882 directly reported seven unavailable bindings to its
runner, with no aggregate extension-profile alternative. Stored values remain
unknown; the fresh runner result establishes runtime availability at that run.

Apple's [JWT guide](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
shows a ten-character Key ID example without mandating that length. Copy the
Key ID unchanged from the same team key that supplied the private key and
Issuer ID. Local API Key ID validation now accepts bounded 1–64 unchanged
ASCII alphanumeric characters; do not pad, truncate, change case or substitute
a team ID to pass validation. Team/App ID prefix validation remains ten
characters, and issuer/profile/certificate/native gates remain unchanged. The
syntax correction alone does not establish valid authentication. The targeted
65 helper cases and full 145-case Python release suite passed; genuine
generated-key JWT/mocked-request tests check preservation, filename handling,
cleanup and unsafe-ID rejection. See [VALIDATION](VALIDATION.md). These results
do not establish real Apple authentication, and the app/Core/target/dependency
source still matches the passing native run.

Latest unsigned native [run 37548308269](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37548308269)
at `48e8c45` passed on iPhone and iPad, including the deletion UI regression.
These results do not supply signing credentials or demonstrate active
Safari/DNS/App Group grants. See [VALIDATION](VALIDATION.md).

## Supported registration routes

Apple's official OpenAPI **v4.5**, retrieved with normal TLS on October 6, 2026,
documents `POST /v1/bundleIds`, `POST /v1/bundleIdCapabilities` and
`POST /v1/profiles` (`IOS_APP_STORE`, matching bundle and certificate).
It does **not** document App Group creation/assignment or a `POST /v1/apps` for
creating the App Store app record. Those require Apple browser/Xcode interfaces.
A coarse Network Extensions capability switch is not proof of the DNS Settings
subtype. No registrations have been performed by this session.

Once authorized account access exists:

1. Verify the intended team, active membership and agreements. Inspect existing
   IDs before creating missing explicit app/Safari IDs.
2. Register the shared App Group and assign it to both IDs. Enable DNS Settings
   for the main app and inspect the resulting entitlements.
3. Verify the existing owner-reported app record `6819892589` uses the matching
   main ID and intended actual account fields. Do not create a duplicate record.
4. Export the reported Apple Distribution identity, including its private key,
   as a password-protected P12. Obtain `IOS_APP_STORE` profiles for the exact
   main/Safari IDs, matching certificate and group/capabilities; the reported
   other-app profiles cannot be used. Locate an authorized ASC team `.p8` or
   create/download a team API key if none is available. Bind the P12/password,
   both profiles and ASC key/ID/issuer securely in Actions, then validate them.
   Apple's certificate API cannot recover a missing private key.
5. Set the actual registered App Group in Actions variables if it differs from
   the configured default. The confirmed consumer main ID already has a
   fallback; `APP_BASE_BUNDLE_ID` is an optional registered override for it.
   Run the checked [archive/upload workflow](CLOUD-RELEASE.md) in upload mode.
   Verify processing/TestFlight availability; public release requires physical
   QA and App Review.

Official sources: [OpenAPI specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip),
[team API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api),
[App Group registration](https://developer.apple.com/help/account/identifiers/register-an-app-group),
[group assignment](https://developer.apple.com/help/account/identifiers/enable-app-capabilities#enable-app-groups),
[new App Store app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app),
[App ID prefixes](https://developer.apple.com/library/archive/technotes/tn2311/_index.html).
