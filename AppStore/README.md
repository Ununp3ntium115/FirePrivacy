# App Store Connect package

These files are prepared submission text, not an uploaded or submitted app
record. Review them against the exact binary and enter the final data in App
Store Connect. No login is required by the app itself.

- `metadata.en-US.json`: proposed English name, subtitle, promotional text,
  keywords, categories, and fields requiring real account/deployment data.
- `description.en-US.txt`: description of the implemented local-report MVP.
- `review-notes.en-US.txt`: reviewer workflow and privacy/storage explanation.
- `SCREENSHOTS.md`: actual-build screenshot plan and verified accepted sizes.
- `privacy-policy.md`: source copy of the readable policy published on
  `gh-pages`, while the standalone site is not enabled.

The prepared name/subtitle/promotional text/keywords fit their character limits;
the description fits 4,000 characters. App Store name availability is determined
by the real app record and is not established by these local length checks.
Screenshots remain a separate deliverable and must come from the actual app.

Final account data includes the registered bundle identifier, SKU, version/build,
verified seller/copyright holder, review contact, privacy/support URLs, content
rights, availability, price, and current age-rating, privacy, export, and trader
answers. Do not enter `null`, explanatory draft strings, or invented contact data
as production metadata. Recheck privacy labels if the shipping app or its
dependencies change.

See [BUILDING.md](../Documentation/BUILDING.md) for the signed archive/upload
commands and [RELEASE-CHECKLIST.md](../Documentation/RELEASE-CHECKLIST.md) for
the checks required before review submission.
