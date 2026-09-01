# Rule change log

Rules are versioned independently of the app. A finding records the rule ID and
version that produced it, so a difference between two runs can always be
attributed.

## ruleset-1.0.0 — 2026-08-31

Initial rule set.

| Rule | What it says | Deliberate limit |
| --- | --- | --- |
| `AGG-APPLE-001` | Apple's own export marks the domain as a possible cross-app or cross-site collector | Never claims malware or unlawful conduct; never claims payload content |
| `AGG-CROSSAPP-002` | The same third-party domain appears under at least three unrelated publishers | Suppressed for CDN, authentication, push, payments and fraud-prevention infrastructure; confidence drops when contacts came from embedded web content |
| `LOC-NET-003` | Location access and location-data infrastructure were observed for the same app in the same window | Explicitly labeled a temporal relationship, not a transmission |
| `SENSOR-UNEXPECTED-004` | The user marked a sensitive access as unexpected | Raises severity one level; still states that the current setting is unknown |
| `UNKNOWN-HIGHFANOUT-005` | One app contacts many services whose purpose is unclassified | Medium confidence at most; unknown is reported as unknown, not as risk |
| `VENDOR-KNOWN-006` | A reviewed data-broker or location-intelligence endpoint was contacted | Requires review status `reviewed` and a citable source; wording describes documented business, not conduct |
| `COVERAGE-GAP-007` | Blockable destinations are present and available protection is off | Only when the OS supports the filter; states coverage limits and breakage risk |
| `FRESHNESS-008` | The report is more than 14 days old | Info severity; says that no new data is not the same as no change |

### Rules deliberately not shipped

- Anything that infers an app's *purpose* from its domains alone.
- Anything that scores an unknown owner as high risk.
- Anything that concludes data was transmitted from a sensor/network
  correlation.
