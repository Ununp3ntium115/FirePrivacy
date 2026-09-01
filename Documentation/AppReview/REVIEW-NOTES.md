# App Review notes

## What the app is

Fire Privacy is a privacy and security utility. It analyzes an **App Privacy
Report file that the user exports themselves** from Settings › Privacy &
Security › App Privacy Report, and explains what that file records.

## How to test it end to end without any data of your own

1. Launch the app. The first screen explains what it does; no account is
   required and none exists.
2. Tap **Explore the demo**. This imports a fully synthetic report bundled with
   the app. Every bundle identifier is under `com.example.` and every host is
   under a reserved TLD from RFC 2606. The session is watermarked as demo data
   throughout.
3. The Overview shows six posture dimensions, each with a "How is this
   calculated?" link, and up to five priority findings.
4. Tap any finding to see its complete evidence chain: the observed facts, the
   rule's interpretation, what the finding explicitly does *not* establish, and
   the source line numbers and hashes behind it.
5. Open **Apps** → any app → **Raw evidence** to see the underlying records.
6. Open **Protection**. The system URL filter reports itself as unavailable in
   this build (the capability has not been granted yet), and the screen says so
   plainly rather than offering a control that cannot work.
7. Open **Trust** to see everything stored, every network destination the app
   can ever contact and why, and **Delete all Fire Privacy data**.

## Data collection

The developer collects nothing. There is no account, no advertising SDK, no
analytics SDK, no cross-app identifier and no third-party crash reporter. The
privacy manifest declares no collected data types and no tracking domains.

Importing, analyzing, exporting and deleting make **no network request at all**.
A source-level check in `Tests/PrivacyRegression/` fails the build if a
networking API is introduced into the local-analysis modules.

## Permissions

The initial release requests no protected-resource permission: no Contacts,
Photos, Camera, Microphone, Location, Bluetooth, Health or Motion. The
`NSLocalNetworkUsageDescription` string is present only because a user may
optionally connect the app to a language-model server they run on their own
network; nothing else uses it.

## Network Extension

This build contains no Network Extension provider and requests no Network
Extension entitlement. The `com.apple.developer.networking.networkextension`
entry in the entitlements file is commented out pending the URL filter
capability request. The app does **not** use a packet-tunnel provider as a
general traffic-inspection mechanism; see ADR-002.

## AI

Explanations are optional. The default mode assembles text from the finding
itself with no model involved. Model modes are named in the UI, and Apple
Private Cloud Compute is described as server-side Apple processing, never as
on-device processing. Every generated explanation is validated against the
deterministic finding before display and is discarded if it cites evidence or an
action that does not exist.

## Claims

The app does not claim to stop all tracking, to see inside other apps, to read
other apps' permissions, or to make a device anonymous. Onboarding includes an
explicit "What Fire Privacy cannot do" section.
