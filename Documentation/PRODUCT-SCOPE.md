# Fire Privacy: local report MVP

This document describes the app being built in this checkout. It supersedes the
earlier repository descriptions where they refer to modules or capabilities
that are not included in this app. It is a scope description, not evidence of a
successful device build or App Store approval.

Fire Privacy lets someone import an App Privacy Report exported from iPhone or
iPad Settings, then explore the app identifiers, contacted domains, and recorded
sensor access in that file. Analysis is descriptive. A contact is not proof that
personal information was transmitted, and a recorded sensor access does not
reveal the permission's current state. The report is historical and may be
incomplete.

The app includes a clearly labeled synthetic example for people who do not have
a report yet. It keeps one imported report on the device, encrypted using
Apple's CryptoKit and a key in the device Keychain. Importing another report
replaces the stored report. Export is an explicit action through the system
share sheet. Deleting the report removes the app's stored copy and encryption
key; it does not delete the original file in Files or copies previously shared.

The MVP has no account, subscription, ads, analytics SDK, remote analysis, AI
service, VPN, URL filter, Safari extension, knowledge-base download, live traffic
inspection, or claim that it can change another app's permissions. It makes no
tracker, ownership, maliciousness, legal, or security classification of the
domains in a report. The earlier proposals for those features remain future
ideas rather than shipping functionality.

## Release evidence

The release checklist in [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) separates
checks that can run in this Linux workspace from checks requiring Xcode,
physical devices, an Apple Developer account, or App Store Connect. Public
metadata and policies must describe the build that is actually submitted.

## Report compatibility

The import instructions follow the normal Settings export workflow: Settings →
Privacy & Security → App Privacy Report → share/export the report to Files,
then select it in Fire Privacy. Availability, screen labels, and the exported
schema can vary by OS version. Import compatibility with a real, current
Apple-generated report on iPhone and iPad is a release check. Synthetic parser
fixtures alone do not establish that compatibility.

If an imported record is not supported, the app should describe that limitation
and retain the distinction between missing evidence and no activity. It must
never present imported text as executable content or as instructions.
