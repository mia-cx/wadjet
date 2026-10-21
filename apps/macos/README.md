# Wadjet

A ShareX-style screenshot and screen-recording utility for macOS 26+ — Capture,
Record, Pick Colour, Copy Text and Measure on a Freeze Frame, Markup on the live
screen or the Freeze Frame, a Canvas Editor, a Dynamic Island-style toolbar and
post-capture toasts.

## Run

    ./run.sh

Builds the `Wadjet` Xcode scheme with xcodebuild into `build/Wadjet.app`, signs it (the first
Apple Development identity, or ad-hoc if none; override with
`WADJET_SIGNING_IDENTITY`), kills a running copy, and opens it. Extra
arguments are forwarded to xcodebuild (`./run.sh SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`).
`WADJET_NO_OPEN=1 ./run.sh` builds and signs without launching — that is what CI
does.

The app runs in the App Sandbox, so its data (temporary Captures, History, log) lives in its
container: `~/Library/Containers/cx.mia.wadjet/Data/Library/Application Support/wadjet/`.
Settings live in `config.json` in that folder and are picked up live when you edit it.
Screenshots save to `~/Pictures/Wadjet`: each Canvas in `original/`, its flattened image in
`flattened/`, under the same name. Recordings save to `~/Movies/Wadjet`. `folders` in
`config.json` (or Settings) changes where new Captures save; existing files stay put.

`WADJET_CLEAR_GLASS=0 ./run.sh` builds the store variant without the private
clear-glass lens patch (the lens then sits behind the toolbar icons with
regular glass).

`cd WadjetKit && swift test` runs the UI-free tests (colour formats, Measure
edge finding, config store) without building the app.

Screen Recording permission is required for Freeze Frame; grant it in
System Settings > Privacy & Security > Screen & System Audio Recording (the
permission alert has a shortcut to that pane) and trigger again.

## Store build

    xcodebuild archive -project Wadjet.xcodeproj -scheme Wadjet -configuration Release \
        -destination 'generic/platform=macOS' -archivePath build/Wadjet.xcarchive \
        CODE_SIGN_IDENTITY="Apple Development"
    xcodebuild -exportArchive -archivePath build/Wadjet.xcarchive \
        -exportOptionsPlist ExportOptions.plist -exportPath build/export

The archive builds without CLEAR_GLASS_PATCH, so the private lens patch is
compiled out. Export needs Apple Distribution and Mac Installer Distribution
certificates and a Mac App Store provisioning profile for `cx.mia.wadjet`.

## Shortcuts

wadjet ships with no shortcuts. Add them in Settings > Shortcuts or in `config.json`:

    "shortcuts": [
      { "keys": "ctrl+opt+cmd+9", "tool": "pickColour" },
      { "keys": "shift+cmd+4", "tool": "captureRegion", "workflow": "Screenshot",
        "options": { "countdown": 3, "cursor": false } }
    ]

`keys` parses `cmd`/`shift`/`opt`/`ctrl` (plus `command`/`option`/`alt`/`control` and
`enter`/`esc`/`backspace` aliases) with a–z, 0–9, f1–f20, space, tab, return, escape,
delete, the arrows and punctuation; every shortcut needs a modifier unless it's an
f-key. `tool` is a ToolID (`captureRegion`, `captureWindow`, `captureScreen`,
`recordRegion`, `recordWindow`, `recordScreen`, `pickColour`, `copyText`, `measure`,
or a Markup Tool: `directSelect`, `eraser`, `draw`, `text`, `censor`, `shapes`,
`counter`, `magnify`, `freezeRegion`).
`workflow` names a Workflow of the right kind for the tool; the optional `options`
apply countdown/systemAudio/microphone/cursor/clickCircles before the tool triggers,
and `freeze`/`freezeWhileRecording` override whether the tool opens on a Freeze
Frame (`capture.freezeWhileRecording` does the same globally during a recording).
Edits are picked up live; a shortcut that clashes with an enabled macOS screenshot
shortcut is still registered but flagged with a toast and a log line.
`defaultWorkflows.screenshot` / `.recording` pick the Workflow each kind runs when
neither a Shortcut nor the tool's menu overrides it.
- Esc cancels by priority: open Workflow menu > overlay > countdown > in-flight toast > idle
  toast. A global Esc hotkey is registered only while something cancellable is active —
  it is never claimed while recording, so Esc reaches the app being recorded.
- The remaining Tools live in the eye menu and the toolbar.

## Debug command channel

