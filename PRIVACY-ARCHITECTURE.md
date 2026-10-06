# Fire Privacy privacy architecture

This describes the expanded source implementation. It is not proof of a native
SDK build, working UI controls, physical-device behavior, signing, or Apple
approval. Those results belong in [VALIDATION](Documentation/VALIDATION.md).
The consumer, URL-filter, and managed editions have different deployment gates.

## Local analysis and evidence

Selecting a Files document authorizes a bounded local import. Supported records
retain source line/hash, file hash, parser version, timestamps and supported
context fields. Domain normalization uses the bundled public-suffix data;
unknown or unsupported evidence remains explicit. Raw text is untrusted and is
never executed or rendered as HTML.

The deterministic engine supplies versioned findings, observed facts,
inferences, uncertainty, evidence references, and closed action identifiers.
Reviewed domain classifications come from an authenticated, cited knowledge
base. Unreviewed, disputed, expired, unknown, and user-overridden information
remain distinguishable. A signature authenticates a publisher; it does not prove
a classification is correct.

Signed analysis-rule updates use the same approved knowledge-update path and
deployed knowledge-family anchors. Their closed configuration can only enable
or disable eight compiled detectors and adjust bounded reviewed thresholds;
it cannot download prose, actions, scores or executable behavior. Signatures,
expiry, revocations and full-manifest high-water identity are verified before
installation. Disabled detectors withhold overall posture and remain explicit.

Profiles change relevance and preferences, not recorded evidence. A manual
permission audit is user-entered information, not a read of another app's live
permission state. Posture dimensions explain their inputs and missing coverage;
missing evidence cannot produce a perfect-safety score. Report comparison and
weekly summaries describe exported history. A missing later observation does
not prove a finding was resolved. Temporal proximity is association, not cause.

## Private storage and retention

The private workspace stores bounded report sessions, an encrypted index,
preferences, manual audits/overrides, consent receipts, network event metadata,
and installed dataset state. The default history policy is ten reports and
64 MiB for report/source ciphertext; configurable source limits are at most
20 reports and 64 MiB. Feature-state storage has separate bounded limits.
Retention cleanup failures must be reported and retried, rather than silently
presenting removed index entries as deleted files.

Raw source retention is off by default. Keeping an encrypted original copy
requires its own consent; its digest must match the imported source. The
original Files document is never modified. Demo activity is synthetic and is
not stored as a personal session.

Private records use versioned CryptoKit AES-GCM envelopes whose authenticated
context binds record type, state key, and session identity. The random 256-bit
Keychain key is accessible while unlocked, this-device-only, and not iCloud
synchronized. Private files use complete protection and backup exclusion;
metadata is applied before atomic replacement. Failed authentication must not
silently replace a saved value. Hardware behavior still needs physical QA.

Exports are user-created readable JSON, CSV, or Markdown, with explicit full or
redacted content choices. Redaction is not a claim of anonymity. Temporary files
are protected, backup-excluded, and cleaned after sharing/cancellation, launch,
and deletion. CSV formulas and Markdown syntax in imported strings are escaped.
Sanitized diagnostics contain allowed version tokens, counts and error enums,
not report text, domains, app identifiers, source hashes, or endpoint secrets.

## Consent and the app-created network boundary

[Consent](Sources/FirePrivacyCore/Consent.swift) defines independent, versioned
receipts. Import consent does not authorize an update, advisor, filter, source
copy, reminder, or diagnostic export. Revocation, report/analysis changes, and
configuration changes invalidate pending authority and cancel active work.
Receipts and event history remain local in encrypted storage.

The [network catalogue](Sources/FirePrivacyCore/NetworkLedger.swift) creates
disclosures from the actual endpoint, exact payload, authentication presence,
and declared operator retention. The [gate](Sources/FirePrivacyCore/ApprovedNetworkRequest.swift)
binds a short-lived, single-use approval to those bytes, endpoint, certificate
pin, credential digest, report/analysis identity, configuration, and consent
generation. Previewing or entering an endpoint never sends a request.

The sole app-created URLSession worker is
[ApprovedHTTPTransport](Apps/FirePrivacyApp/ApprovedHTTPTransport.swift).
It requires a gate-minted transmission permit, HTTPS, normal certificate-chain,
date and hostname verification, and optionally an exact leaf-certificate pin.
A pin never permits an invalid chain. Sessions are ephemeral with no cookie,
cache, redirect, or shared credential storage. Request and streamed-response
sizes are bounded. There is no automatic public-cloud fallback.

