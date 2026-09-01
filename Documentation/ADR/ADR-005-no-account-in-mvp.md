# ADR-005 — No account in the MVP

**Status:** accepted

## Decision

Every core feature works locally with no sign-in, and no account system exists.

## Consequences

- No server holds anything about a user, so there is nothing to breach, subpoena
  or correlate.
- Sync between devices is not available. That is the cost, and it is the right
  trade for a first release of a privacy product.
- If an account is added later it must be optional, must not gate analysis, and
  must ship with in-app deletion.
