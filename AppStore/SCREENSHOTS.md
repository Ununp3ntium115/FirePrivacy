# Screenshot capture plan

This is a plan, not a screenshot set. Capture the signed/Release-equivalent app
after Apple-platform validation. Store deliverables outside source assets or in
`AppStore/Screenshots/`; use synthetic data exclusively.

| Image | Screen | Copy, if a caption is added outside the device image |
| --- | --- | --- |
| 1 | Overview with the demo loaded | Your report, easier to understand |
| 2 | App detail showing recorded domains/sensors | Explore recorded app activity |
| 3 | Domain detail/evidence view | See the evidence behind each contact |
| 4 | Privacy/local-storage explanation | A private workspace on your device |
| 5 | iPad overview/detail layout | Room to explore on iPad |

Only use screens that exist in the final app. Do not add a “protection active,”
tracker-blocking, AI, or score claim. If a planned view changes, change this plan
and the captions to match it.

The official [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
were retrieved October 5, 2026 with HTTPS certificate verification enabled.
Apple accepts 1–10 screenshots per set as JPEG/JPG/PNG without alpha or
transparency. The relevant accepted portrait sizes are:

| Display class | Accepted portrait pixel dimensions | Requirement |
| --- | --- | --- |
| iPhone 6.9-inch | 1260 × 2736, 1290 × 2796, 1320 × 2868 | Use this class for the iPhone set. |
| iPhone 6.5-inch | 1284 × 2778, 1242 × 2688 | Required for iPhone if 6.9-inch screenshots are not provided. |
| iPad 13-inch | 2064 × 2752, 2048 × 2732 | Required if the app runs on iPad. |

The corresponding landscape dimensions are the same pair reversed. Confirm the
upload slots shown for the app on submission day. Capture at an accepted native
resolution; do not resize an iPhone capture into an iPad screenshot.

Check light/dark appearance, Dynamic Type defaults, readable text, meaningful
empty states, and orientation. Use one consistent locale and synthetic dataset.
Screenshots must describe what the uploaded binary does and must not expose
personal report contents, device details, account identifiers, or contact data.
