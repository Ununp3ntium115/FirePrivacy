# Analysis rule configuration

## 1.0.0

Reviewed initial configuration for the eight compiled `ruleset-2.0.0` detectors. All detectors are enabled. Default thresholds preserve the initial implementation: at least three apps sharing a destination, at least ten destinations with strictly less than 40% reviewed coverage, and latest activity/import strictly older than fourteen days.

This configuration controls detector selection and bounded thresholds. It cannot add executable code, detectors, prose, categories, actions, severity, confidence, network requests, publisher identities, or knowledge-source claims. Reviewed infrastructure suppression, verified source requirements, manual unexpected-access decisions, and actual protection availability checks remain in compiled code.

Disabled detectors suppress findings and affect finding-derived score dimensions. Raw observations and reviewed classification coverage remain unchanged; the optional overall summary is withheld when any detector is disabled. A rule revision is an interpretation change, not new exported activity.

`default-rules.sha256` identifies the exact bundled JSON bytes. `default-rules.canonical-sha256` identifies normalized configuration JSON as produced by the Swift encoder (fixed detector order, sorted field names). The bundled loader validates that the document exactly matches compiled defaults. New independent configurations require a trusted signed envelope and increasing sequence and semantic version; this file contains no production private key or fabricated signature.

Payload format is documented in `rule-configuration.schema.json`. Signed manifests use the separate `FirePrivacy.AnalysisRules.v1` canonical LF domain separator and a maximum ninety-day lifetime. Cryptographic acceptance does not replace editorial review of parameter changes.
