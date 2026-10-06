# Security

Fire Privacy's boundaries cover hostile report input, authenticated private
storage, signed public datasets, optional approved network requests, constrained
advisors, and edition-specific protection extensions. Source implementation and
passing portable tests do not establish native or physical-device readiness.

## Reporting

Use the [public issue tracker](https://github.com/Ununp3ntium115/FirePrivacy/issues)
for ordinary bugs or policy questions. Use a minimal synthetic example and the
app/OS versions. Do not publish a personal report, activity history, credentials,
or a sensitive vulnerability reproducer. Request a private reporting route from
the maintainer before sending sensitive details. No private email or response-time
promise has been verified.

## Security contracts

- Import bounds bytes, lines, records, nesting, collections and strings, rejects
  invalid UTF-8/duplicate keys, and preserves provenance for supported evidence.
  Imported text is plain data, never HTML, SQL, instructions or executable code.
- Local analysis contains no networking path. Networking belongs only to the
  approved native worker, whose typed, one-use authority binds the exact bytes,
  destination, authentication, context, consent generation and expiry.
- Revocation and context changes cancel pending work and reject late output.
  A stale callback must neither publish a result nor recreate deleted storage.
- Private history and feature state use versioned AES-GCM authenticated contexts,
  a random device-only unlocked Keychain key, protected atomic writes and backup
  exclusion. Missing keys/authentication failures preserve an unavailable state.
  Deletion/retention failures require truthful, retryable cleanup.
- Signed KB/rule/filter data have bounded, declarative schemas, trusted public keys,
  authenticated payload digests, validity/semantic checks and persisted downgrade
  protection. Trust anchors are not taken from an unauthenticated download.
  A supplied trusted revocation context must be enforced. A publisher signature
  does not establish vendor accuracy or license rights.
- Signed rule updates configure only eight compiled detectors and bounded
  thresholds. They cannot inject prose, executable code, actions or score
  weights. Increasing sequence/version and complete signed-manifest identity
  reject rollback and same-sequence equivocation; disabled detectors are explicit
  and withhold overall posture.
- The advisor accepts closed typed inputs and constrained presentation choices;
  evidence/action references must match the captured current analysis. Model
  prose, new facts, tools and control commands are never displayed or executed.
  There is no automatic cloud fallback. Remote input is minimized and previewed.
- Native transport retains normal TLS trust, dates and hostnames; an optional
  leaf pin is additional validation. HTTP, redirects, cookies, caches, header
  injection and unbounded response accumulation are rejected. Tokens never enter
  previews, event logs, Codable endpoint configuration or diagnostics.
- App Groups contain validated protection configuration/rules and explicit
  allowances, not report history, raw source, consent, model inputs or secrets.
  Consumer, URL-filter and managed targets have distinct capabilities and gates.
- Routine logs/event history contain codes/counts/host metadata, not personal
  observations or server/model text. Reminders contain generic text. Scene
  privacy covering protects inactive previews; it does not prevent someone
  reading an already unlocked, open device.
- Full exports are intentionally readable. Redacted export does not guarantee
  anonymity. Protected temporary copies are cleaned, while recipients retain
  their own copies under their policies.

## Verification and residual limits

See [VALIDATION](Documentation/VALIDATION.md) for dated evidence and
[RELEASE-CHECKLIST](Documentation/RELEASE-CHECKLIST.md) for pending checks.
Native SDK/type checking, real current Apple exports, TLS/pinning with a test
endpoint, OS extension/DNS activation and removal, key rotation and deletion
races, accessibility, physical locked-state/backup behavior, signed distribution,
and Apple review must each be demonstrated separately.

Safari can retain compiled rules after an unsuccessful reload; report uncertain
removal and provide Settings remediation. DNS providers can see queries and
control retention; TLS alone does not guarantee their data practices. Approved
URL-filter infrastructure, signed publishing/revocation operations, and managed
operator deployment are external prerequisites. Consent cannot recall data
already sent to an external endpoint. Historical contacts and temporal patterns
cannot establish payload contents, current permissions, malicious intent or a
legal conclusion.

Keep private signing keys, passwords, `.p12`/`.p8` files, provisioning profiles,
model credentials and production dataset signing keys out of commits/chat/logs.
Use secure GitHub secrets/Keychain as appropriate. Committed dataset public keys
and synthetic test keys are not production private signing credentials.
