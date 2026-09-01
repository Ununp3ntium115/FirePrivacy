# Release gates

Fire Privacy ships in stages so that a capability Apple has not granted cannot
block a release that does not need it.

| Gate | Scope | Status in this repository |
| --- | --- | --- |
| 0 | Apple capability validation: organization enrollment, URL filter entitlement, OHTTP relay request, PIR proof of concept, App Review consultation | Not started. The app is built so that none of it is a prerequisite. |
| 1 | Local analysis MVP: onboarding, demo report, import, streaming parser, normalized encrypted store, bundled knowledge base, deterministic findings, dashboard, app and domain detail, Trust Center, JSON/CSV/Markdown export, delete-all | **Implemented** |
| 2 | Guidance and comparison: privacy profiles, manual settings audit, report comparison, weekly local report, evidence graph, local overrides, signed knowledge-base updates | Mostly implemented; signed update *transport* is deliberately absent (`DisabledKnowledgeBaseTransport`) so the app makes no request until updates are switched on |
| 3 | iOS 26 protection: URL filter manager, control extension, signed Bloom filter, PIR service, Privacy Pass issuer, OHTTP integration, safe mode | Interfaces, state machine, dataset verifier, Bloom filter and disclosures implemented. The system bridge reports the capability as missing until Gate 0 completes. |
| 4 | Private advisor: deterministic templates, on-device adapter, structured output, grounding validation, evaluation suite, visible mode and off switch | Templates, schemas, validator, coordinator and fallback implemented. The Foundation Models call itself is stubbed pending SDK verification. |
| 5 | Optional network services: encrypted DNS, Safari content blocker, local model pairing | Types, disclosures and Safari rule list present; not wired to system configuration |
| 6 | Managed Edition | Not started |
| 7 | iOS 27 features (Private Cloud Compute) | Mode exists and is disabled; described as server-side Apple processing |

## Why capabilities are stubbed rather than guessed

`SystemURLFilterBridge` and `FoundationModelsBridge` are the only two files that
touch Apple frameworks the packages avoid. Each reports its capability as
unavailable and carries a `TODO(Gate n)` naming what must be verified on a
device before it is enabled.

The alternative — writing plausible-looking calls against an API that has not
been verified — would produce a build that appears to offer protection while
silently doing nothing. For a privacy product that failure mode is worse than
saying "not available in this build", which is what the Protection screen says
today.
