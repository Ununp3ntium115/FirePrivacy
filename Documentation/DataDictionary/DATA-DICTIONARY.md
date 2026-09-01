# Data dictionary

Every field Fire Privacy stores, and whether it came from Apple, from the user,
or from Fire Privacy's own inference. The distinction is load-bearing: the UI
must never present an inference as an observation (DET-003).

## ImportSession

| Field | Source | Notes |
| --- | --- | --- |
| `id` | derived | content-derived UUID, stable for the same file and clock |
| `sourceHash` | derived | SHA-256 of the imported bytes; duplicate detection |
| `sourceFilename` | user | sanitized, length-bounded |
| `importedAt` | device | local clock |
| `reportStart` / `reportEnd` | inferred | min/max timestamp across records; `nil` means unknown and is shown as unknown |
| `parserVersion`, `normalizationVersion` | Fire Privacy | stamped on every record |
| `recordCount`, `invalidCount`, `unknownCount` | derived | shown on the import summary |
| `rawCopyState` | user | `none` by default |
| `status` | derived | `complete`, `partial`, `failed` |
| `isDemoData` | Fire Privacy | drives the demo watermark |

## NetworkObservation

| Field | Source | Notes |
| --- | --- | --- |
| `host` | Apple, normalized | canonical ASCII form |
| `host.displayValue` | derived | Unicode form; both shown so a homograph cannot hide |
| `registrableDomain` | inferred | from the versioned public-suffix list |
| `context` | Apple | website context; encrypted at rest |
| `hits` | Apple | **contact frequency, never data volume** |
| `domainType` | Apple | preserved verbatim, including values Fire Privacy does not recognize |
| `domainOwner` | Apple | preserved as reported, sanitized |
| `initiatedType` | Apple | preserved |
| `sourceLineHash`, `sourceLineNumber` | derived | evidence linkage without keeping the bytes |
| `mergedRecordCount` | derived | how many report lines were folded together |
| `normalizationWarnings` | derived | every transformation applied, as stable identifiers |

## SensorObservation

| Field | Source | Notes |
| --- | --- | --- |
| `sensorType` | Apple | unknown categories preserved as `other:<value>` |
| `count` | derived | counts `intervalBegin` edges only, so paired records are not double counted |
| `firstTimestamp` / `lastTimestamp` | Apple | window, not a continuous-running claim |

## Finding

| Field | Source | Notes |
| --- | --- | --- |
| `id` | derived | hash of rule, version, subject and evidence; stable across runs |
| `severity` | inferred | impact/breadth/persistence; independent of confidence |
| `confidence` | inferred | evidence combination with a correlation penalty |
| `observedFacts` | Apple / user | direct record fields only |
| `inferences` | Fire Privacy | the rule's interpretation, separated from the facts |
| `uncertainty` | Fire Privacy | what the finding does not establish |
| `isStale` | derived | true when the knowledge base has expired |

## SelfReportedPermission

Entirely user-entered, stored separately from anything Apple reported, and
always labeled as user-entered. Fire Privacy cannot read another app's current
permission state (PER-001, PER-005).
