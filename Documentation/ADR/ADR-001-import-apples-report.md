# ADR-001 — Import Apple's report rather than attempting private access

**Status:** accepted

## Decision

Read an App Privacy Report that the user exports themselves, through the system
document picker.

## Context

The alternative would be to try to read the live report database, or to infer
app behaviour some other way. Neither is available to a sandboxed App Store app,
and pursuing them would mean private API and a rejected build.

## Consequences

- Evidence is user-consented and rich: app-attributed domains, sensor access,
  Apple's own domain classification, timestamps and counts.
- The data is historical. Every screen says so, and the freshness rule
  (`FRESHNESS-008`) raises it explicitly when the window has closed.
- Import is a deliberate act, so the app can be genuinely offline by default.
