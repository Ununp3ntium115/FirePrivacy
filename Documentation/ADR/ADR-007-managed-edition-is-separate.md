# ADR-007 — Managed Edition is separate

**Status:** accepted

## Decision

Supervised-device live filtering is a separate mode, reviewed and likely
distributed separately from the consumer app.

## Consequences

- Different entitlements, different user expectations, different retention.
- Managed flow records never enter any consumer path.
- A consumer build cannot be talked into behaving like a monitoring product.
