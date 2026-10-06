# Supplied usage references

`usage-timeline.schema.json` defines FirePrivacy's optional interchange format. `example.json` contains synthetic evidence. It is not Apple's native Screen Time export format and does not automatically read Screen Time.

A reference identifies an exact APR app bundle ID, evidence source, reporting coverage, device-scope claim and either exact foreground windows or an aggregate foreground duration. Timestamps require an explicit UTC or numeric offset and accept up to nine fractional digits. Both boundaries are closed. All source, completeness and same-device assertions remain independently unverified.

`claimsCompleteForegroundWindows: true` permits comparison of recorded APR timestamps within coverage against the supplied windows. Missing windows under an incomplete claim remain unknown. `deviceScope` must explicitly be `sameDeviceAsReport` and the claim must be explicitly bound to the selected APR report through `comparisonReportID` for any comparison or review signal; omitted, combined or other-device usage remains unknown. Screen Time's Share Across Devices can combine device histories.

Aggregate totals require an empty `foregroundWindows` array and `claimsCompleteForegroundWindows: false`. A positive total has no session locations. A zero total can flag a covered, supported APR timestamp for review as activity during **supplied zero reported foreground use**, while still proving neither inactivity nor iOS background classification.

Network first/last timestamps bracket hits; the comparison never distributes contacts across that interval or treats hits as bytes. Sensor begin/end events form a candidate interval only when the existing APR parser can pair exactly one of each by app, category and exact identifier. Unpaired events retain their timestamp evidence but have unknown interval extent. Conflicting sources are detected at the same recorded timestamp, not at unrelated endpoints with different coverage.

Imports are capped at 1 MiB, 128 references, eight references per app, 128 windows per reference and 2,048 windows overall. Duplicate JSON keys, unknown fields, invalid calendars, missing zones, reverse ranges, out-of-coverage windows, nonfinite, underflowing nonzero, or excessive totals and mixed aggregate/window references are rejected. The app stores normalized references through its authenticated encrypted feature store; explicit exports and external source files remain under the user's control.

## Opened/closed NDJSON logs

`usage-event-log.schema.json` and `usage-events-example.ndjson` describe a separate supplied event-log format. The first nonempty line is a coverage header. Subsequent lines contain exactly `bundleID`, `event` (`opened` or `closed`) and `timestamp`. `bundleIDs` can identify covered apps with no logged events; this remains an explicit unverified header assertion and produces a warning.

The importer pairs file-order events independently for each app. Missing opens/closes, duplicate opens, earlier timestamps and events outside coverage downgrade that app's completeness claim. Unattributable malformed records downgrade every claim and clear all pending opens. No guessed open, close, clipped boundary or gap duration is created. Valid completed pairs remain available, and warnings never echo malformed source contents. Imported references initially have no report binding; the app must attach a same-device assertion to the selected report through a user-directed import before comparing.

The event log is capped at 1 MiB, 16 KiB per line, 10,000 event records, 128 apps, 128 paired windows per app and 2,048 pairs overall. At most 256 warnings are retained, with an explicit truncation flag. Its supplied opened/closed semantics and completeness are not certified by iOS. Shortcuts App triggers may support logging opens or switches to an app and closes or switches away; a user-configured automation can miss or delay events.
