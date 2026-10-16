# wadjet

## Building and testing the app

- Build through `apps/macos/run.sh`, not bare `swift run`: macOS ties the Screen Recording grant to the bundle's signing identity, so only the Apple Development signature keeps the grant across rebuilds. An ad-hoc build re-prompts every time.
- Local builds use the Xcode beta (`run.sh` sets `DEVELOPER_DIR`); CI builds with the runner's stable Xcode 26 and warnings as errors. Keep the code compiling on both.
- Drive the running app with `apps/macos/tools/cmd.sh` and read the result in `~/Library/Application Support/wadjet/app.log`, because the overlay can't be inspected while you sit outside it.
- Get Mia's go-ahead before any screenshot, screen recording, or synthetic mouse input: her screens show work.

## Code gotchas

- The selection lens strips Liquid Glass blur and tint by swizzling the private `CABackdropLayer.setFilters:` (`ClearGlassPatch` in `main.swift`). SwiftUI offers no public control for it, so keep the patch and recheck it after each macOS update.
- Each display has its own Freeze Frame panel. Convert `NSEvent.mouseLocation` with `window.convertPoint(fromScreen:)` before using it in a view, because raw screen coordinates are only correct on the display at origin 0,0.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on the public repo mia-cx/wadjet. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