`tools/cmd.sh <command>` posts a DistributedNotificationCenter command so the app is
driveable without coordinate clicking. Every command is logged as `cmd: …` in
`~/Library/Containers/cx.mia.wadjet/Data/Library/Application Support/wadjet/app.log`.

    tools/cmd.sh open "Measure"          # open overlay on a Tool (as if its hotkey fired)
    tools/cmd.sh tool "Pick Colour"      # switch Tool while frozen
    tools/cmd.sh workflow "Screenshot"   # pick the Workflow a Tool's capture runs
    tools/cmd.sh menu "Capture Region"   # open a Tool's dropdown / closemenu to dismiss
    tools/cmd.sh option countdown 3      # Off|3|5|10
    tools/cmd.sh option measureMode "Horizontal" # Bounds|Spacing|Horizontal|Vertical
    tools/cmd.sh option colourFormat "hsl()"     # Hex|rgb()|hsl()|oklch()|lab()|SwiftUI
    tools/cmd.sh option island off       # showIslandWhileRecording
    tools/cmd.sh option audio|mic|cursor|clicks on|off
    tools/cmd.sh expand / collapse       # island -> glass toolbar
    tools/cmd.sh upload succeed|fail|offline
    tools/cmd.sh pause / stop            # during a recording
    tools/cmd.sh esc                     # runs the Esc handler

`tools/drive.swift` (compile to /tmp/drive) posts CGEvents for pointer/drag/key input; use it
only while the overlay is up or at known app windows.

## What's real

- Freeze Frame: SCScreenshotManager, per display at its native pixel size, cursor shown
  but every pixel read (Pick Colour, loupe, Measure) taken from a second cursor-free
  capture; hotkey-to-visible latency per open plus session p50/p95 goes to the app log
  and the state HUD.
- Region/window/screen selection on the frozen pixels with macOS-style dimming, window
  capture "through" the overlay via SCContentFilter(desktopIndependentWindow:), a crosshair
  loupe (magnified pixels, x/y, hex), Pick Colour (many formats to pasteboard), Copy Text
  (real Vision OCR), Measure (Screen Ruler-style bounds/spacing/edge modes), scroll-wheel
  variant cycling, Space for Region<->Window.
- The black fake Dynamic Island on every display (notch form on the built-in screen): morphs
  on hover into the dark-tinted Liquid Glass toolbar — Workflow dropdown and Tool options
  inline, iOS 26-style selection lens with real refraction and rim aberration, custom
  tooltips.
- Recording writes an H.264 MP4 through its own AVAssetWriter, with pause, and runs its
  Workflow (Save file to `folders.recordings`).
- Recording is stoppable from both the status item (● time + Pause/Stop menu) and the island
  (red dot + time); the "Show Island While Recording" option toggles only the island.
  Countdown supported; Esc during countdown cancels.
- Toasts: iOS-style thumbnail card top-right, status chip, detail line, duration badge on
  recordings; slide-in, hover pauses, click opens the Canvas in the Editor, drag dismisses, stacks to 3.
  Text-only toasts (Copy Text, Pick Colour) are compact dark pills.
- Pin: places the Screenshot's Canvas where it was captured, as a Markup image Annotation.
- Markup: Select, Direct Select, Eraser, Knife, Draw, Shapes, Text, Step counter, Censor,
  Magnify and Freeze region draw Annotations on the live screen or the Freeze Frame, and
  Capture and Record Tools capture them.
- Canvas and Editor: every Screenshot keeps a `.wadjet` Canvas in the screenshots folder's
  `original/`. The Editor opens it (from the toast, Recent, or Finder) or any image file to
  recrop it and edit its Annotations, then saves, copies, shares, exports, or runs a
  Screenshot Workflow. Old Canvases shrink on `canvasRetention`'s deadlines.
- Screenshots run their Workflow: config.json's `workflows` list (Save file to
  `flattened/` in `folders.screenshots`, Copy image, Show toast); captures land in the
  Captures dir and the 7-day sweep clears what Save file didn't keep.
- History: every Capture is recorded with OCR text from Screenshots; the Recent submenu
  shows the last 10 and outlives the swept files.

## What's simulated or missing

- Uploads aren't built. The Debug submenu's Next Upload items (and the `upload` cmd) only
  pick the result of the toast's simulated Retry (Succeed / Fail / Offline).
- Recordings have no audio, and the system audio, microphone and click circles options
  do nothing yet. Picking the GIF Workflow records an MP4 and runs the built-in MP4 Workflow.
- Destinations and the History window aren't built yet.
