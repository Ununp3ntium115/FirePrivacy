# Apple account registration

Prepared October 6, 2026. The user authorized registration under team
`LYDVWU62G4` and subsequently reported creating the App Store Connect record
after receiving the main bundle ID below. Record ID: **6819892589**.
[Owner-provided app version page](https://appstoreconnect.apple.com/apps/6819892589/distribution/ios/version/inflight).
This is owner confirmation; no authenticated Apple API/browser verification has
occurred in this cloud session. Safari/App Group registration, capabilities and
distribution profiles remain unconfirmed.

| Item | Consumer value |
| --- | --- |
| Main explicit App ID | `com.firesoftwaresolutions.FirePrivacy` |
| App Store Connect app ID | `6819892589` (owner-reported) |
| Safari explicit App ID | `com.firesoftwaresolutions.FirePrivacy.SafariContentBlocker` |
| Shared App Group | `group.com.firesoftwaresolutions.FirePrivacy.protection` |
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

Actual [preflight 37403403756](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37403403756)
ran at `a42b009` on hosted macOS. All 18 token/request-boundary tests passed.
The live account check then returned `missingBindings` for all three ASC names;
no Apple API request was made. Those credentials are unavailable to this
`app-store` workflow, rather than merely unknown from metadata. Subsequent
upload-mode [run 37540319978](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37540319978)
passed all 39 signing-helper tests on macOS, then confirmed the base ID,
distribution P12/password, main/Safari profile and all three ASC bindings
unavailable to this runner. No aggregate extension-profile alternative was
provided. Signing and upload were skipped. Exact secure settings are in
[CLOUD-RELEASE](CLOUD-RELEASE.md); the presence check does not decode credentials
or certify registration, capability grants or Apple account authority.

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
3. Create the iOS app record in App Store Connect with the matching main ID,
   available app name, primary language, unique SKU and intended access. Actual
   account fields and existing records determine these choices.
4. Supply matching Apple Distribution private key/P12 and App Store profiles for
   app and Safari. Apple's certificate API cannot recover the private key.
5. Set `APP_BASE_BUNDLE_ID` and the registered App Group in Actions variables.
   Run the checked [archive/upload workflow](CLOUD-RELEASE.md). Upload goes to
   App Store Connect; public release requires processing, QA and App Review.

Official sources: [OpenAPI specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip),
[team API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api),
[App Group registration](https://developer.apple.com/help/account/identifiers/register-an-app-group),
[group assignment](https://developer.apple.com/help/account/identifiers/enable-app-capabilities#enable-app-groups),
[new App Store app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app),
[App ID prefixes](https://developer.apple.com/library/archive/technotes/tn2311/_index.html).
