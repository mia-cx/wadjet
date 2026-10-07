# Freeze Frame capture and overlay

Research for [#2](https://github.com/mia-cx/wadjet/issues/2), 2026-10-07. Target macOS 26+, checked against Xcode 27 beta (27A5228h).

## Short answer and recommendation

Use `SCScreenshotManager.captureScreenshot(rect:configuration:)` with `SCScreenshotConfiguration` on macOS 26. It captures display-space rectangles across displays, supports cursor inclusion, and returns SDR, HDR, or both. Capture each display before presenting the selection overlay. Keep each display's image, geometry, and scale together. Show one borderless, nonactivating AppKit panel per display. This avoids `SCShareableContent` enumeration in the image capture path and gives explicit output sizing for mixed Retina displays. [1][2][3][4]

Start #12 with per-display SDR images, `showsCursor = true`, `ignoreShadows = false`, and `.local` display intent. Crop these images when selection completes. Do not take a second live screenshot. Prototype `.screenSaver` panels with `.canJoinAllSpaces`, `.canJoinAllApplications`, and `.fullScreenAuxiliary`. These are documented building blocks, not a promise to cover every system UI. Full-screen Spaces, Stage Manager, menu bar, Dock, and focus behavior remain acceptance tests. [2][4][5][6][7][8]

**The unresolved requirement is “instant at hotkey time.”** Apple provides asynchronous screenshots, with no documented deadline or multi-display atomic capture contract in these APIs. macshot's source reports substantial latency and slower concurrent requests on macOS 26. Treat those numbers as that project's observations, not measurements of Mia's Mac. Benchmark before accepting the Freeze Frame timing requirement. [1][9][10]

## Capture API

macOS 26 adds screenshot-specific configuration and output types. The older `captureImage(contentFilter:configuration:)` accepts `SCStreamConfiguration` and exists from macOS 14. WWDC23 introduces that asynchronous API; WWDC24 demonstrates HDR screenshot presets for the older configuration. Prefer the macOS 26 API for this deployment target. [1][2][9][11]

The rectangle API takes points in screen/display space and supports multiple displays. `sourceRect`, when used, is points in a display's logical coordinate system. Output `width` and `height` are pixels. Set dimensions explicitly; the zero values observed on a new configuration mean default sizing, not a zero-size requested capture. [1][2][3][12]

Use the content-filter variant when excluding wadjet windows is necessary. Apple sample code shows display filters excluding applications and `desktopIndependentWindow` filters capturing one window. The system content picker also supplies filters, but its live selection UI does not implement selection on wadjet's Freeze Frame. [9][13]

Minimal image capture, with signatures typechecked against the installed SDK:

```swift
import AppKit
import ScreenCaptureKit

@available(macOS 26.0, *)
func captureDisplay(rect: CGRect, pixelSize: CGSize) async throws -> CGImage? {
    let config = SCScreenshotConfiguration()
    config.width = Int(pixelSize.width.rounded())
    config.height = Int(pixelSize.height.rounded())
    config.showsCursor = true
    config.ignoreShadows = false
    config.displayIntent = .local
    config.dynamicRange = .sdr
    let output = try await SCScreenshotManager.captureScreenshot(
        rect: rect, configuration: config
    )
    return output.sdrImage
}
```

This helper receives already-derived display coordinates and pixel dimensions. In implementation, an absent requested image must fail the capture rather than present an empty overlay. The output image properties are optional. [4]

### Cursor and shadows

Set `showsCursor` explicitly. Its documented default is true. The local probe also returned true. `ignoreShadows` returned true, so set false to preserve the visible desktop composition. The default display intent returned canonical, so set local explicitly for a same-display preview. These runtime observations are from macOS 27 beta and need confirmation on macOS 26. [2][4][14]

The cursor baked into the image is distinct from the live selection crosshair. Capture first, then change the live cursor. Keep the baked cursor in the Freeze Frame for magnification, OCR, and final cropping. Separate display requests can observe different cursor positions if it moves between requests. That last point is an inference from asynchronous requests without a synchronization parameter. [1][14]

iShare's current source defaults to `/usr/sbin/screencapture` and constructs interactive capture arguments. Apple's installed tool help says `-C` captures the cursor only in non-interactive modes. The limitation is interactive `-i` plus cursor capture, not the executable's ability to capture a cursor at all. [15]

## Timing and the “moment capture starts” contract

The rect API avoids waiting for a shareable-content list before requesting pixels. macshot implements that approach and retains the content-filter path as a fallback. Its source reports roughly 380 ms per sequential request, versus roughly 1.3 seconds per queued concurrent request on its macOS 26 setup. It reports 1.5 seconds sequential versus 3.9 seconds concurrent for four displays. No hardware description or reproducible benchmark accompanies that comment. Do not quote these as expected wadjet performance. [10]

Recommendation for the prototype:

1. Snapshot display geometry and window-picking metadata before ordering panels front. Record a monotonic hotkey timestamp.
2. Request per-display images with explicit scale and color settings. Compare sequential and concurrent requests on the actual machine.
3. Present panels only after all required images arrive. Record each completion and the first rendered overlay frame.
4. Measure cold and warm p50/p95 timings, plus cross-display skew. Include open menus, animated content, one display, and mixed-scale displays.
5. If this misses the agreed latency budget, evaluate a resident `SCStream` frame cache separately. Record frame age at the hotkey; a cached frame is earlier than the trigger.

These are proposed validation steps, not established performance results. Apple sample code shows stream frame status, scale metadata, and sample-buffer delivery. WWDC23 documents active-stream integration with system sharing UI. A resident stream adds lifecycle and ongoing capture costs; it should be a measured alternative, not the default solution. [9][13]

There is no timestamp or “capture all displays atomically” parameter in the inspected screenshot signatures. One rectangle spanning all displays is worth benchmarking, since Apple documents multi-display support. It does not establish atomicity or a native-resolution policy for mixed-scale output. Keep per-display images as the initial design until those properties are measured. [1][3]

Do not show a cursor-display overlay early while other rectangle screenshots remain pending. Without filtering, the later screenshots can include wadjet's overlay. Progressive presentation also weakens the single Freeze Frame timing model. macshot uses progressive presentation for responsiveness; wadjet must choose that tradeoff explicitly. [10][13]

## Displays, coordinates, and Retina

`NSScreen.frame` covers the entire display, including menu bar and Dock space. Use it instead of `visibleFrame`. `NSScreen.screens.first` describes the primary screen; `NSScreen.main` can describe the screen containing the active window. Apple says not to cache the screen array across display changes. [6][16]

AppKit screen coordinates and screenshot rectangle coordinates need conversion. macshot fixes a documented-in-source secondary-display black-stripe bug with:

```swift
let primaryTop = NSScreen.screens[0].frame.maxY
let captureRect = CGRect(
    x: screen.frame.minX,
    y: primaryTop - screen.frame.maxY,
    width: screen.frame.width,
    height: screen.frame.height
)
```

Use the primary screen, not the active screen, as the conversion anchor. Preserve negative origins. Test displays above, below, and left of primary, plus rotation. The conversion is supported by real implementation evidence; the tests remain necessary on macOS 26 and 27. [10][16]

Apple defines `backingScaleFactor` as backing pixels per screen-space unit. Set each requested image size from its own logical size and scale. Store actual returned pixel dimensions too. Derive crop scale from `image.width / logicalWidth` and `image.height / logicalHeight`, so downstream selection matches the image that arrived. Apple recommends backing conversion methods where practical. [3][17]

Keep selection geometry in global logical points. Intersect with each display, then map each intersection into that image's pixel coordinates. Round crop edges outward and clamp to image bounds. These are proposed geometry rules. A selection crossing 1x and 2x displays needs an explicit final raster policy. Recommend restricting v1 selection to one display until #12 decides whether cross-display Capture is required. Otherwise pick a common export scale and resample the fragments; there is no single native pixel scale for that selection. [3][17]

## Overlay above desktop and full-screen apps

Use one `NSPanel` per screen. Give it `.borderless` and `.nonactivatingPanel`, `hidesOnDeactivate = false`, no shadow, no appearance animation, and mouse input while selecting. Override `canBecomeKey` for keyboard selection and Escape. Install an image that fully covers the panel before ordering it front. macshot uses this pattern and a backing image layer; snap uses one borderless overlay window with `.screenSaver`. [7][18][19]

Start with `level = .screenSaver`; avoid macshot's unexplained raw level 257. Window level controls stacking, while collection behavior controls Space eligibility. Set `.canJoinAllSpaces` and `.fullScreenAuxiliary`. Add `.canJoinAllApplications`, which Apple specifically documents for floating windows and overlays joining other apps' full-screen Spaces and Stage Manager sets. Do not combine it with `.primary` or `.auxiliary`, which Apple marks mutually exclusive with it. Also avoid `.fullScreenPrimary` and `toggleFullScreen`, since selection should not create a new Space. [5][7][8][18]

Keep idle prebuilt panels ordered out and noninteractive. Restore input and cursor state on confirm, Escape, failure, sleep, or display reconfiguration. This is a proposed lifecycle rule; macshot's source documents stranded warm panels swallowing clicks as a real failure mode. [18]

“Above everything” cannot be accepted from API declarations alone. These docs describe eligible Spaces and window levels, not universal priority over system dialogs or protected UI. Test menu bar, Dock, full-screen apps, Stage Manager, separate Spaces per display, and keyboard routing in #12. Do not attempt private WindowServer APIs. [5][7][8]

## Window picking on the Freeze Frame

`SCShareableContent` gives displays, applications, and windows. `SCWindow` includes frame, ID, layer, owner, title, and on-screen state. Use it when constructing capture filters. Apple does not document a front-to-back order for its window array in the inspected declarations. [13][20]

For selection hit-testing, take `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` before showing overlays. Apple explicitly documents front-to-back ordering for `.optionOnScreenOnly`. The dictionaries provide window IDs and bounds. Hit-test eligible windows in that order; do not pick the smallest rectangle across unrelated applications. Exclude wadjet's own panels and record stable metadata for the selection session. Apple calls window dictionary generation relatively expensive, so avoid doing it on every mouse move. [21][22]

Window rectangles are an approximation to visible shape. Transparent corners, shadows, sheets, Quick Look, menus, and occlusion need prototype decisions. macshot contains a Finder/Quick Look-specific heuristic; that is evidence of edge cases, not a rule to copy wholesale. [23]

**Window selection must distinguish two results.** Cropping the Freeze Frame returns visible pixels, including any occluding windows. Capturing `SCContentFilter(desktopIndependentWindow:)` after the click returns a new image of that window. It can reveal covered content and reflects a later time. Recommend Freeze Frame cropping for v1, and an explicit later decision if isolated window content, transparent corners, or shadows are required. [13][23]

## HDR and color

The macOS 26 API supports `.sdr`, `.hdr`, and `.bothSDRAndHDR`. `.local` optimizes for the capture display; `.canonical` optimizes for HDR display presentation elsewhere. SDR output uses the capture display's color space. HDR output uses extended sRGB. Preserve the returned color space when previewing and exporting; do not relabel everything as sRGB. [4][24][25]

Use SDR first for #12 and ordinary PNG/clipboard Workflows. This deliberately does not preserve HDR luminance in the Freeze Frame. If fidelity to HDR desktop content is a v1 requirement, make that a separate implementation gate. Request both outputs and evaluate a real EDR-capable preview plus HDR export. Merely putting an HDR `CGImage` in a generic preview is not a validated HDR rendering path. WWDC24 covers HDR capture configuration; it does not certify wadjet's AppKit preview or crop/export pipeline. [4][11][24][25]

Retina output and HDR are separate choices. Mixed displays need per-display color management as well as per-display geometry. Holding both HDR and SDR images increases storage compared with holding only one image. Avoid retaining extra copies during selection unless the Workflow needs them. This is a design inference from the distinct output images, not a measured memory budget. [4]

## Validation performed and open risks

Ran a tiny Swift program outside the repo with `xcrun swiftc -target arm64-apple-macos26.0`. It typechecked both async `captureScreenshot` overloads and the proposed panel flags. Executed only configuration construction and `CGPreflightScreenCaptureAccess`. The capture and panel functions were never called. No screen image, overlay, stream, permission request, or latency benchmark ran.

Observed defaults on the host: `showsCursor=true`, `width=0`, `height=0`, SDR dynamic range, canonical intent, `ignoreShadows=true`. Preflight returned true for this process. This does not establish permission for wadjet's signed application identity. `sw_vers` reported macOS 27.2 (26B5101f); macOS 26 runtime behavior remains untested. [26]

Open implementation gates:

- Actual hotkey-to-pixels and hotkey-to-interactive latency, cursor timing, cross-display skew, sequential versus concurrent performance. Window metadata and captured pixels are separate reads, so moving windows can disagree.
- Space eligibility, focus, menu bar/Dock coverage, display rearrangement, sleep/wake, and notch behavior on real hardware.
- One-display versus cross-display selection, plus visible-pixels versus isolated-window semantics.
- HDR fidelity requirements and a validated preview/crop/export color path.
- Permission denial/revocation, capture errors, and partial display results. Fail the session cleanly; do not present a partial Freeze Frame as complete.

Do not rely on `NSWindow.sharingType = .none` to omit overlays. Apple's current documentation calls it a legacy constant and explicitly says not to use it to hide content from capture. Capture before presentation, or use an explicit content filter for later streams. [27][13]

## Effects on other tickets

These are recommendations for the orchestrator, not edits to those tickets.

- **#12:** implement per-display image-backed panels and frozen window metadata. Include the timing and real Spaces tests above. Resolve cross-display and window Capture semantics.
- **#3 and #10:** reuse logical-to-display geometry, but remove selection panels before live Recording. Any retained HUD needs explicit filtering. Evaluate a resident stream only if measured screenshot latency demands it.
- **#5:** signed wadjet needs its own permission validation. The terminal preflight result is insufficient. Custom all-display Freeze Frame selection differs from using Apple's built-in content picker. [13][26]
- **#7, #8, #11:** agree whether Steps, OCR, Color Picker, Pin, and history receive SDR only or preserve an HDR representation. Magnification and Color Picker should read the retained Freeze Frame, not later desktop pixels.
- **#13:** panel lifecycle must allow the post-capture toast after dismissing selection. For #4, #6, and #9, this research changes no uploader protocol; chosen image format/color policy affects the resulting file.

Suggested new ticket if #12 remains only an interaction prototype: **Measure Freeze Frame latency and display fidelity on macOS 26/27.** Deliver p50/p95 timings and display skew, with a decision on screenshot APIs versus a resident stream. Add an HDR fidelity ticket only if v1 requires HDR-preserving output.

## Sources

Apple API references were read through their official DocC JSON endpoints where the HTML required JavaScript. Source links below point to the corresponding public reference pages. Open-source links pin the commits inspected.

1. [SCScreenshotManager and screenshot overloads](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager). Also inspected `SCScreenshotManager.h` in the installed Xcode 27 beta macOS SDK for macOS 26 availability and exact signatures.
2. [SCScreenshotConfiguration](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration).
3. [width](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/width) and [sourceRect](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/sourcerect).
4. [SCScreenshotOutput](https://developer.apple.com/documentation/screencapturekit/scscreenshotoutput), [sdrImage](https://developer.apple.com/documentation/screencapturekit/scscreenshotoutput/sdrimage), [hdrImage](https://developer.apple.com/documentation/screencapturekit/scscreenshotoutput/hdrimage).
5. [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications). Also inspected installed `NSWindow.h` mutual-exclusion comments.
6. [NSScreen.frame](https://developer.apple.com/documentation/appkit/nsscreen/frame).
7. [screenSaver window level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/screensaver).
8. [canJoinAllSpaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces) and [fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary).
9. [WWDC23: What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/), screenshot discussion at 10:10 onward and stream integration earlier in the session.
10. [macshot ScreenCaptureManager.swift](https://github.com/sw33tLie/macshot/blob/39bcead38445577ad8a077e2757e26d10603cc9d/macshot/Capture/ScreenCaptureManager.swift#L120-L314), rect capture, coordinate correction, and latency comments.
11. [WWDC24: Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/), HDR screenshots around 6:16.
12. Installed Apple SDK `SCScreenshotManager.h` configuration comments, cross-checked with sources 1 and 3.
13. [Apple sample: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), inspected its code listings for filters, sizing, stream configuration, and frame metadata.
14. [showsCursor](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/showscursor) and [ignoreShadows](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/ignoreshadows).
15. [iShare ImageCapture.swift](https://github.com/itoolio/ishare/blob/deb7abcdfdef251647c532924bad38426a18b1b2/ishare/Capture/ImageCapture.swift) and [Constants.swift](https://github.com/itoolio/ishare/blob/deb7abcdfdef251647c532924bad38426a18b1b2/ishare/Util/Constants.swift#L54). `castdrian/ishare` resolves to `itoolio/ishare`. Also inspected Apple's installed `/usr/sbin/screencapture -h`, without running a capture.
16. [NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens).
17. [NSScreen.backingScaleFactor](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor).
18. [macshot OverlayWindowController.swift](https://github.com/sw33tLie/macshot/blob/39bcead38445577ad8a077e2757e26d10603cc9d/macshot/UI/Overlay/OverlayWindowController.swift#L165-L219).
19. [snap OverlayWindow.swift](https://github.com/J-1000/snap/blob/89994390eb9327e811917877b9c9a81cd46b69a7/Snap/Capture/OverlayWindow.swift) and [nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel).
20. [SCWindow](https://developer.apple.com/documentation/screencapturekit/scwindow). Also inspected installed `SCShareableContent.h` for fields.
21. [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)).
22. [optionOnScreenOnly](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenonly).
23. [macshot OverlayView+WindowSnapping.swift](https://github.com/sw33tLie/macshot/blob/39bcead38445577ad8a077e2757e26d10603cc9d/macshot/UI/Overlay/OverlayView%2BWindowSnapping.swift#L90-L165).
24. [DynamicRange](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/dynamicrange-swift.enum).
25. [DisplayIntent](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/displayintent-swift.enum).
26. [CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()). Local validation script, command, and observations are described above; no capture call ran.
27. [NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).
