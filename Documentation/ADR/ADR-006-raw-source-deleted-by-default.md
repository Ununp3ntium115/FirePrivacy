# ADR-006 — The raw source file is deleted by default

**Status:** accepted

## Decision

Parse the selected file, store normalized observations, delete Fire Privacy's
temporary copy, and leave the user's own document untouched.

## Context

An App Privacy Report is a sensitive history: which apps someone uses, when, and
what those apps contacted. Keeping a second copy of it by default would make the
app a more attractive target than the thing it protects.

## Consequences

- Evidence linkage is preserved without the bytes: each observation keeps the
  line number and a hash of the source line.
- Re-running an analysis with new rules requires the user to re-import, unless
  they opted into keeping an encrypted copy.
