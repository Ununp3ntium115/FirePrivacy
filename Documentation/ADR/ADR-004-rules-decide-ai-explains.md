# ADR-004 — Rules decide, AI explains

**Status:** accepted

## Decision

Deterministic, versioned rules produce every finding. A model may only rewrite a
finding in plainer words.

## Context

A privacy product's output is a claim about other people's software and, often,
about a named company. Claims must be reproducible, auditable and defensible.

## Consequences

- The same file, knowledge base, rule set and profile always produce the same
  findings — asserted by tests, not by hope.
- Everything works offline and on hardware without Apple Intelligence.
- Model output is validated against the finding and discarded if it invents
  evidence, invents an action, claims payload visibility, states a current
  permission, makes a legal claim, or overstates certainty.
- Turning AI off costs the user nothing but phrasing.
