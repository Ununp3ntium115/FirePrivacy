# Prepare signed dataset updates

`scripts/publish-signed-datasets.py` prepares local, reviewable HTTPS download
artifacts. It uses an operator's existing Ed25519 private PEM key and OpenSSL
signing plus public verification. It creates no keys, performs no HTTP request,
publishes nothing and changes no app trust anchor. Source accuracy/licensing,
publisher identity, maintained HTTPS hosting and Apple service approval remain
operator responsibilities.

The app accepts a download only when the exact key ID/public key is already a
trusted deployed anchor. A public key supplied by the download cannot authorize
itself. Preserve production private keys outside the repository/chat/logs and
retain control of the maintained publisher/revocation service. The CLI never
prints private material, signatures or backend diagnostics.

## Inputs and outputs

The five commands are `kb`, `kb-revocations`, `filter`, `filter-revocations`, and
`rules`.
Run `python3 scripts/publish-signed-datasets.py <command> --help` for its exact
arguments. Each requires a bounded payload, existing key path/key ID, existing
source-review JSON, explicit real HTTPS target, expiry and new output directory.
The default issue time is now; whole-second Unix timestamps are used.

The private key must be a regular file owned by the caller with no group/other
permissions, such as mode 600 or 400. An encrypted PEM uses
`--passphrase-file` with the same ownership/permission requirement; a passphrase
never belongs in a command argument or environment variable. Install OpenSSL
with Ed25519 support. `FIREPRIVACY_OPENSSL_PATH` can select its executable;
standard PATH and Homebrew OpenSSL locations are also checked. LibreSSL is not
silently substituted for OpenSSL.

The new output directory contains:

- `download.json`: the exact response body the app's approved update request
  consumes. Host this file only after operator review.
- `manifest.json`, exact `payload.json` or binary `payload.bin`, and
  `signing-message.bin`: inspectable bytes used for hashing and signing.
- `public-key-reference.json`: public key in base64/lowercase hex, digest,
  exact public build-variable name/JSON and deployment requirement;
  this reference does not install or authorize a key.
- `source-review-and-changelog.json`: operator-supplied review, source links,
  claimed licensing basis, target, versions/digests/byte counts and whether a
  prior artifact was authenticated. These statements are not independently
  fetched, verified or legally certified by the CLI.

Outputs have restricted local permissions. Existing output directories are
preserved. Errors leave no purported successful release. Local files, a valid
signature or a target URL do not establish live hosting or distribution.

## Source review

The input review record has the following closed schema:

```json
{
  "schemaVersion": 1,
  "reviewer": "Actual responsible reviewer",
  "reviewedAtSeconds": 1791244800,
  "changeSummary": "Describe the reviewed changes and their evidence limits.",
  "sources": [
    {
      "url": "https://github.com/Ununp3ntium115/FirePrivacy",
      "retrievedAtSeconds": 1791244800,
      "purpose": "Replace this example with the actual cited source and review.",
      "license": "Record the actual usage/license basis; this example grants no rights."
    }
  ]
}
```

Each source may additionally carry a lowercase 64-hex `sha256` of the reviewed
document. Replace the example with real operator-reviewed evidence; all KB
citations must appear in the record. A source title/URL, publisher signature or
classification category does not establish what an observed domain contact
transmitted. Keep source accuracy, confidence, review status and limitations
honest. Review records contain no reports, credentials or signing-key paths.

## Knowledge base and its revocations

`kb` reads the Core `KnowledgeBasePayload` schema: version, sources and cited
classifications, with whole-second ISO8601 UTC dates. It requires a positive
`--sequence` and three-component `--minimum-app-version`. The signed manifest
uses the fixed `FirePrivacy.KnowledgeBase.v1` LF field order, including the final
LF. Payload hashing covers the exact input bytes. The response is
`{"manifest":"base64 manifest JSON","payload":"base64 payload JSON"}`.

