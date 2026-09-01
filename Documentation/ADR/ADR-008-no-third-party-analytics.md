# ADR-008 — No third-party analytics or crash SDK

**Status:** accepted

## Decision

Use local metrics and user-generated diagnostics only.

## Consequences

- The privacy manifest can honestly declare no collected data.
- Diagnosing a problem depends on the user choosing to send a bundle, which
  lists every file it contains and holds no domains, bundle identifiers or
  report contents.
- The supply chain stays small enough to review.
