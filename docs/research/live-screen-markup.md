# Drawing Annotations over the live screen

Research for [#90](https://github.com/mia-cx/wadjet/issues/90). Target: macOS 26+, sandboxed SwiftUI app. wadjet's existing Freeze Frame panels already solve most of the window-layer problem — see `apps/macos/Sources/Wadjet/main.swift`.

## Short answer

- **Overlay above everything:** a borderless `NSPanel` per display at `.screenSaver` level with `.canJoinAllSpaces` + `.fullScreenAuxiliary` — the exact pattern the Freeze Frame panels already use (`main.swift:1587-1589`, `1378-1381`). That covers full-screen Spaces and sits above the menu bar. Non-issue.
- **Click-through:** this is the hard part, not the windowing. `ignoresMouseEvents` is whole-window only; per-pixel click-through on transparent areas works for *non-layer-backed* borderless windows whose `hitTest` returns nil — and wadjet's SwiftUI-hosted panels are layer-backed, so it won't apply there. Recommended: keep the Markup panel `ignoresMouseEvents = true` whenever no tool is armed and no Annotation is being hovered, and flip it to `false` while a Markup Tool is armed — i.e. accept that an armed tool owns the clicks. True pass-through-while-armed needs a `CGEventTap`, which requires Input Monitoring (listen-only) or the post-event privilege (filtering) — both available to sandboxed apps via `CGRequestListenEventAccess` / `CGRequestPostEventAccess`, but a new permission prompt. Prototype before committing.
- **Recordings:** the Record display filter already excludes wadjet's own app (`excludingApplications: own`, `main.swift:889`). To record Annotations, include wadjet in the filter and exclude the non-annotation windows with `exceptingWindows`, or composite Annotations into frames at the `SCStream` output before `AVAssetWriter`. The latter is more code but keeps every other wadjet window excluded.
- **Live sampling under an Annotation (Censor, Magnify, peer-through):** the only supported way to get live pixels of other apps is ScreenCaptureKit — a dedicated `SCStream` scoped with `sourceRect` to the sampled region, or `SCScreenshotManager` stills for static moments. Censor stays secure under changing content only if the sample refreshes; recommend one low-fps `SCStream` per display while any live-sampling Annotation exists on it. Cost must be measured on a real Mac; no published numbers.

## Overlay windowing

One panel per display, same shape as the Freeze Frame panels:

```swift
let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], ...)
p.level = .screenSaver
p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

wadjet already does this at `.screenSaver` / `.screenSaver + n` in several places (`main.swift:951-954` recording HUD, `1378-1381`, `1587-1589`, `1645-1648`, `3243-3246`). `.screenSaver` is the highest level needed to cover the menu bar; go *above* it only for the Markup layer so Capture dialogs can't occlude annotations — the Freeze Frame panels already stack this way (`screenSaver + 1`, `+ 2`, `+ 3`). [NSWindow.Level](https://developer.apple.com/documentation/appkit/nswindow/level), [collectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.property)

Annotations persist while Space changes happen around them: `.canJoinAllSpaces` + `.fullScreenAuxiliary` makes the panel visible on every Space including full-screen apps — verified in the running app's Freeze Frame panels. [NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior)

## Click-through vs catching clicks

`NSWindow.ignoresMouseEvents` is a whole-window switch — a transparent full-screen panel either swallows every click on the display or none of them. [ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoremouseevents)

Two ways to get finer grain:

1. **Native per-pixel click-through.** For a borderless, non-layer-backed window, clicks on fully transparent pixels fall through to the windows below when `hitTest` returns nil for the point — long-standing AppKit behavior, demoed by this public test project: [MaskedView hitTest returning nil](https://github.com/aphofstede/TransparentWindowClickthroughTest/blob/master/TransparentWindowClickthroughTest/MaskedView.swift), [SO discussion](https://stackoverflow.com/questions/29441015/click-through-custom-nswindow). Two caveats from the same sources: `ignoresMouseEvents` must never have been toggled (an Apple-side quirk), and setting `wantsLayer` on the contentView disables the fall-through. Since wadjet hosts everything in `NSHostingController`/SwiftUI (layer-backed), this path needs either a plain `NSView` Markup panel (loses SwiftUI/glass) or — better — a **second, non-layer-backed AppKit panel** used only for hit-catching, paired with the layer-backed drawing surface. *Verify on a real Mac: draw with a SwiftUI view vs a plain `NSView` in an identical panel and click a transparent region.*

2. **Event tap.** A `CGEventTap` at the session tap point observes every mouse event while the panel itself stays `ignoresMouseEvents = true`. Listen-only taps need the **Input Monitoring** privilege — available to sandboxed and App Store apps via `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`; a tap that *consumes* or re-injects events needs the separate post-event privilege (`CGRequestPostEventAccess`), also sandbox-compatible per Apple DTS. [DTS on Input Monitoring in the sandbox](https://developer.apple.com/forums/thread/707680), [CGRequestListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()), [CGRequestPostEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()). Swallowing a click destined for the app beneath and reposting it (or not) is fragile — modifier state, double-click timing. Recommended only if option 1 fails; it adds a second permission prompt on top of Screen Recording.

Pragmatic middle ground worth stating plainly: **while a Markup Tool is armed, the overlay may simply eat clicks** (armed = drawing, pointer is the tool cursor anyway). Settled map (#89) already gives the pointer to the armed tool and Esc as the disarm, so click-through only matters when no tool is armed — where hover-hit-testing an Annotation still needs the panel to see moves. `NSTrackingArea` on the armed panel or global `mouseMoved` monitoring covers hover detection; clicking an existing Annotation with no tool armed is the one case that needs option 1 or 2.

## Capturing the overlay in Recordings

The Record path builds `SCContentFilter(display:excludingApplications:exceptingWindows:)` with wadjet itself excluded (`main.swift:889`), so nothing wadjet draws reaches the video today.

Options:

- **Include wadjet, except its other windows.** `SCContentFilter(display:includingApplications:exceptingWindows:)` includes a whole app's windows except a list — put every Freeze Frame/toast/pin window in `exceptingWindows` while Markup is active. [init(display:includingApplications:exceptingWindows:)](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:includingapplications:exceptingwindows:)), [WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/). Cheapest in code; downside is every wadjet window must be enumerated at recording start and the filter can't pick up windows created mid-recording (update with `updateContentFilter` — [SCStream.update](https://developer.apple.com/documentation/screencapturekit/scstream/updatecontentfilter(_:completionhandler:))).
- **Composite in the writer.** Keep wadjet excluded; draw the Annotation model onto each `CMSampleBuffer` (or `CVPixelBuffer`) in the existing `SCStreamOutput` → `AVAssetWriter` path (`main.swift:845-860`). More CPU per frame but wadjet controls compositing — also the only way to render Annotations *differently* in the recording (e.g. hide selection handles).
- **Screenshots and Freeze Frame** already have the pixel data locally (`Freeze.crop`, `main.swift:169`) — Annotations flatten on top in-app, and also live on as Canvas layers (#89). No screen-capture involvement needed.

## Sampling live content beneath an Annotation

Censor (blur/pixelate), Magnify, and the feathered peer-through circle need the pixels *under* the annotation while the live screen changes. Options, in order of preference:

- **`SCStream` with `sourceRect`** — a stream per display whose `sourceRect` is the union of live-sampling annotation bounds; update the rect as annotations move (`updateConfiguration`). Gives real-time frames at a chosen `minimumFrameInterval`; this is the same API the recorder uses. [sourceRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect), [SCStream](https://developer.apple.com/documentation/screencapturekit/scstream)
- **`SCScreenshotManager.captureScreenshot`** — already used for Freeze Frames (`main.swift:1519`); fine for a *static* censor at draw time, wrong for live. Repeated calls are heavyweight compared to a stream. [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- `CGWindowListCreateImage` is deprecated since macOS 14.0 — don't use it. [docs](https://developer.apple.com/documentation/coregraphics/1455737-cgwindowlistcreateimage)

**Censor security under changing content:** a blur/pixelate region must re-render from fresh samples — a stale sample can *reveal* content that has scrolled beneath it. With a per-display `SCStream`, security holds automatically because the censor output is always derived from the latest frame. A solid-black redact needs no sampling at all — prefer it (like the rest of the industry) when secrecy matters.

**Cost:** a 5 K 60 fps display stream is not free (each frame is a full pixel buffer through `SCStreamOutput`), but a region-scoped stream at 15–30 fps is small. ScreenCaptureKit grants require Screen Recording permission, which wadjet already needs. *Measure on a real Mac: one `SCStream` per display at `minimumFrameInterval` = 1/15 with a ~600×400 `sourceRect`, watching CPU in Activity Monitor while scrolling beneath a Censor.* No published benchmarks — unverified.

## What to try on a real Mac

1. Borderless panel + plain `NSView` (no `wantsLayer`): does `hitTest` → nil give true per-pixel click-through on macOS 26, including over full-screen Spaces?
2. Same panel hosting SwiftUI via `NSHostingController` — expected to fail per the layer rule; confirm.
3. `CGEventTap` listen-only vs default (filter) tap under the sandbox: which privilege prompt appears, and can a filtered click be re-posted without visible artifacts?
4. `SCStream` with `sourceRect` tracking a dragged Censor region: latency between the screen changing and the censored overlay updating; CPU cost.
