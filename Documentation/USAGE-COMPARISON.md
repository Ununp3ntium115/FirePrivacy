# Compare reported activity with supplied usage

Apple sources retrieved with normal TLS on October 6, 2026 support two different
inputs: APR reports sensor/data access and domain contacts; Screen Time reports
foreground usage. Comparing their timestamps can identify something to review.
It cannot establish that Apple or an app misreported activity, that sensor data
was transmitted, or that an app acted improperly.

The Core comparison, file import and native editor/comparison controls are
implemented. Their matching hosted native runtime validation is pending.
This guide separates their data contract from platform access and device QA;
it does not claim an installed automatic Screen Time collector. The dated
[source record](USAGE-COMPARISON-SOURCES.json) contains response hashes, status,
availability and extracted official text. Existing native results do not cover
these subsequent additions.

## What can be compared

| Input | What it supports | Limits to preserve |
| --- | --- | --- |
| Imported APR timestamp | Compare the recorded instant with supplied usage coverage/windows | Original file identity, line, timestamp text and supported precision remain visible; the file is not an independently authenticated Apple statement |
| APR network first/last bounds | Compare the supplied endpoint timestamps | Intermediate hits have no individual timestamps; total hits are contact frequency, not bytes or a background-contact count |
| APR sensor begin/end | Compare supported recorded timestamps and unambiguous candidate pairs | A missing/ambiguous endpoint has unknown extent; even a candidate pair does not independently prove uninterrupted sensor access |
| User recollection | Compare remembered windows when explicitly marked as describing this device | Memory and any completeness assertion remain unverified; missing windows can be forgotten use |
| User-transcribed Screen Time | Compare reported aggregate duration over the specified device/time bucket | A positive total does not locate sessions; zero is a reported value, not proof of inactivity; rounding, device combination and freshness matter |
| Imported Shortcuts/external usage log | Compare supported recorded open/close pairs with their provenance | Events can be delayed, missing, duplicated or disabled; pairing does not certify a complete OS history |
| Special authorized Apple usage export | On eligible systems, compare per-app foreground-duration buckets with returned device/filter/freshness context | This requires a separate iOS/iPadOS 26.4+ data-access route and authorization; it is not included in the current Xcode 26.2 consumer implementation |

For example, an APR network record with seven hits, first contact at 20:05 and
last contact at 20:25, compared with a supplied 20:00–20:10 window, has mixed
reported timestamps. It does not establish that seven contacts happened after
20:10. Likewise, a sensor pair spanning a window can have endpoints outside it;
describe endpoint alignment rather than inventing continuous background access.

Comparisons require the same observed app identifier, an explicit coverage
interval/time zone and a same-device claim explicitly bound to the selected APR
report. Different/combined devices, an unspecified device scope or an unbound/
different report remain unknown. Overlapping and contradictory
references are retained separately. A result outside claimed complete windows,
or during reported zero usage, can suggest review while retaining those claims'
limitations. Boundary timestamps are treated conservatively as overlapping.

Usage comparisons remain distinct from deterministic publisher findings and
posture. Preserve their reference IDs, provenance, coverage and timeline digest;
an advisor must not turn them into verified facts or infer harmful intent.
If an advisor starts incorporating them, its context/approval must bind that
digest and reject stale results. No new network purpose, packet capture or
silent permission change is needed for local comparison.

## APR and ordinary Apple usage APIs

