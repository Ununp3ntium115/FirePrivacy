# Threat model

## Assets

App Privacy Report contents; the inferred app inventory; contacted domains and
web contexts; sensor-access history; privacy preferences and local overrides;
model credentials; encryption keys; knowledge-base trust anchors; the URL filter
dataset; consent receipts; diagnostic exports.

## Actors and the controls that answer them

| Actor | What they try | Control |
| --- | --- | --- |
| A malicious imported file | crash the app, exhaust memory, smuggle markup or instructions | streaming parser with hard limits; structural rejection of depth, duplicate keys, invalid UTF-8, oversize lines; every string sanitized and length-bounded on import |
| A hostile domain or owner string | reach a model as an instruction, or render as markup | `UntrustedText` on import; `AdvisoryInput` is the entire model surface; no HTML rendering; output validation |
| Compromised knowledge-base distribution | make Fire Privacy libel a company, or suppress a real finding | Ed25519 signature, payload digest, schema allow-list, expiry, revocation list, rollback rejection — all hard gates; two-person review for trust anchors |
| Compromised PIR infrastructure | learn what a user browses | iOS performs the lookup through Apple's relay; the service sees neither the user nor the queried entry; no query logging |
| Network attacker | tamper with a dataset in flight | TLS plus signature verification of the payload itself, so transport compromise alone is not enough |
| An overreaching third-party model | receive more than it should | structured input only; no raw report; explicit mode; field preview; no automatic fallback to a public cloud |
| Another app on the device | read Fire Privacy's data through shared storage | App Group carries protection state only; observations live in the app container, encrypted, with complete file protection |
| Someone with brief physical access to an unlocked device | read the report history | complete file protection, this-device-only key, and a one-action delete-all that destroys the key |
| An insider with backend access | correlate users | backends are separated by role; no backend holds both identity/billing and filter operational data; no query logs to correlate |
| Supply-chain compromise | ship code through a data update | updates are declarative data only; the app cannot load code at runtime, and the privacy regression suite checks for the APIs that would allow it |
| Accidental engineering telemetry | leak by mistake | no third-party analytics or crash SDK; logs carry codes and counts only; the network ledger is user-visible and checked in review |

## STRIDE summary

| Threat | Example | Primary controls |
| --- | --- | --- |
| Spoofing | fake knowledge-base endpoint | TLS, signed manifests, pinned signing keys |
| Tampering | modified NDJSON or Bloom filter | digests, signatures, parser validation |
| Repudiation | unclear what the user agreed to | versioned local consent receipts, invalidated when disclosure text changes |
| Information disclosure | raw report in logs | no raw logging, encryption at rest, privacy-annotated logging |
| Denial of service | huge lines, filter outage | parser limits, bounded work, fail-open filtering |
| Elevation of privilege | extension reading app data | minimal App Group, separate entitlements, no report data outside the app container |

## Residual risks accepted for this release

- The bundled public-suffix list is a curated subset. Hosts under an unlisted
  suffix are flagged `unknown_public_suffix` so a wrong grouping is visible
  rather than silent.
- The first-party heuristic (`isLikelyFirstParty`) is a label-matching guess and
  is used only to reduce noise, never to raise a finding.
- Vendor classification is a claim about a company. Data-broker and
  location-intelligence entries require review status `reviewed` and a citable
  source before shipping, checked by a test.
