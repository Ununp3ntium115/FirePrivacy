# Draft App Store submission package

These files describe the expanded **consumer** implementation, which includes
Safari content blocking and encrypted-DNS settings, local analysis/history, and
optional constrained advisors. Verify against the working, signed consumer
binary before copying fields into App Store Connect. URL-filter and managed
editions need separate capability/operator/legal review and matching metadata.

- `metadata.en-US.json`: draft fields; legal identity/contact and App Privacy answers remain operator/account tasks.
- `description.en-US.txt`: verify feature visibility, then remove the draft instruction.
- `review-notes.en-US.txt`: replace provisional navigation with exact tested labels and supply actual review instructions.
- `privacy-policy.md`: revised policy source; root must publish it and verify the live URL before distributing the expanded binary.
- `SCREENSHOTS.md`: official dimensions; capture is paused until functionality/native validation is complete. Use actual screens with synthetic data.

Portable tests, native builds, signed archives, upload/processing, TestFlight QA,
review submission, approval and public release are separate statuses. None is
established by this package. See [Apple requirements](../Documentation/APPLE-REQUIREMENTS.md)
and [release checklist](../Documentation/RELEASE-CHECKLIST.md).
