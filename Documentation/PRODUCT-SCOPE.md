# Fire Privacy expanded source scope

The local-report MVP has been expanded with the repository's underlying privacy
architecture. This describes implemented source/coordinator paths, not a native
build, completed UI, installed protection, Apple approval, or released product.
Screenshots and final metadata must wait for the matching working binary.

## Consumer implementation

- Bounded App Privacy Report import with normalized app/domain/sensor activity,
  source hashes/line provenance, public-suffix normalization, explicit unsupported
  evidence and a synthetic demo.
- Cited signed knowledge, versioned deterministic findings, facts/inferences/
  uncertainty, closed actions, explainable posture dimensions, profiles and
  manual audits kept separate from Apple observations. Signed rule configuration
  can only enable/disable the eight compiled detectors and adjust bounded
  reviewed thresholds; it cannot download executable behavior or new claims.
- Bounded encrypted report history, comparison/weekly summaries, optional
  separately consented encrypted source retention, local overrides, JSON/CSV/
  Markdown full/redacted exports and sanitized diagnostic export.
- Separate versioned consent receipts, dynamic network disclosure/event history,
  exact expiring one-use request approval, revocation/cancellation and protected
  preference/dataset state.
- Offline advisor; optional iOS/iPadOS 26 SystemLanguageModel presentation
  assistance with runtime fallback; optional user-operated HTTPS model endpoint
  with exact minimized-payload preview and no automatic cloud fallback.
- Safari content-blocker extension and encrypted-DNS settings adapter, each with
  separate consent, actual OS state, explicit coverage and removal limitations.
- Generic local reminders, with separate consent and OS notification permission.

The app has no account, ads, subscription, analytics SDK, report resale, or
installed-app enumeration. It does not read other apps' current permissions,
change their permissions, inspect encrypted payloads, or guarantee anonymity,
complete tracking prevention, safety, or a legal finding. Imported activity is
historical. Unknown/absent evidence remains unknown.

## Separate editions and external prerequisites

The consumer target excludes URL-filter and managed provider extensions. The
URL-filter edition contains real iOS 26 manager/control-provider code and signed
prefilter handling, but distribution additionally requires registered IDs/App
Groups, granted capabilities, an operating PIR/Privacy Pass/OHTTP service and
Apple relay validation. Coverage is participating APIs, not all packet traffic.

The managed edition has separate local policy/data/control providers. It needs
an eligible operator, matching entitlements and a supported supervised/MDM
installation. Reading or possessing a policy does not prove management status
or activate a provider. The consumer app is not an MDM enrollment service.
Private Cloud Compute has no implemented request path.

Dataset downloads need a real publisher endpoint, maintained signing/revocation
operations and truthful operator retention disclosures. Optional self-hosted
inference needs a user-operated compatible HTTPS endpoint. No unverified service
hostname, account, certificate, capability grant or legal organization is invented.
The local [dataset publisher](DATASET-PUBLISHING.md) produces real signed KB,
rule/filter and revocation envelopes with an operator's existing private key;
its public authority must be deployed in the signed app before use. It does not
host an endpoint or establish operator identity/Apple service approval.

## Remaining release evidence

The expanded native implementation and UI must pass hosted Xcode checks and
real-device QA. Initial TestFlight upload can supply the installable QA build;
physical/report/accessibility/protection/backup checks finish before final App
Review. Public policies and metadata must be republished to match that exact
edition. See [VALIDATION](VALIDATION.md), [APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md)
and [RELEASE-CHECKLIST](RELEASE-CHECKLIST.md).
