# Fire Privacy privacy policy

Policy for the expanded consumer edition, prepared October 6, 2026. Verify
that it matches the submitted binary before release.
The separately gated URL-filter and managed editions require their own matching
operator/deployment disclosures.

## Your report and local analysis

Fire Privacy reads the App Privacy Report file you choose in Files. It may
contain app identifiers, domains, sensor events, timestamps and supported
context/source fields. The app normalizes supported records, preserves evidence
provenance, and creates deterministic findings on your device. It does not
modify the original file or read other apps' current permissions. The demo is
synthetic, not personal activity.

No account, advertising identifier, advertising SDK, subscription or analytics
SDK is used. The developer does not receive a report database from local
analysis. Optional network operations are described below; keeping them off
leaves import, analysis and offline guidance local.

Cited domain classifications are publisher knowledge, not proof of what a
particular contact transmitted. Historical contacts, sensor events and missing
observations do not establish payloads, current permissions, harm, safety or a
legal conclusion. User-entered audits and overrides remain separate from Apple
observations.

## What stays on this device

The private workspace holds bounded normalized report history, preferences,
manual audits/overrides, consent receipts, installed dataset state and local
network event metadata. History defaults to ten reports with a 64 MiB
report/source-ciphertext limit; its configured limits are shown by the app.
Raw-source retention is off by default. You can separately consent to an
encrypted original copy. Keeping a copy does not change the Files original.

Private records use CryptoKit AES-GCM encryption and a random device Keychain
key accessible while unlocked, configured not to synchronize through iCloud or
migrate to another device. Private files use complete file protection and backup
exclusion. Data remains subject to the chosen retention/deletion controls;
failed cleanup is reported. Physical-device behavior must be verified on the
actual build.

Local event history is limited to recent operation purposes, endpoint hosts,
times, byte counts and status. It does not include URL paths/queries, request
bodies, credentials, imported identifiers, model output or server error text.
Consent receipts record the feature, disclosure version, scope and grant/revoke
times and remain local. They do not grant access to unrelated features.

## Optional model assistance

Offline guidance is always available. The optional Apple on-device adapter uses
SystemLanguageModel on eligible iOS/iPadOS 26 devices when Apple Intelligence and
model assets are ready. That adapter does not send model input to a server.
Unsupported/unready devices fall back to offline guidance. Private Cloud Compute
is not enabled by this app.

A model selects presentation order/style; displayed facts, explanations,
limitations, scores and actions remain authored from deterministic evidence.
Invalid or stale references are rejected. A model cannot change permissions,
protection settings or analysis decisions.

You can optionally configure a compatible HTTPS model endpoint you operate.
Before a request, the app shows its actual destination, complete JSON, configured
authentication presence and operator retention disclosure. Sending needs current
feature consent and a short-lived single-use approval of that exact request.
Revocation and context changes cancel future/pending work and reject stale output.
There is no automatic fallback to a public cloud endpoint.

The minimized request includes model/schema settings, static presentation
instructions, rule/action identifiers and versions, deterministic severity,
confidence and counts, and request-local ordinal references. It excludes raw
reports, domains, app identifiers, timestamps, notes, stable report/evidence IDs
and the local analysis digest. These summary fields are still derived activity
data, not a claim of anonymity. Configured authentication and network metadata,
including IP/request timing, also reach the destination. HTTPS uses normal
certificate, date and hostname checks; an optional certificate pin adds a check.

The endpoint operator can read the summary and controls server logs, storage,
training and deletion. Fire Privacy cannot verify or enforce an external
operator's practices or delete its copies. Configure an endpoint you operate and
understand; review any hosting/provider involvement. The app itself does not
use imported reports to train a model or sell/license report data.

## Optional datasets and protection

Knowledge-base, reviewed rule-configuration and filter downloads need separate
consent and approval. Rule configurations use the knowledge-update request;
they can only enable/disable compiled detectors and adjust bounded thresholds,
not add executable behavior or new claims. Their
GET requests have no report body. The host still receives connection metadata
and any configured authentication; its stated retention policy applies. Signed
public data must pass the app's trust, validity, semantic and downgrade checks
before activation. No production publisher endpoint is inferred from a domain
shown in an imported report.

Safari content blocking is an optional extension you enable in Settings. It
uses validated rules and explicit local allowances and does not receive your
visit history. Its coverage is Safari resources, not every app. Safari can cache
compiled rules; failed reload/removal means old rules may remain until you
disable the extension in Settings. The app reports this rather than claiming
that removal succeeded.

Encrypted DNS is optional and requires your resolver choice/consent and enabling
the configuration in Settings. DNS query names leave the device and the resolver
can read them, along with connection metadata. Encryption protects the
connection, not against the resolver. Resolver operator, logging/retention,
jurisdiction, blocking and failure behavior must be understood before enabling.
Encryption alone does not block trackers. Apps using another resolver, direct
IP addresses, caches or tunnels may be outside this configuration's coverage.

Shared protection storage contains validated rules/configuration and explicit
allowances, not report history, raw sources, receipts, advisor payloads, keys or
credentials. Generic local reminders require separate consent and notification
permission and contain no domain, app, finding or report identifiers.

## Exports and diagnostics

You choose full or redacted JSON, CSV or Markdown exports and a system share
recipient. Exports are readable, not encrypted by Fire Privacy; a full export
can expose activity. Redaction does not guarantee anonymity. Sanitized diagnostic
exports contain allowed version tokens, counts and error codes, not personal
reports or credentials. A receiving app/service applies its own policies.

Temporary export files use protection/backup exclusion and are cleaned after
sharing/cancellation, launch and deletion. Copies held by recipients remain
outside Fire Privacy's control.

## Revocation and deletion

You can revoke optional features independently. Delete-all cancels/revokes
requests, removes local reminders, attempts removal of owned OS protection
configuration, and deletes private report/state files, temporary exports and the
private key. Failures are reported and can require a retry after unlock or
manual removal in Settings. If OS removal is incomplete, a protected,
backup-excluded retry queue retains only feature names; it contains no report,
endpoint, credential or receipt and is removed after successful cleanup.

Deletion cannot remove the original file in Files, Apple's report history in
Settings, previous shared copies, or data already received by an external
endpoint/resolver. Remove those through their own controls. There is no app
account to close or developer-held report database to erase.

## Support and hosted pages

Use the [public issue tracker](https://github.com/Ununp3ntium115/FirePrivacy/issues)
for ordinary questions. Do not attach a real report, personal activity,
credentials or a sensitive vulnerability. Use a synthetic example; request a
private route before sharing sensitive details. GitHub account information and
anything you post are handled by GitHub and may be public.

This page and support are hosted by GitHub, whose connection/cookie/account
handling follows [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
Opening a policy/support link connects through your system browser. The app
does not send a report to that page. The project has not verified a private
contact email or a separate legal company identity from repository text.

For policy questions use the support route without private data. Changes to the
shipping app's data handling require an updated policy and App Store privacy
answers before distribution.
