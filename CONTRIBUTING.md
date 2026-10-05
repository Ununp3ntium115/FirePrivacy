# Contributing

## The rules that are not negotiable

1. **Never claim more than the evidence supports.** A contact is a contact, not a
   transmission. A hit count is frequency, not volume. An unknown owner is
   unknown, not dangerous.
2. **Deterministic first.** The current candidate produces descriptive summaries
   from imported observations. Richer rules must be versioned and tested. A
   future model may rephrase a supported finding; it may not decide.
3. **Disclose every network operation.** The current candidate has no network
   client or generated ledger. Adding one requires an accurate ledger, Trust
   Center disclosure, consent where applicable, and updated privacy checks and
   policy. Do not reference a nonexistent `NetworkLedger.entries` implementation.
4. **Treat imported strings as hostile.** Use the parser's bounded validation
   and plain-text display. Never concatenate imported strings into instructions,
   markup, or queries. A future richer text model must preserve that boundary;
   the original `UntrustedText` module is not present in this candidate.
5. **Never claim protection is active when it might not be.** Every failure path
   must land in a state the UI can name.

## Before you open a pull request

```bash
swift build
swift test
./Tests/PrivacyRegression/no-network-in-local-analysis.sh
python3 -m unittest discover -s Tests/CloudRelease -p 'test_*.py'
```

A change to a rule also needs:

- positive and negative test vectors;
- a recorded version/change history (create the original planned rule registry
  and `Rules/CHANGELOG.md` when introducing that feature);
- the uncertainty wording that goes with it.

Introducing or changing vendor classification also needs:

- a citable source in the knowledge base;
- review status `reviewed` for data-broker or location-intelligence categories;
- neutral wording — the classification describes documented business, not
  conduct.

The signed knowledge base, versioned classification rules, filtering, and AI
adapters are original concepts awaiting implementation. Preserve their accuracy
and governance requirements rather than claiming they already exist. See
[FEATURE-COVERAGE.md](Documentation/FEATURE-COVERAGE.md).

## Style

- Swift 6 language mode, strict concurrency, no force-unwrap in parsing, crypto,
  persistence or Network Extension code.
- No business logic in SwiftUI views.
- Comments explain *why*, not what the next line does.
