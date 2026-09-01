# ADR-002 — No packet tunnel as a generic filter

**Status:** accepted

## Decision

`NEPacketTunnelProvider` is excluded from the consumer filtering MVP.

## Context

A packet-tunnel provider is an IP-tunnelling technology. Using one to inspect
and block traffic means reassembling flows without the application metadata a
content filter is given, and it means presenting a VPN to the user for something
that is not a VPN.

## Consequences

- Consumer prevention uses Apple's iOS 26 URL Filter, where iOS performs the
  check and Fire Privacy never receives the requested URL.
- Live, app-attributed allow/drop filtering is a Managed Edition capability on
  supervised devices, using `NEFilterDataProvider`.
- A real VPN may be added later only as a disclosed, separately architected
  product with its own privacy commitments.