| Operation | When / actor | Information leaving the device |
| --- | --- | --- |
| Import, normalization, matching, scoring, history, local comparison | Local | None through an app network request |
| KB/rule/filter download | Exact request approval and separate update consent | No report body; destination still receives IP/connection metadata and any configured authentication |
| Apple on-device advisor | Separate consent; eligible iOS/iPadOS 26+ device with ready SystemLanguageModel | No model input sent by this adapter |
| User-operated advisor | Separate current consent and approval of complete JSON preview | Model/schema settings, rule/action versions, severity/confidence/counts and request-local ordinal references; no raw report, domains, app IDs, timestamps, notes, stable report IDs or analysis digest |
| Safari content blocker | User enables extension; system applies installed rules | No visit history delivered to this content-blocker extension |
| Encrypted DNS | User consents and enables the configured resolver in Settings | DNS query names and connection metadata go to that resolver; encryption does not hide names from it or itself guarantee blocking |
| System URL filter | Separate edition, approved capability/service, system-confirmed running state | OS private lookup protocol and operator metadata handling; not a Fire Privacy URLSession request |
| Share export/diagnostics | User chooses a system share destination | Chosen readable file; recipient policies apply |
| Policy/support | User opens external browser link | Browser/destination connection handling applies |

Local event history records purpose, endpoint host, time, byte counts and status
only. It stores no URL path/query, payload, token, imported identifier or server
error text. A deleted ledger generation rejects late completion events. Endpoint
operators control server logs/retention/training; the app cannot promise deletion
or non-training by a server the user configures.

## Advisor authority

The offline advisor is always the fallback. The optional Apple adapter selects
`SystemLanguageModel`, not a server provider or Private Cloud Compute. Runtime
eligibility, Apple Intelligence and model readiness are checked. Below iOS 26
or on an unsupported device, evidence and offline guidance remain available.
Private Cloud Compute has no implemented request path in this app.

Model input is a closed, bounded schema. The model can choose presentation order
and style; visible facts, explanations, limitations, scores and actions come
from deterministic code. Output must match the current analysis and its exact
allowed references. Generated prose, tools, permission changes, executable
commands and new conclusions are not accepted. Stale or invalid results are
rejected, and the actual mode/fallback must be shown.

## Protection editions and shared storage

Consumer builds contain the Safari blocker and encrypted-DNS adapter. Safari
coverage is Safari resources, not all apps. A saved DNS configuration is not an
active configuration; system state is checked. Resolver logging, retention,
jurisdiction, blocking and failure behavior must be disclosed from real settings.

The URL-filter edition uses iOS/iPadOS 26 URL-filter APIs, a signed Apple-format
prefilter, and an operator's registered PIR/Privacy Pass/OHTTP service. Apple
must validate the relay configuration before distribution, including TestFlight.
Coverage is WebKit/URLSession and participating networking APIs, not universal
packet inspection. The managed edition is separate and needs its actual
supervised/MDM deployment and capability authorization. Its providers evaluate
local host/app policy without storing payload or flow history.

An App Group carries authenticated protection artifacts, explicit local
allowances, and protection state only: no reports, observations, source files,
consent receipts, advisor payloads, credentials or encryption keys. Safari may
cache compiled rules; it cannot independently expire that cache. Foreground
validation/revocation requests an empty-rule reload. Failed reload/removal must
say cached rules may remain and direct the user to Settings.

## Deletion and recovery

Delete-all revokes/cancels first, removes reminders and owned OS configurations,
and purges private ciphertext, temporary exports, and the private key. Original
Files documents, Settings history, shared copies, and external server copies
remain outside its control. Failures cannot be presented as complete deletion.
A minimal protected, backup-excluded removal queue may retain OS-feature names
only after partial OS cleanup; it contains no report, endpoint, credential or
receipt, and is removed after successful cleanup. Late operations must not
recreate private storage after deletion.

See [SECURITY](SECURITY.md) and [release requirements](Documentation/APPLE-REQUIREMENTS.md)
for security controls, official Apple sources, and remaining operator/device checks.
