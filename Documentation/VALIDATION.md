# Validation record — October 5, 2026

The portable development workflow works in the current Linux cloud instance.
The universal iPhone/iPad source and Apple release scripts are prepared. No
Apple-platform build, signed archive, upload, approval, or release has been
completed in this instance.

| Check | Observed result |
| --- | --- |
| `bash scripts/check-portable.sh` | Passed. Swift 6.2.3 build; 34 XCTest cases executed, 0 failures; structural project audit and privacy scan passed. |
| Core hostile-input coverage | UTF-8, duplicate keys, structural/size limits, integer precision/overflow, malformed timestamps, unsupported schemas, conflicting identities, and evidence linkage exercised. |
| Project, scheme, manifests, icons | Portable structural audit passed; OpenStep graph, universal families, app/test targets, local package, document handling, and opaque PNG dimensions checked. `plutil -lint` passed. |
| App and Apple-test Swift syntax | `swiftc -frontend -parse` passed. Syntax parsing does not typecheck Apple SDK APIs. |
| Shell helpers | `bash -n` passed for `.sh` and `.command` files. The Linux Swift install helper ran successfully and repeated without reinstalling. |
| Privacy source guard | Passed for 12 production Swift source files. No networking, advertising/tracking, or web-view APIs found. This is a structural guard, not a runtime network trace. |
| Apple submission sources | 19 official source pages retrieved with normal TLS. Requirements and retrieval evidence are in `APPLE-REQUIREMENTS.md` and `APPLE-SOURCE-VERIFICATION.md`. |
| Public policy and support | Unauthenticated HTTPS GET returned 200 for the GitHub-rendered policy and public issue tracker; readable policy contents confirmed. |
| Standalone privacy/support site | Source published on `gh-pages`. GitHub Pages enabling is denied to this scoped integration; the standalone site is not active. The readable GitHub policy/support URLs are active. |
| Native iPhone/iPad build and tests | Not run. Linux has no Xcode or Apple SDK. Mac CI is configured, but existing GitHub runs were prevented from starting by an account billing lock. |
| Real Apple report compatibility | Not run on current physical iPhone/iPad exports. Supported shapes are corroborated by published third-party examples; synthetic fixtures pass. |
| Keychain, encrypted persistence, export/delete UI | Apple-platform XCTest cases and native UI smoke tests are implemented but unrun here. Physical-device lock/backup/accessibility checks remain pending. |
| Signed archive and App Store Connect upload | Not run. Team `LYDVWU62G4` is configured; the Mac must authenticate, use the registered bundle ID, and run the checked release path. |
| Fire-inspired visual direction | Generated concept saved in `Design/`, awaiting user review. It is not a native screenshot or a submitted screenshot. |

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

On the authenticated Mac, after registering the app bundle ID and creating the
matching App Store Connect app record:

```sh
BUNDLE_ID=YOUR_REGISTERED_BUNDLE_ID bash scripts/release-to-app-store.command
```

This runs the native checks, creates a signed archive, and opens Xcode Organizer
with the upload option. Add `--upload` to use the authenticated command-line
upload. Failures abort the script; upload does not imply review submission or
public release. Complete `RELEASE-CHECKLIST.md` using the actual Apple results.
