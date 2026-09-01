# Fire Privacy

A privacy control center for iPhone. Fire Privacy reads the App Privacy Report
that *you* export from iOS Settings, explains what it shows with linked
evidence, and — where iOS provides a supported mechanism — helps you act on it.

**Free, no account, no advertising, no data resale.** Everything is analyzed on
the device by default.

---

## What Fire Privacy does

1. **Historical visibility.** You export Apple's App Privacy Report and import
   the newline-delimited JSON file. Fire Privacy parses it on-device, associates
   contacted domains and sensor access with app bundle identifiers, matches them
   against a signed local knowledge base, and produces evidence-backed findings.
2. **Guided control.** It explains the trade-off of each privacy choice in plain
   language and gives exact steps to change iOS settings. It never pretends it
   can silently change another app's permissions.
3. **Preventive filtering.** On iOS 26 or later it can use Apple's
   privacy-preserving URL Filter so that *iOS* denies requests to known tracking
   destinations. Fire Privacy does not receive the addresses you request.
4. **Private explanation.** A deterministic rules engine is the source of truth.
   An optional model — Apple's on-device model, or an endpoint you run yourself —
   only rewrites a finding in plainer words, and everything it writes is checked
   against the finding before you see it.

## What Fire Privacy cannot do

This list is part of the product, not a disclaimer. A consumer App Store app
cannot:

- enumerate every app installed on your iPhone;
- read the current permission state of other apps;
- disable an SDK inside another app;
- see inside another app's encrypted traffic;
- open another app's Settings page;
- prove that a domain contact was harmful, or that a sensor reading was sent.

Fire Privacy identifies **evidence and indicators**. Where it is inferring, it
says so; where it does not know, it says that too.

## Editions

| | Consumer | Managed (supervised devices) |
| --- | --- | --- |
| Import and analyze App Privacy Report | Yes | Yes |
| Deterministic findings and guidance | Yes | Yes |
| System URL filter (iOS 26+) | Yes | Yes |
| Live flow attribution / allow-drop filtering | No | Yes |
| MDM policy enforcement | No | Yes |

The MVP does **not** use a packet-tunnel VPN as a general traffic-inspection
mechanism. See `Documentation/ADR/ADR-002-no-packet-tunnel.md`.

## Repository layout

```
├── Package.swift              Swift package with every domain module
├── Apps/FirePrivacyApp/       iPhone app target sources
├── Extensions/                URL filter control provider, Safari content blocker
├── Packages/                  ObservationCore, AppActivityImportKit, KnowledgeBaseKit,
│                              FindingEngine, AdvisorKit, ProtectionKit, ConsentKit,
│                              ObservationStore, ReportKit, TrustCenterKit, FirePrivacyUI
├── Resources/                 Demo report, bundled knowledge base, privacy manifest
├── Rules/                     Rule schema, sources and change log
├── Tests/PrivacyRegression/   Checks the privacy promises hold in the source
└── Documentation/             ADRs, threat model, App Review notes, build guide
```

## Building

See `Documentation/BUILDING.md`. In short: the modules build with SwiftPM
(`swift build`, `swift test`); the iPhone app is assembled in Xcode from
`Apps/FirePrivacyApp` plus these packages.

**Nothing in this repository has been compiled yet** — see the status note below.

## Status

Gate 1 (local analysis MVP) is implemented: import, normalization, knowledge
base, deterministic findings, scoring, dashboard, app and domain detail,
evidence chain, Trust Center, export and delete-all. Protection and model
adapters are present as interfaces with honest "not available in this build"
states, pending the Apple capability approvals described in
`Documentation/RELEASE-GATES.md`.

**The code has not been compiled yet.** It was written in an environment with
no Swift toolchain, so `swift build` and `swift test` have never run against it.
The privacy regression script and the bundled-data consistency checks do pass.
Expect a first compile to surface type errors, most likely in the SwiftUI layer
and the Swift 6 concurrency annotations. That first compile is the top of the
backlog.

## Licence and ownership

Fire Software Solutions LLC. See `SECURITY.md` for reporting a vulnerability and
`PRIVACY-ARCHITECTURE.md` for the data-flow commitments.
