# ADR-010 — Capability bridges are stubbed, not guessed

**Status:** accepted

## Decision

The two files that touch Apple frameworks the packages avoid —
`FoundationModelsBridge` (Foundation Models) and `SystemURLFilterBridge`
(`NEURLFilterManager`) — report their capability as unavailable until the calls
have been verified against a shipping SDK on a device, and the entitlement has
been granted.

## Context

Both APIs sit behind a capability Fire Software Solutions has not yet been
granted, and neither can be exercised in CI. Writing plausible-looking calls
against an unverified API would produce a build that appears to offer protection
while doing nothing.

## Consequences

- The Protection screen says "not available on this build" and explains why,
  which is honest and testable, instead of showing a switch that silently fails.
- The state machine, dataset verifier, Bloom filter, disclosures and safe-mode
  paths around them are fully implemented and tested, so enabling the capability
  is a small, reviewable change.
- Each bridge carries a `TODO(Gate n)` naming exactly what must be verified.
