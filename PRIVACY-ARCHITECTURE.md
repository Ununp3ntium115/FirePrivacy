# Fire Privacy — privacy architecture

This document states what Fire Privacy does with data. It is written so that a
reviewer can check each claim against the source.

## 1. Default: nothing leaves the device

Importing a report, normalizing it, matching domains, building findings, scoring,
exporting and deleting all happen on the device with **no network request**.

That is enforced structurally rather than by intention: the modules on the
local-analysis path (`ObservationCore`, `AppActivityImportKit`, `FindingEngine`,
`PrivacyProfileKit`, `ObservationStore`, `ReportKit`, `ConsentKit`) contain no
networking API at all. `Tests/PrivacyRegression/no-network-in-local-analysis.sh`
fails the build if one is introduced.

## 2. The complete network ledger

| Purpose | When | Carries data about you |
| --- | --- | --- |
| Import and analysis | never connects | — |
| Knowledge-base update | only if enabled | no |
| Filter list update | only while protection is on | no |
| System URL filter lookups | performed by iOS, not by the app | no (Fire Privacy never receives the URL) |
| Your own model endpoint | only if you configure one | yes — the previewed structured summary |
| Sharing an export | only when you tap share | yes — whatever you chose to include |

The same table is shown in the app's Trust Center, generated from
`NetworkLedger.entries`.

## 3. What is stored, and where

| Data | Storage | Default retention |
| --- | --- | --- |
| Your original file in Files | untouched | never modified |
| Temporary import copy | app temp directory | deleted at end of import |
| Encrypted raw copy | off | off unless you turn it on |
| Normalized observations | encrypted file per session | user-controlled |
| Findings, scores | same encrypted file | same as observations |
| Explanations | in memory, cache invalidated when the finding changes | until the finding changes |
| Consent receipts | local | until deleted |
| Protection state, verified prefilter | App Group | while protection is on |

Raw report data is **never** written to the App Group that extensions can read.

## 4. Encryption

- AES-GCM per record, with a versioned envelope so keys can be rotated.
- The root key is 32 random bytes in the Keychain with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and no iCloud synchronization.
- Files are written with complete file protection.
- "Delete all Fire Privacy data" removes the ciphertext **and destroys the key**,
  so anything that survived is unreadable.

## 5. Untrusted input

Everything in an imported file is untrusted: domains, app names, owner strings,
contexts. They are:

- length-bounded and stripped of control characters, bidi overrides and
  zero-width characters on import (`UntrustedText`);
- never rendered as markup, never concatenated into SQL, never concatenated into
  model instructions;
- passed to a model only as typed fields in `AdvisoryInput`, which is the entire
  surface a model can see.

The parser enforces structural limits while parsing: nesting depth, string
length, duplicate keys, invalid UTF-8 and oversized lines each quarantine a line
with a reason rather than being partially believed.

## 6. AI boundary

- The deterministic rules engine decides everything. A model only rephrases.
- Model output is validated before display: evidence IDs must exist, action IDs
  must exist *and* be possible on this device, and the text may not claim payload
  visibility, a current permission state, a legal conclusion, or more certainty
  than the finding carries.
- Failing validation falls back to the deterministic explanation, and the UI says
  which mode actually produced the text.
- Private Cloud Compute is described as **server-side Apple processing**, never as
  on-device processing, and is disabled until Apple ships it in a production
  release.
- Ollama is not assumed to exist on iOS. A local endpoint is a machine the user
  runs, requires TLS with a pinned certificate outside developer builds, and
  shows the exact fields that will leave the iPhone.

## 7. What Fire Privacy will never do

- Create an advertising identifier or fingerprint the device.
- Combine report data across users.
- Sell, license or share report data.
- Use imported data to train a model.
- Enroll anyone in a research dataset.
- Transmit a first-party analytics event when diagnostics are off.

## 8. Accuracy commitments

- A domain contact is reported as a contact, never as a transmission.
- A hit count is described as contact frequency, never as data volume.
- Sensor/network correlation is labeled temporal, never causal.
- An unknown owner is reported as unknown, never as dangerous.
- Words like "malicious", "illegal", "spying" and "stolen" require stronger
  evidence than a hostname and never appear in routine heuristic findings.
