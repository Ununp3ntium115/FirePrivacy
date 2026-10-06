# Required-reason API audit — October 6, 2026

The shipped app now directly calls `Darwin.fstat` in
`Apps/FirePrivacyApp/EncryptionKeyRotation.swift`, within
`RotationDurability.synchronize`. The helper opens a file or directory using
`O_NOFOLLOW`, reads `st_mode` to verify the expected regular-file/directory type,
then synchronizes durability. The filesystem checks and rotation journals concern
owned private app-container storage and cleanup markers. This reads metadata
even though it does not read, display, serialize or transmit file timestamps.

Apple's current
[NSPrivacyAccessedAPIType documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
explicitly lists `fstat(_:_:)` under
`NSPrivacyAccessedAPICategoryFileTimestamp`. Its approved reason is:

> C617.1 — Declare this reason to access the timestamps, size, or other metadata
> of files inside the app container, app group container, or the app’s CloudKit
> container.

The owned-container file-type checks match that purpose. The app privacy
manifest declares that category with C617.1; generator/project audits must
preserve it. A different category reason is not needed merely because the helper
checks metadata rather than timestamps. The public guideline and current DocC
JSON were retrieved with normal HTTPS certificate/hostname verification on
October 6, 2026. The detailed source JSON is 50,617 bytes, SHA-256
`19546c6db12067a6e6441140399e8323fd73d5e79d1c682e1d0b826b16da6cf5`.
The traceable record is in
[APPLE-OPTIONAL-SOURCE-VERIFICATION](APPLE-OPTIONAL-SOURCE-VERIFICATION.json).

The current source search found no direct covered stat-family call in
`ReportFileIO.readImportedData/readBoundedData`. Picker-selected imports use
`isRegularFileKey`, `fileSizeKey` and bounded FileHandle reads. Those properties
are not listed by the retrieved FileTimestamp category. Apple separately defines:

> 3B52.1 — Declare this reason to access the timestamps, size, or other metadata
> of files or directories that the user specifically granted access to, such as
> using a document picker view controller.

That reason applies if a covered API is later used directly for the external
selected document. No such direct use was found in this source revision, so it
is not declared speculatively. Extension manifests need reasons for their own
actual covered APIs; app-container fstat in the main app does not justify a
blanket declaration on unused extension targets. Operator CLI/Python and XCTest
filesystem calls are not shipped iOS code.

This audit establishes the declared-purpose match in source. Final native
archive privacy reports, included dependencies/manifests and App Store Connect
processing remain separate validation. Any new covered API or different scope
requires reviewing the declaration again.