[About App Privacy Report](https://support.apple.com/en-us/102188) says APR starts
gathering only after it is enabled. Data & Sensor Access shows how often and
when privacy-sensitive data/sensors were accessed over the past seven days.
Network sections list contacted domains, including embedded app content and
websites. Network activity from private browser sessions is excluded. These
coverage limits prohibit treating an empty result as complete inactivity.

That support article does not specify a stable exported NDJSON field schema or
a universal per-event foreground/background flag. Fire Privacy preserves fields
its importer supports, their raw context and provenance; undocumented numeric
values or context strings do not become a verified app state.

[DeviceActivityEvent](https://developer.apple.com/documentation/deviceactivity/deviceactivityevent)
defines device activity as time an application/category/web domain is
"frontmost on the screen," accumulated in the schedule's start time zone.
[DeviceActivityCenter](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter)
provides scheduled interval and threshold callbacks. They do not supply an
unrestricted retrospective callback stream for every other app's opens/closes.

The ordinary [FamilyActivityPicker](https://developer.apple.com/documentation/familycontrols/familyactivitypicker)
uses opaque selections. [DeviceActivityReport](https://developer.apple.com/documentation/deviceactivity/deviceactivityreport)
provides a privacy-preserving view through a report extension. Apple explicitly
says its sandbox prevents network requests and moving sensitive content outside
the extension's address space. It is not a supported route for copying private
report data into the host app's general model/storage.

Ordinary reports require Family Controls authorization. Individuals can
authorize their own device; child authorization needs a parent/guardian in the
same Family Sharing group. [Distribution permission](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)
is requested by the account holder for the app and relevant Screen Time
extensions. Adding entitlement text does not establish that permission.

`DeviceActivityAuthorization` is documented from iOS/iPadOS 17. Its authorization
checks/client identifiers do not themselves expose a usage timeline. It must
not be confused with the special data-access API below.

The [Screen Time framework](https://developer.apple.com/documentation/screentime)
documents web-usage reporting, history deletion and responses to parental web
restrictions. Its presence is not a general other-app foreground-session export
API.

## iOS/iPadOS 26.4 authorized data access

Current official DocC marks these APIs/capability as introduced in **26.4**:

- [FamilyActivityData](https://developer.apple.com/documentation/familycontrols/familyactivitydata)
  returns actual installed-app bundle identifiers, visited domains and category
  names when authorized, instead of only opaque representations.
- [DeviceActivityData.activityData(filteredBy:using:)](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/activitydata(filteredby:using:))
  exports device activity using the requested filter/policy.
- [approvedWithDataAccess](https://developer.apple.com/documentation/familycontrols/authorizationstatus/approvedwithdataaccess)
  and [Family Controls App and Website Usage](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls.app-and-website-usage)
  are required for this access. Explicit person/parent/guardian authorization
  applies. Only one app can hold data-access authorization on the device;
  granting another returns the previous app to `notDetermined`.

Customer installations can use the route only on devices located in the EU and
signed in with an EU-country/region Apple Account. Apple allows development/testing
in other regions with the appropriate Apple-provided provisioning profile;
that is not worldwide customer eligibility. Check actual authorization/API
results; a locale setting or location guess is not an entitlement/eligibility
check. Request no extra location permission just to infer eligibility.

The exported structure includes application `totalActivityDuration` within
activity segments. The documented segment cases are hourly, daily and weekly.
[hourly(during:)](https://developer.apple.com/documentation/deviceactivity/deviceactivityfilter/segmentinterval-swift.enum/hourly(during:))
aggregates into hours and disregards smaller date components. Querying a
one-minute filter interval does not manufacture one-minute session data.
`ActivitySegment.longestActivity` is one longest activity session in that
segment; `firstPickup` is the device's first pickup. These fields belong to the
device segment, not a per-application session list. Show the actual filter and
do not invent an app attribution or every app's exact start/stop intervals.

Preserve the returned device, filter, time bucket, time zone, `lastUpdatedDate`
and policy. Device model/name alone is not a documented unique current-device
identity. Screen Time can combine devices when Share Across Devices is enabled.
Even [Policy.live](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/policy/live)
may return recently refreshed cached data. No source inspected promises complete
exact per-app session history or a cache-free live stream.

An automatic integration would need an SDK containing 26.4 symbols, availability
guards, actual signed capability/provisioning, explicit data-access authorization,
region eligibility and runtime tests. It would also need independent consent,
accurate privacy/disclosure updates, revocation cleanup and protected local
storage. The current Xcode 26.2 target has no such usage capability or adapter;
this guide does not add it. These particular APIs are not first introduced in 27.

## User-configured local Shortcuts logs

Apple's [iOS 26 App trigger guide](https://support.apple.com/guide/shortcuts/apde31e9638b/9.0/ios/26)
defines **Is Opened** as opening or switching to the selected app and **Is Closed**
as closing or switching from it. Users can configure personal automations and
allow App automations to [run without asking](https://support.apple.com/guide/shortcuts/enable-or-disable-a-personal-automation-apd602971e63/9.0/ios/26).
This logs configured events prospectively; it cannot recover missed events or
past history before setup.

1. Choose the app in Shortcuts and copy its exact identifier from the imported
   APR in Fire Privacy. This is a user-established mapping, not installed-app
   enumeration or independently verified attribution.
2. Create one personal App automation for **Is Opened** and another for
   **Is Closed**, for that selected app. Enable automatic execution if desired;
   labels differ by OS version. Test both while using the actual device.
3. At each trigger, capture Current Date and format an ISO8601 timestamp with
   an explicit zone, such as `2026-10-06T20:05:00+02:00`. This is the time the
   automation captures, which may differ from the exact app transition.
4. Initialize a dedicated local `usage-events.txt` with the coverage header
   below; do not write to the APR file. Write one compact JSON event per line
   to a Files location the actions can access. Serialize the three-field record
   as JSON so its strings are escaped. Use an available append action, or read
   existing text, combine it with the new record/newline, and Save File back to
   the same file.
   Confirm file/action permissions and behavior on the device. The official
   [file-actions guide](https://support.apple.com/guide/shortcuts/share-actions-apdaf74d75a5/ios)
   documents Save File and file-action discovery; it does not establish one
   universal built-in append-action name or reliable atomic multi-writer logging.
5. Set known coverage and same-device provenance, keep completeness false when
   there may be gaps, and import the supported event format below into the
   explicitly selected APR report. Verify the coverage end reflects the period
   you are actually comparing. Test a normal pair plus missing/duplicate events
   before trusting the workflow. Re-import revised logs deliberately rather
   than silently replacing previous evidence.

Use a local Files provider if the records should remain on that device. A chosen
cloud-backed Files provider, shared shortcut or other action has its own storage
and recipient behavior. Those original files are outside Fire Privacy's encrypted
workspace/deletion control. No record is sent to an advisor/update host by this
logging workflow.

## Reference JSON interchange

The Core reference importer accepts schema 1 with `references`. This is
app-defined interchange, not an Apple export format. Native UI/runtime
verification is pending. The [resource schema](../Sources/FirePrivacyCore/Resources/UsageTimeline/usage-timeline.schema.json),
[format notes](../Sources/FirePrivacyCore/Resources/UsageTimeline/USAGE-FORMAT.md)
and implementation tests are the authority for the integrated source.

```json
{
  "schemaVersion": 1,
  "references": [
    {
      "bundleID": "com.example.synthetic",
      "provenance": "importedUsageLog",
      "deviceScope": "sameDeviceAsReport",
      "coverage": {
        "start": "2026-10-06T20:00:00+02:00",
        "end": "2026-10-06T21:00:00+02:00"
      },
      "claimsCompleteForegroundWindows": false,
      "foregroundWindows": [
        {
          "start": "2026-10-06T20:05:00+02:00",
          "end": "2026-10-06T20:10:00+02:00"
        }
      ],
      "sourceLabel": "Synthetic local open/close log"
    }
  ]
}
```

- Required reference fields are `bundleID`, `provenance`, `coverage`,
  `claimsCompleteForegroundWindows` and `foregroundWindows`.
- Provenance is exactly `userRecollection`, `userTranscribedSystemUsage` or
  `importedUsageLog`; none is independently verified telemetry.
- `deviceScope` is `sameDeviceAsReport`, `otherDeviceOrCombined` or `unspecified`;
  omission is unspecified, which cannot establish same-device review signals.
  Its same-device claim must also be explicitly bound to this report through
  optional `comparisonReportID` (UUID), or through the app's selected-report
  import/edit action. This remains a user claim, not device attestation. A
  reference bound to another report is not silently rebound when selection changes.
- Optional fields are `id` (UUID), `aggregateForegroundSeconds` (finite number),
  `sourceLabel` and `suppliedAt` (zoned ISO8601). All coverage/window timestamps
  need explicit time zones and ordered bounds; windows must lie within coverage.
- An aggregate-only reference has empty windows and false completeness. Its
  duration must be nonnegative and no greater than its coverage interval.
  It is not converted into synthetic sessions.
- The importer limits JSON to 1 MiB, references to 128, references per app to 8,
  windows per reference to 128 and total windows to 2,048, with bounded depth
  and strings (maximum nesting depth 12). Unknown/duplicate fields and conflicting identities are rejected.
  Re-importing changed content under an existing ID requires an explicit edit,
  not silently overwriting provenance.

## Opened/closed NDJSON interchange

The source [event importer](../Sources/FirePrivacyCore/AppUsageEventLogImporter.swift)
is implemented and its 12 targeted Core tests pass. This is separate from the
reference JSON format and from native/device validation. See the
[event-line schema](../Sources/FirePrivacyCore/Resources/UsageTimeline/usage-event-log.schema.json)
and [synthetic file](../Sources/FirePrivacyCore/Resources/UsageTimeline/usage-events-example.ndjson).

The first nonempty line is a coverage object; each subsequent nonempty line is
exactly one event object. For example:

```ndjson
{"type":"coverage","schemaVersion":1,"start":"2026-10-06T20:00:00+02:00","end":"2026-10-06T21:00:00+02:00","claimsCompleteForegroundWindows":false,"deviceScope":"sameDeviceAsReport","bundleIDs":["com.example.synthetic"],"sourceLabel":"Synthetic local open/close log"}
{"bundleID":"com.example.synthetic","event":"opened","timestamp":"2026-10-06T20:05:00+02:00"}
{"bundleID":"com.example.synthetic","event":"closed","timestamp":"2026-10-06T20:10:00+02:00"}
```

The header requires `type: "coverage"`, `schemaVersion: 1`, zoned ISO8601
`start`/`end`, and boolean `claimsCompleteForegroundWindows`. Optional fields
are `deviceScope`, unique `bundleIDs` and `sourceLabel`; no other fields are
accepted. Each event contains exactly `bundleID`, `event` (`opened` or `closed`)
and zoned ISO8601 `timestamp`. Empty lines are allowed; comments or extra fields
are malformed records. The header is not an Apple attestation.

The parser pairs events in file order, separately for each app. It retains
completed valid pairs and does not sort away errors or invent an opening,
closing, clipped boundary or duration. An unmatched open/close, duplicate open,
earlier timestamp or event outside coverage downgrades that app's completeness
claim. A malformed record attributable to an app downgrades that app; a malformed
record with no reliable app identity downgrades all completeness claims and
clears pending opens. A declared app with no events produces a warning; any
retained completeness is the explicit unverified header assertion, not something
deduced from absence.

The limits are 1 MiB total, 16 KiB per line, 10,000 event records, 128 apps,
128 paired windows per app and 2,048 pairs overall. At most 256 warning records
are retained, with an explicit truncation flag. Warning codes are `invalidRecord`,
`unmatchedOpened`, `unmatchedClosed`, `duplicateOpened`, `outOfOrder`,
`outsideCoverage` and `noEvents`; malformed contents are not echoed. The import
result also records the source SHA-256, event count and pair count.

Imported event references initially have no report binding. The app's explicit
selected-report import attaches a supplied `sameDeviceAsReport` claim; unknown/
other-device scope does not become same-device by import. Completeness remains
an unverified user claim even if every parsed event formed a pair. Two automations
can race or lose writes, and a syntactically valid file need not contain every
transition. No OS usage entitlement is added by this local file route.

## Interpreting a discrepancy

Show the recorded timestamp, usage source/device/coverage and its actual
precision before offering review. Activity outside supplied windows can have
legitimate explanations such as background refresh, notifications, uploads,
navigation/audio, extensions or system services; a source mismatch, rounded
total, stale summary or missed automation is another possibility. These are
possibilities to investigate, not conclusions about the imported record.

Keep raw APR context visible as reported text, keep user recollection distinct,
and describe any conflict. Absence of a discrepancy does not certify privacy,
inactivity or complete logging. Timing alone does not establish what data was
sent, unlawful behavior, deception or a mismatch in Apple's reporting.
