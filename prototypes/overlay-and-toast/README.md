# Overlay + Toast prototype (throwaway)

Answers mia-cx/wadjet#12 (Freeze Frame overlay and toolbar) and #13 (post-capture toast).

## Run

    ./run.sh

Builds a release binary with the Xcode 27 toolchain, wraps it as `build/WadjetPrototype.app`,
codesigns with the Apple Development identity (so the Screen Recording grant survives rebuilds),
and opens it. Screen Recording permission is required for Freeze Frame; grant it in
System Settings > Privacy & Security > Screen & System Audio Recording (Prototype menu has a
shortcut to that pane) and trigger again.

## Hotkeys

- ⌘⇧4 Capture Region, ⌘⇧3 Capture Screen, ⌘⇧5 Record Region (press again to stop a recording).
- Esc cancels by priority: open Workflow menu > overlay > countdown > in-flight toast > idle
  toast > Pin. A global Esc hotkey is registered only while something cancellable is active —
  it is never claimed while recording, so Esc reaches the app being recorded.
- The remaining Tools live in the eye menu and the toolbar.

## Debug command channel

`tools/cmd.sh <command>` posts a DistributedNotificationCenter command so the prototype is
driveable without coordinate clicking. Every command is logged as `cmd: …` in the log.

    tools/cmd.sh open "Measure"          # open overlay on a Tool (as if its hotkey fired)
    tools/cmd.sh tool "Pick Colour"      # switch Tool while frozen
    tools/cmd.sh workflow "Upload to w.mia.cx"
    tools/cmd.sh option countdown 3      # Off|3|5|10
    tools/cmd.sh option measureMode "Edges X"  # Region|Line|Edges X|Edges Y|Edges X+Y
    tools/cmd.sh option colourFormat RGB # Hex|RGB|HSL
    tools/cmd.sh option island off       # showIslandWhileRecording
    tools/cmd.sh expand / collapse       # island -> glass toolbar
    tools/cmd.sh upload succeed|fail|offline
    tools/cmd.sh steperror on|off
    tools/cmd.sh pause / stop            # during a recording
    tools/cmd.sh esc                     # runs the Esc handler

`tools/drive.swift` (compile to /tmp/drive) posts CGEvents for pointer/drag/key input; use it
only while the overlay is up or at known app windows.

## What's real

- Freeze Frame: SCScreenshotManager, per display, cursor included; trigger-to-visible latency
  is measured (~60-160 ms) and logged/shown in the state HUD.
- Region/window/screen selection on the frozen pixels with macOS-style dimming (15% idle,
  35% outside the selection, undimmed inside + white border), window tinting from
  SCShareableContent frames, crosshair loupe (magnified pixels, x/y, hex), Pick Colour
  (Hex/RGB/HSL to pasteboard), Copy Text (real Vision OCR on the crop, off the main actor,
  "Recognising text…" toast then "Copied N lines"), Measure (region, line with Shift 45-degree
  snap, edge detection in X/Y/X+Y, px/pt/in/cm from CGDisplayScreenSize, dark popover).
- The black fake Dynamic Island: opaque #000 capsule flush in the menu-bar band (merging with
  the notch on notched displays), morphs on hover into the dark-tinted Liquid Glass toolbar —
  one shape, spring ~0.35 s, square top / rounded bottom; Workflow dropdown and Tool options
  inline; custom tooltips (0.5 s hover).
- Recording is stoppable from both the status item (● time + Pause/Stop menu) and the island
  (red dot + time, expands to Pause/Stop on hover); the "Show Island While Recording" option
  toggles only the island. Countdown digits supported; Esc during countdown cancels.
- `~/Library/Application Support/wadjet-prototype/prototype.log`: timestamped lines for launch
  permission state, status-item frame, hotkey registration, every phase change, Freeze Frame
  latency per display, debug commands, mouse/hover diagnostics, and errors.
- Toasts: iOS-style thumbnail card top-right (max 220x160, 12 pt corners, white border, shadow),
  status chip overlaid at the bottom ("Saved", "Uploading N%", "Link copied",
  "Couldn't upload" + Retry, "You're offline" + Retry, "Converting N%", "Cancelled"), detail
  line under the card, red "Open in app failed" chip for Step errors, duration badge on
  recordings only. Slide-in, 5 s timer, hover pauses, click opens Preview, drag right dismisses,
  stacks to 3 + "+N". Text-only toasts (Copy Text, Pick Colour) are compact dark pills.
- Pin: borderless floating panel, drag to move, scroll to pan, pinch to zoom, edge resize,
  Esc or double-click to close.

## What's simulated

- No recording file is written; the thumbnail is the Freeze Frame crop with a duration badge.
- Uploads and GIF conversion are timed simulations; the Prototype submenu (or `upload` cmd)
  picks the next result (Succeed / Fail / Offline) and `steperror` forces a Step error.
- Destinations, History, Settings menu items are disabled stubs.

## Known gaps

- Vision OCR cold start is ~28 s (first call loads models; it no longer blocks the UI — a
  "Recognising text…" toast waits in place of the result).
- Recordings, uploads and conversions are timed fakes; there is no video encoding or network.
- Measure edges and Copy Text depend on the frozen capture resolution; Loupe/pixels are
  verified (centre cell == cursor pixel), but Shift/Option modifiers need real input (synthetic
  modifier flags were unreliable).
- Debug logging (mouse/hover/hit-test lines) is intentionally left in for interactive testing.
