# Window layers in a Canvas

Research for [#93](https://github.com/mia-cx/wadjet/issues/93): can a Canvas keep every window as its own layer, like Acorn's "Create layers for windows when taking screenshots" ([Acorn docs](https://flyingmeat.com/acorn/docs/screen_shots.html))?

## Short answer

**Yes, mostly — with caveats that need one hands-on test.** ScreenCaptureKit's `SCContentFilter(desktopIndependentWindow:)` captures a single window's full contents *even while occluded*, and `SCScreenshotManager.captureScreenshot` gives a still per window; `CGWindowListCopyWindowInfo` (optionOnScreenOnly) supplies the front-to-back z-order and each window's layer number, which is how the menu bar, Dock, and desktop get filtered or kept. The gaps: per-window capture cost at dozens of windows is unmeasured (no public benchmarks), whether off-screen/clipped windows come back whole needs a test, and system chrome (menu bar, Dock, desktop wallpaper) arrives as pseudo-window layers that must be handled explicitly. Recommend: build the Canvas with a per-window layer array ordered by CGWindowList z-order, each layer storing its captured image, global frame, and an `isWindowLayer` flag so the Editor can hide/move/restack — and keep a flattened full-display image as the base layer, so anything window capture misses still renders.

## Capturing each window

- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` lists `SCWindow`s; each maps to a `CGWindowID`, frame, owning app. wadjet already enumerates this for the Freeze Frame (`apps/macos/Sources/Wadjet/main.swift:1415` and `1464+`). [SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)
- Per-window stills: `SCScreenshotManager.captureScreenshot(contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration:)` — the app already calls exactly this in `captureWindow(id:screen:)` (`main.swift:686-697`). [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager), [init(desktopIndependentWindow:)](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:))
- A `desktopIndependentWindow` capture returns the complete window contents regardless of occlusion — occluded regions are composited in by the system. [WWDC22 "Take ScreenCaptureKit to the next level"](https://developer.apple.com/videos/play/wwdc2022/10155/) (the `desktopIndependent` name says it: the capture is independent of what's in front).
- **Shadows:** `SCStreamConfiguration`/`SCScreenshotConfiguration` expose `ignoreShadowsSingleWindow` (macOS 14+) to omit the window's drop shadow, and `capturesShadowsOnly` (macOS 14+) to grab just the shadow — so we can store shadow as a separable concern (either bake it in or keep a shadowless layer + let the Editor render one). [ignoreShadowsSingleWindow](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/ignoreshadowssinglewindow), [capturesShadowsOnly](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesshadowsonly)
- **Z-order:** `SCShareableContent.windows` isn't guaranteed ordered (noted in `main.swift:1481`'s comment — the app already works around this). `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly)` returns windows in **front-to-back** order and includes `kCGWindowLayer`, `kCGWindowBounds`, `kCGWindowOwnerName`. Use it to sort the SCWindow set and to know stacking. [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)), [optionOnScreenOnly](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenonly), [front-to-back confirmation](https://developer.apple.com/forums/thread/129903)
- **Cost per window:** no published numbers. Each capture is a separate SCScreenshotManager round-trip; N windows = N captures. Practical approach: sequential or small-concurrency loop with a cap (e.g. skip windows beyond a count or below an area threshold) and measure on a real Mac. *Try: 30-window desktop, time per `captureScreenshot`, total Canvas build time.*
- HDR: per-window captures can request HDR via `SCScreenshotConfiguration`/`captureScreenshot` dynamic-range options — same path the Freeze Frame already uses for `hdrImage` (`main.swift:1519`). *Unverified per-window HDR output; test.*

## Menu bar, Dock, desktop, off-screen and multi-display windows

- The window list contains non-app chrome: the menu bar (SystemUIServer), the Dock, the desktop background etc. all appear as windows with nonzero `kCGWindowLayer`. Treat layer-0 on-screen windows as real window layers; fold everything else into the flattened base layer (which we keep anyway from the display capture). [kCGWindowLayer meaning, SO/Apple docs summary](https://stackoverflow.com/questions/5286274/front-most-window-using-cgwindowlistcopywindowinfo)
- **Menu bar:** it's captured by the display-level screenshot as part of the base layer; the separate "menu bar window" can be skipped — the base already has it. The Canvas only needs per-window layers for layer-0 app windows.
- **Desktop/wallpaper:** same — base layer only.
- **Partly off-screen windows:** `onScreenWindowsOnly` still lists them; a `desktopIndependentWindow` capture should return the full window including the off-screen part — *unverified; test by sliding a window half off the display edge and capturing.* If the capture comes back clipped, store the clipped image plus the true frame and let the Editor show the visible portion.
- **Windows spanning displays:** the window's global frame crosses displays; a Canvas layer keyed to the window's screen-coordinate frame just works — the Canvas records global bounds, and each layer carries its own frame. *Verify capture returns the whole window, not just the portion on one display.*
- **Minimized/other-Space windows:** not in `onScreenWindowsOnly` — correctly absent from the Canvas.

## What the Editor can do with window layers

With each window a layer carrying (image, frame, owner, z-index):

- **Hide/reveal** — toggling a layer's visibility reveals the layers beneath (real content, not a hole) because occluded content was captured whole. This is the feature flat screenshots can't do.
- **Move** — drag a window layer; whatever it covered stays put as layers below.
- **Restack** — reordering changes z without re-capture; the whole point of keeping z-order.
- **Restyle/frame** — drop shadows (`capturesShadowsOnly`), corner rounding, or per-window crop in the Editor.

Each is just a layer model operation — the same editability story as Annotations. Cost: a 20-window Canvas stores 20 PNGs/HEICs; at typical sizes that's tens of MB. Mitigation: store windows as the same HEIC format as displays, and let the Editor flatten on export.

## What to try on a real Mac

1. Half-off-screen window → does `desktopIndependentWindow` capture return the full window?
2. A window straddling two displays → full capture or clipped?
3. Time `SCScreenshotManager.captureScreenshot` per window across a busy desktop (20–30 windows) — is the whole layer build under ~1 s?
4. HDR display → does a per-window capture carry HDR, and does `sdrImage`/`hdrImage` behave per window as it does per display?
