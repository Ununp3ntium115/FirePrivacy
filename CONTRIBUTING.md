# Contributing

## The rules that are not negotiable

1. **Never claim more than the evidence supports.** A contact is a contact, not a
   transmission. A hit count is frequency, not volume. An unknown owner is
   unknown, not dangerous.
2. **Deterministic first.** Findings come from versioned rules. A model may
   rephrase; it may not decide.
3. **No new network call without a ledger entry.** If you add one, add it to
   `NetworkLedger.entries` — that table is what the user reads in the Trust
   Center, and it must be true.
4. **Treat imported strings as hostile.** Wrap them in `UntrustedText` at the
   boundary and never concatenate them into instructions, markup or queries.
5. **Never claim protection is active when it might not be.** Every failure path
   must land in a state the UI can name.

## Before you open a pull request

```bash
swift build
swift test
./Tests/PrivacyRegression/no-network-in-local-analysis.sh
```

A change to a rule also needs:

- positive and negative test vectors;
- an entry in `Rules/CHANGELOG.md`;
- the uncertainty wording that goes with it.

A change to a vendor classification also needs:

- a citable source in the knowledge base;
- review status `reviewed` for data-broker or location-intelligence categories;
- neutral wording — the classification describes documented business, not
  conduct.

## Style

- Swift 6 language mode, strict concurrency, no force-unwrap in parsing, crypto,
  persistence or Network Extension code.
- No business logic in SwiftUI views.
- Comments explain *why*, not what the next line does.
