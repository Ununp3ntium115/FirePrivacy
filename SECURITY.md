# Security

Fire Privacy's first release is a local App Privacy Report reader. Its primary
security boundaries are hostile imported files, encrypted app storage, the
device-only Keychain key, and explicit plaintext exports.

## Reporting

Use the project's public issue tracker for ordinary bugs and privacy-policy
questions. Do not publish a personal App Privacy Report, private device activity,
credentials, or a sensitive vulnerability reproducer. For a sensitive issue,
request a private reporting channel from the maintainer before sharing details.
No private security email or response-time commitment has been verified yet.

Use a minimal synthetic example where possible. Include the app and operating
system versions and the expected versus observed behavior.

## Implemented boundaries

- The core importer bounds file, line, record, nesting, collection, and string
  sizes; invalid UTF-8, duplicate keys, unsafe displayed identifiers, unsupported
  records, and invalid numerical data are rejected or quarantined.
- Imported strings are plain text and are not executed, rendered as HTML,
  interpolated into SQL, or sent to a model.
- There are no networking, analytics, advertising, model, filtering, or
  third-party SDK APIs on the shipping app's local-analysis path.
- One normalized report is authenticated and encrypted with CryptoKit AES-GCM.
  A random 256-bit key is held in the device-only, unlocked Keychain. Local files
  use complete protection and backup exclusion.
- Failed decryption or a missing key does not silently replace existing data.
  Deletion failures are reported instead of claiming completion.
- Export is an explicit plaintext-sharing action with a privacy warning and
  temporary-file cleanup. Original and previously shared files are outside the
  app's deletion boundary.
- Routine app code does not log imported domains, identifiers, or report data.
  The scene cover hides report content when the app becomes inactive.

## Verification and future work

See [VALIDATION](Documentation/VALIDATION.md) for actual test results. Linux core
and structural checks do not prove Apple-platform storage, backup, device-lock,
or UI behavior; the Apple test targets and physical-device release checks are
required before submission.

The original architecture proposed signed knowledge bases, filters, and model
adapters. Those are not implemented in this first release. Any later network
service, extension, dependency, or data use needs a reviewed threat model,
updated disclosures, capability permissions where applicable, and meaningful
security tests before release.

Never commit signing keys, certificates, provisioning profiles, passwords, or
App Store Connect credentials. Keep private `.p8` files outside the checkout.
