# ADR-003 — Use the iOS 26 URL Filter for consumer blocking

**Status:** accepted

## Decision

Prefer `NEURLFilterManager` and Apple's privacy-preserving URL filter
architecture.

## Consequences

- The operating system performs the comparison against a signed prefilter and a
  private lookup, so the app learns nothing about what the user requested.
- The feature depends on Apple granting a capability and approving a relay
  configuration, so it is gated separately from the local-analysis release.
- Coverage depends on the networking each app uses. The disclosure says this
  before the user turns it on, not after something fails to be blocked.
- The consumer default is fail-open: a filter that cannot decide must not take
  the device's connectivity with it.
