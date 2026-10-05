# Validation record — October 5, 2026

The portable development workflow works in the current Linux cloud instance.
The universal iPhone/iPad app compiled on hosted Mac CI. The owner approved
the fire-inspired concept, and that styling is now implemented in SwiftUI.
The approved-design native suites passed after diagnosed simulator/UI fixes.
Small final lifecycle/accessibility and release-helper changes are local and
await a further native run. GitHub authentication has been restored. No
signed distribution archive, App Store Connect upload, approval, or public
release has been completed.

| Check | Observed result |
| --- | --- |
| `bash scripts/check-portable.sh` | Passed. Swift 6.2.3 build; 34 XCTest cases executed, 0 failures; structural project audit and privacy scan passed. |
| Core hostile-input coverage | UTF-8, duplicate keys, structural/size limits, integer precision/overflow, malformed timestamps, unsupported schemas, conflicting identities, and evidence linkage exercised. |
| Project, scheme, manifests, icons | Portable structural audit passed; OpenStep graph, universal families, app/test targets, local package, document handling, and opaque PNG dimensions checked. `plutil -lint` passed. |
| App and Apple-test Swift syntax | `swiftc -frontend -parse` passed. Syntax parsing does not typecheck Apple SDK APIs. |
| Shell helpers | `bash -n` passed for `.sh` and `.command` files. The Linux Swift install helper ran successfully and repeated without reinstalling. |
| Cloud signing/cleanup tests | 19 Python unittest cases passed, 0 skipped. They exercise archive/upload preparation, partial credentials, Apple policy selection/error handling, profile/identity matching, owned-file cleanup, preservation of existing profiles, keychain restoration failure, and sanitized errors using dummy data and mocked Apple tools/frameworks. Actual macOS certificate trust, signing, export, and upload remain unrun. |
| Privacy source guard | Passed for 12 production Swift source files. No networking, advertising/tracking, or web-view APIs found. This is a structural guard, not a runtime network trace. |
| Apple submission sources | 19 official source pages retrieved with normal TLS. Requirements and retrieval evidence are in `APPLE-REQUIREMENTS.md` and `APPLE-SOURCE-VERIFICATION.json`. |
| Public policy and support | Unauthenticated HTTPS GET returned 200 for the GitHub-rendered policy and public issue tracker; readable policy contents confirmed. |
| Standalone privacy/support site | Source published on `gh-pages`. GitHub Pages enabling is denied to this scoped integration; the standalone site is not active. The readable GitHub policy/support URLs are active. |
| Native iPhone/iPad build and tests | [Run 37378242655](https://github.com/Ununp3ntium115/FirePrivacy/actions/runs/37378242655), commit `d44a996`, compiled the approved-design app and passed the storage/UI test steps for both families. Retrieved logs confirm, on each family, 34 core XCTest cases passed and 12 native cases executed: 11 passed, 1 hardware-only file-protection case skipped, 0 failed. Final lifecycle/accessibility/evidence-display/helper changes await another native run. |
| Real Apple report compatibility | Not run on current physical iPhone/iPad exports. Supported shapes are corroborated by published third-party examples; synthetic fixtures pass. |
| Keychain, encrypted persistence, export/delete UI | Ad-hoc simulator signing fixed the tested Keychain deletion failure. Both native test steps passed, including AES-GCM round trip, tamper rejection, backup exclusion, explicit export/deletion paths, and demo navigation/deletion. Hardware-only protection is a separately skipped simulator test. An additional real-store/model partial-deletion regression has been added locally and awaits native execution. Physical-device lock/backup/accessibility checks remain pending. |
| Signed archive and App Store Connect upload | Not run. Team `LYDVWU62G4` is configured. The cloud release workflow needs valid signing material, a registered bundle ID, and a matching App Store Connect app record. See `CLOUD-RELEASE.md`. |
| Fire-inspired visual direction | Owner approved the generated concept on October 5, 2026. The charcoal/ember design and original flame icon are implemented. The concept remains an illustration, not a native or submitted screenshot. |
| Actual native screenshots | Run 37378242655 completed successfully, including its screenshot-capture and artifact-retention steps. The `native-iphone` artifact contains actual iPhone/iPad demo overview captures; native UI result bundles contain additional navigation attachments. Image contents, dimensions, and alpha have not yet been inspected here; the current artifact host still returned403 after its network-rule addition. The final helper adds alpha-free technical export and still awaits Mac execution. |
| GitHub access and cloud handoff | Git/API access worked for PR #2 and the approved-design push. At 21:56 UTC both native Git and API access began failing; the API reports HTTP 401 `Bad credentials`. Git/API access is now restored. The next source push/native run and workflow registration can proceed. Secret/variable metadata still returns403, so existing signing bindings remain unknown. |

The last portable run on the candidate source returned exit 0. The additional
Swift Testing runner printed zero Swift Testing cases; the separate XCTest
suite explicitly executed and passed 34 cases, so validation is not based on
a zero-test run.

The official Swift 6.2.3 archive was SHA-256 pinned and its historical release
signature verified against the official Swift key set and signer fingerprint.
GPG notes that the release-signing key is now expired; the artifact's signature
was made while the key was valid. Verification was not disabled.

## Reproduce and continue

```sh
bash scripts/install-swift-linux.sh
bash scripts/check-portable.sh
```

For a cloud-based release, use [CLOUD-RELEASE.md](CLOUD-RELEASE.md). GitHub's
hosted Mac runner supplies Xcode; the Linux session continues independently.

Alternatively, on an authenticated Mac, after registering the app bundle ID
and creating the matching App Store Connect app record:

```sh
BUNDLE_ID=YOUR_REGISTERED_BUNDLE_ID bash scripts/release-to-app-store.command
```

This runs the native checks, creates a signed archive, and opens Xcode Organizer
with the upload option. Add `--upload` to use the authenticated command-line
upload. Failures abort the script; upload does not imply review submission or
public release. Complete `RELEASE-CHECKLIST.md` using the actual Apple results.
