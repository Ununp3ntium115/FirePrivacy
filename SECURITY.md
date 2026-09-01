# Security

## Reporting a vulnerability

Report privately to Fire Software Solutions LLC before public disclosure.
Include the app version, iOS version, and the smallest input that reproduces the
issue. Please do not include a real App Privacy Report export — a synthetic file
that reproduces the issue is enough, and the export contains a sensitive history
of your own app and domain activity.

We will acknowledge receipt, agree a disclosure timeline with you, and credit
you unless you prefer otherwise.

## What we consider in scope

- Anything that causes Fire Privacy to transmit user data it promised to keep
  local.
- Anything that causes an imported file to be executed, rendered as markup, or
  interpreted as model instructions.
- Signature-verification bypasses for the knowledge base or the filter dataset.
- Local data readable without the encryption key, or surviving "delete all".
- A UI state that claims protection is active when it is not.
- Findings that assert more than the evidence supports.

## Trust boundaries

| Boundary | Assumption |
| --- | --- |
| Imported file | hostile |
| Domain / owner / context strings | hostile |
| Knowledge-base release | untrusted until the Ed25519 signature, digest, schema, expiry, revocation and rollback checks all pass |
| Filter dataset | same |
| Model output | untrusted; validated against the deterministic finding |
| Local endpoint you configure | trusted only to the extent you configured it, over TLS with a pinned certificate |
| App Group contents | readable by extensions, so it carries protection state only |

## Hard rules in the codebase

- No force-unwrap in parsing, crypto, persistence or Network Extension code.
- No string-built SQL; no HTML rendering of imported content; no JavaScript
  bridge.
- Knowledge-base and rule updates are declarative data. The app never downloads
  code that changes its behaviour.
- Production logs never contain domains, bundle identifiers, contexts, notes,
  prompts, model responses, credentials or IP addresses.
- Trust-anchor changes require two-person review.

## Cryptography

- SHA-256 for evidence linkage and content-derived identifiers. CryptoKit on
  Apple platforms, with an identical portable implementation used off-device so
  results match everywhere.
- Ed25519 for dataset signatures. If signature verification is unavailable on a
  platform, verification **fails**; the bundled dataset stays in use.
- AES-GCM for local records, with a versioned envelope and per-record nonce.