`kb-revocations` reads `{schemaVersion,sequence,revokedVersions,revokedKeyIDs,
revokedPayloadDigests}`. It publishes sorted unique arrays with the separate
`FirePrivacy.KnowledgeBaseRevocations.v1` signing domain. Its download response
is `{"revocations":{"manifestData":"base64 manifest JSON",
"payloadData":"base64 payload JSON"}}`, which the Engine accepts without a new
KB payload. An operator can combine that `revocations` member with the KB
manifest/payload pair when maintaining one endpoint; the app applies revocations
first. Do not publish a revoked new KB in that combined response.

## Reviewed analysis-rule configuration

`rules` reads Core `DeclarativeRuleConfiguration`: exactly `schemaVersion`,
`version`, `implementationVersion`, and `rules`. Schema is 1, implementation is
`ruleset-2.0.0`, and all eight compiled detectors must appear exactly once. Each
rule has exactly `id`, boolean `enabled`, and `parameters`.

| Detector | Accepted parameters |
| --- | --- |
| `AGG-APPLE-001` | Empty object |
| `AGG-CROSSAPP-002` | `minimumDistinctApps`: integer 3–1000 |
| `LOC-NET-003` | Empty object |
| `SENSOR-UNEXPECTED-004` | Empty object |
| `UNKNOWN-HIGHFANOUT-005` | `minimumDistinctDestinations`: integer 10–1000; `maximumReviewedCoverage`: finite number 0.05–0.5 |
| `VENDOR-KNOWN-006` | Empty object |
| `COVERAGE-GAP-007` | Empty object |
| `FRESHNESS-008` | `minimumAgeDays`: integer 1–365 |

The default payload is
[default-rules.json](../Sources/FirePrivacyCore/Resources/AnalysisRules/default-rules.json).
Review its proposed changes before signing. No arbitrary prose, new detector,
score weight, severity, action, executable code or model instruction is accepted.
Disabling a detector suppresses its findings; it does not prove the activity
disappeared, and the app withholds overall posture when detectors are disabled.

Provide a positive `--sequence` and `--minimum-app-version`. Rule/minimum app
versions have three numeric components, each at most six digits. Payload bytes
are at most 16 KiB and validity at most 90 days. The signing message uses these
LF-separated fields, with a final LF:

```text
FirePrivacy.AnalysisRules.v1
schemaVersion
configurationVersion
sequence
generatedAt
expiresAt
minimumAppVersion
ruleCount
payloadSHA256
signingKeyID
```

The values above are replaced by their manifest values; `signatureBase64` is
not part of the signing message. Output is
`{"rules":{"manifest":{...},"payloadData":"base64 raw payload"}}`.
The Engine consumes this member through the existing knowledge-base update
request, using the knowledge-family public anchors, consent and exact preview.
It is not an additional network purpose. A maintained endpoint can include it
alongside the KB pair and/or authenticated revocations; revoked key/payload
digests remain effective for rules.

Previous-rule verification authenticates the complete manifest and exact payload
before requiring both a greater sequence and semantic configuration version.
The app's persisted high-water mark also binds the complete normalized signed
manifest: re-signing changed dates or minimum app version at the same sequence
is equivocation. Exact current-artifact restoration is distinct from accepting
a new update. A local publisher cannot reset those runtime protections.

## Filter payloads and revocations

`filter` needs `--version`, `--tag` and a declared `--kind`:

| Kind | Payload and extra parameters |
| --- | --- |
| `safariDomainsV1` | Nonempty, unique, lowercase ASCII/Punycode domain array; no URL, wildcard, IP or regex |
| `managedRulesV1` | Core ManagedPolicy JSON; matching inner/outer version, expiry no later than the signed outer expiry, actual supported deployment mode and rules |
| `appleURLBloomV1` | Already-generated Apple-compatible binary prefilter, exact `--bit-count`, `--hash-count`, `--murmur-seed`, real `--pir-server-url` and operator-supplied `--apple-configuration-identity`; optional `--privacy-pass-issuer-url` |

The CLI does not construct or deploy PIR/Privacy Pass/OHTTP infrastructure and
does not verify Apple's relay approval. Synthetic service fields in tests are
not deployment configuration. The URL-filter edition needs its real service,
registered capabilities and Apple's relay validation before non-development
distribution, including TestFlight. Managed policies require the actual eligible
deployment/operator. See [APPLE-REQUIREMENTS](APPLE-REQUIREMENTS.md).

