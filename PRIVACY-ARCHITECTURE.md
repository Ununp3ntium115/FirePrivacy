# Fire Privacy — first-release privacy architecture

This document describes the implemented MVP. Apple-platform behavior must still be verified on a supported simulator and physical device before release; see the validation record and release checklist.

## Data flow

The user chooses a file from Files. Fire Privacy reads a bounded copy into memory, validates supported newline-delimited JSON records, and derives descriptive app/domain summaries and evidence-linked findings. Unsupported or invalid lines are counted and explained. No raw input file is retained or modified.

The app stores one normalized report in its own Application Support directory. Persistence uses CryptoKit AES-GCM and a random 256-bit Keychain key with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The key is not synchronized through iCloud. Report files use complete file protection and are excluded from backup. A failed import or save does not publish a replacement report.

Export is initiated by the user after a privacy warning. It produces a readable normalized JSON file for the system share sheet. That file may contain sensitive app identifiers, domains, and timestamps. Fire Privacy cleans its temporary export after the share sheet closes and clears stale exports at startup; exported copies held by another app are outside its control. Export does not reproduce the original Apple file.

Delete-all removes the saved report, temporary exports, and its encryption key. Failures are surfaced; the app does not claim deletion completed after a storage error. Deletion cannot remove the user's original file or copies previously shared outside Fire Privacy.

The synthetic demo is labeled and is not persisted as a personal report.

## Network ledger

| Operation | App-operated network requests | Information shared |
| --- | --- | --- |
| Import, analysis, findings, persistence | None | None |
| Synthetic demo | None | None |
| Share export | None by Fire Privacy; the selected destination may transmit | User-selected readable report |
| Open policy/support link | System browser, only after the user opens a configured link | Browser/destination behavior applies |

There are no analytics, ads, accounts, remote updates, model adapters, VPNs, traffic filters, or third-party SDKs in this release. Future additions require an updated network ledger, consent design, manifest, privacy labels, and review.

## Untrusted input

The importer enforces input-size, line-size, record-count, nesting, text-length, duplicate-key, UTF-8, and numerical limits. Invalid records are quarantined rather than converted into invented observations. Displayed external strings are plain text, with control and direction-changing characters handled by the importer. Unsupported schemas remain unsupported; testing a synthetic fixture is not proof of compatibility with all Apple exports.

No imported string is executed as code, rendered as HTML, interpolated into SQL, or sent to a model. The local-analysis source has no networking APIs. The regression script guards that structural constraint; it does not substitute for runtime or storage tests.

## Accuracy

A contact is a contact, not proof of data transmission, tracking, wrongdoing, or harm. A hit count is frequency, not bytes. A sensor begin/end record may be part of one interval, so the app describes sensor event records rather than inventing an access count. Historical exports do not expose current permissions. Bundle identifiers are displayed as provided; no installed-app enumeration or verified app-name lookup is claimed.

Findings are descriptive and cite observations. The app supplies manual settings guidance and does not claim to change another app's permissions. No risk score, signed knowledge base, vendor attribution, causal sensor/network inference, or active protection is presented.

## Future scope

The original repository proposed signed knowledge-base updates, protection extensions, and optional model explanations. Those are future designs, not first-release features or implemented controls. They require separate implementation, capability approval where applicable, security testing, and revised disclosure before shipping.
