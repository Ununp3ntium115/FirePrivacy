# Privacy and support site

`index.html`, `privacy.html`, `support.html`, and `styles.css` are a standalone
static site. No JavaScript, remote font, analytics service, build dependency,
cookie, or fabricated domain/contact is required. Links within the site are
relative so it can be deployed at either a domain root or a repository path.

Local preview from the repository:

```sh
python3 -m http.server 8080 --directory website
```

An earlier version of the site files has been pushed to the repository's
`gh-pages` branch. The revised expanded policy/support/home source in this
checkout is draft; publish it after the matching native functionality is verified. Enabling
GitHub Pages through this integration was rejected with HTTP 403, so no live
Pages website is claimed. The repository owner can enable Settings → Pages →
Deploy from a branch → `gh-pages` → root, or publish the files through another
HTTPS static host they control. Verify the resulting privacy and support URLs
from outside the cloud workspace before configuring them in the app.

The public [rendered policy](https://github.com/Ununp3ntium115/FirePrivacy/blob/gh-pages/privacy-policy.md)
and [issue tracker](https://github.com/Ununp3ntium115/FirePrivacy/issues) were
verified as publicly readable with HTTP 200 on October 5, 2026. Those URLs are
configured as the app and App Store metadata defaults. They work before the
standalone site is live; no active GitHub Pages domain is claimed. The live
policy still describes the earlier single-report MVP and must be republished
to match the expanded build before distribution.

The GitHub API verified on October 5, 2026 that this repository is
public and issues are enabled. Ensure the issue tracker is monitored and usable
by customers before submitting the app.

Set the verified URLs in the app's supported URL configuration and App Store
Connect metadata. Update the policy if final storage, sharing, support, or data
handling differs from what it describes. Its encryption, backup, Keychain, and
deletion claims require Apple-platform/device validation before release.

The repository's earlier company and security-contact claims do not establish a
verified seller identity or reachable private support address. This site uses
the product name and existing project route until real contact details are
confirmed. Do not substitute an invented email or domain.