`filter-revocations` reads `{targetKind,revocations:{keyIDs,versions,
payloadDigests}}` with a non-revocation target kind. It emits a signed
`revocationsV1` dataset containing sorted unique sets. The app routes that
download to the declared target's persisted revocation context.

Filter signing uses the exact compact sorted manifest JSON used by Swift's
JSONEncoder, with omitted nil fields and no final LF. Manifest integers remain
exact even above 2^53. Output is Core SignedFilterDataset JSON: object manifest,
base64 raw payload, and base64 detached signature.

KB payloads are limited to 4 MiB; KB revocations to 1 MiB; filter revocations to
512 KiB. This publisher limits ordinary filter bytes to 5 MiB, a stricter subset
of Core's 16 MiB cap, so the final base64 envelope fits the app transport's
8 MiB limit. Rule payloads are at most 16 KiB. KB validity is at most 366 days;
filters, revocations and rule configurations at most 90 days.
Expired, excessive or future-dated input is rejected.

## Version continuity and hosting

For later releases, pass `--previous-artifact` pointing to the previous local
`download.json`. The CLI verifies it with the same supplied signing key before
requiring increasing sequence and KB dataset version, increasing sequence and
rule configuration version, or increasing filter version. Revocation updates
must retain all previously authenticated deny
entries and their target. A previously revoked signing key cannot authorize a
new revocation release. Expired prior documents still preserve revocation
continuity; expiry never clears the app's retained deny entries.

The current prior-artifact path supports same-key continuity. A key rotation
needs a separately reviewed app trust-anchor deployment and preservation of all
previous sticky revocations; omitting a prior artifact does not erase the app's
high-water marks. The review record explicitly states when no prior artifact
was checked. The tool provides no downgrade/rollback bypass.

## Deploy the public update authority

The runtime accepts operator public anchors from signed build Info.plist, through
`FIREPRIVACY_KB_PUBLIC_KEYS_JSON` and `FIREPRIVACY_FILTER_PUBLIC_KEYS_JSON`.
Set those public GitHub Actions variables or build settings before the signed
app build. Each is a raw JSON object mapping a key ID to exactly 64 lowercase
hex public-key characters. `public-key-reference.json` provides the exact
`buildVariableName` and `buildVariableJSON` for its artifact family. These public
values do not belong in the private signing-key secret; the corresponding private
dataset PEM stays with the operator.

Use separate knowledge/filter key identifiers. Each configured map is limited
to 32 IDs and 16 KiB; IDs use `[A-Za-z0-9_.-]{1,80}`. Empty/unset maps preserve
bundled bootstrap trust for the local consumer app. Duplicate decoded IDs,
malformed supplied maps, zero/invalid key bytes, a different key under a pinned
ID, or a knowledge/filter ID collision are rejected. An identical pinned
declaration retains its original validity window. Pins and configured maps are
independently bounded, so 32 new keys plus one bootstrap key yields 33 merged
keys. The app and every included provider must contain exact matching filter
configuration; malformed config never quietly becomes a smaller trust set.

Build deployment establishes that specific public authority. Download content,
an App Group file or a local preference cannot add trust. Publishing a response
before its key is deployed yields a rejected update, even when its signature
is mathematically valid. Native archive/configuration validation must check the
exact public maps before release.

After review, the operator hosts the public response on the supplied HTTPS
endpoint and maintains it, source review, expiry renewal and revocations. Record
the actual host/operator retention disclosure for app consent; dataset GETs send
no report body but do expose connection metadata. No live endpoint is deployed
by this repository helper.

## Verification

Run the real-crypto Python tests:

```sh
python3 -m unittest discover -s Tests/CloudRelease -p test_dataset_publisher.py -v
```

`DatasetPublisherInteroperabilityTests` invokes the actual CLI with unique
temporary keys on Linux/macOS and feeds all seven artifact families into the real
Swift verifiers. It compares canonical signing bytes, rejects payload/signature
tampering and verifies rule restore/equivocation behavior. Keys and artifacts
are removed after each test. Neither
suite uses or generates a known production private key or performs publication.
