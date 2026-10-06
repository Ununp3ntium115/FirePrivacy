# Bundled knowledge-base provenance

The payload contains three exact-host endpoint roles reviewed against vendor-published documentation on 2026-10-05T23:18:53Z. Every entry quotes its source, includes a review timestamp, and distinguishes a documented service role from observed device behavior. Segment's cited documentation is a vendor-published archive; its historical endpoint description does not prove current service operation. No ownership inference, tracking accusation, risk score, or old unreviewed rule list was imported.

The detached Ed25519 manifest binds the exact payload SHA-256, schema and dataset versions, monotonic sequence, release times, minimum app version, record count, and signing-key identifier. `KnowledgeBaseManifest.signingRepresentation` is the authoritative fixed-order UTF-8 signing format. Bundle loading and downloaded activation use the same signature verifier on Apple and Linux. Only the public bootstrap key appears in app code. The private bootstrap key is generated outside the checkout, used once, and destroyed by the release operator. Future releases require separately provisioned signing credentials and reviewed public-key rotation; the app cannot mint its own trusted updates.

The complete Public Suffix List is pinned from the official `publicsuffix/list` repository:

- Commit: `6cd82aff889e3d64e5e03bc5c1f43da1934a960a`
- Source: https://raw.githubusercontent.com/publicsuffix/list/6cd82aff889e3d64e5e03bc5c1f43da1934a960a/public_suffix_list.dat
- SHA-256: `102b252c18b5f87f4c81f017e75282a82c18e00cd0c2e601b5b02a0f7a601f2c`
- License: Mozilla Public License 2.0; the upstream license is included as `PSL-LICENSE.txt`, and the source file retains its copyright and license notices.

Matching defaults to both ICANN and PRIVATE sections so hosted tenants have separate registrable domains. The `includePrivate: false` option explicitly selects ICANN-only behavior. Longest exact/wildcard rules and exception rules follow PSL semantics. An unknown suffix, or unavailable PSL resource, produces no registrable-domain assertion. Foundation URL host conversion supplies IDNA/Punycode; strict ASCII label validation follows, and Unicode display strings never serve as classification keys.

No runtime network requests occur while reading, verifying, or querying bundled data. Downloaded candidates must arrive through the app's separately authorized transport. A returned verified high-water mark must be persisted with the activated dataset to prevent rollback across relaunches.
