# ADR-009 — Ollama is an optional endpoint, not an assumed iPhone service

**Status:** accepted

## Decision

Treat a local model as a machine the user operates and explicitly selects.

## Context

There is no Ollama daemon on iOS. Any product copy implying otherwise would be
false.

## Consequences

- The mode is off by default and requires host selection, a connection test, TLS
  with a pinned certificate outside developer builds, and a preview of the exact
  fields that will leave the iPhone.
- There is no automatic fallback from a local endpoint to any public cloud.
- The raw report is never sent in this release.
