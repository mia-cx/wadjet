# wadjet

## Building and testing the app

- Build through `apps/macos/run.sh`, not Xcode's Run button or a bare `xcodebuild`: macOS ties the Screen Recording grant to the bundle's signing identity, and only run.sh signs with Apple Development (the project defaults to ad-hoc). An ad-hoc build re-prompts every time.
- `Sources/Wadjet` is a folder-synced group: add Swift files on disk and never edit `project.pbxproj` for them.
- `swift test` in `apps/macos/WadjetKit` tests the UI-free code (colour formats, Measure edge finding, config store, workflow runner) without the app.
- Local builds use the Xcode beta (`run.sh` sets `DEVELOPER_DIR`); CI builds with the runner's stable Xcode 26 and warnings as errors. Keep the code compiling on both.
- Drive the running app with `apps/macos/tools/cmd.sh` and read the result in `~/Library/Containers/cx.mia.wadjet/Data/Library/Application Support/wadjet/app.log`, because the overlay can't be inspected while you sit outside it.
- Get Mia's go-ahead before any screenshot, screen recording, or synthetic mouse input: her screens show work.

## TypeScript workspace

- The root is a pnpm Turborepo with Biome. `pnpm lint`, `pnpm build`, and `pnpm test` cover `packages/*` and `apps/*` except `apps/macos`.
- `packages/protocol/PROTOCOL.md` quotes every fixture in `packages/protocol/fixtures/` in full, and a test fails when they disagree. Change both together.

## Code gotchas

- The selection lens strips Liquid Glass blur and tint by swizzling the private `CABackdropLayer.setFilters:` (`ClearGlassPatch` in `main.swift`). SwiftUI offers no public control for it, so keep the patch and recheck it after each macOS update. It compiles only with the `CLEAR_GLASS_PATCH` condition, which run.sh sets and store builds leave off (`WADJET_CLEAR_GLASS=0 ./run.sh`).
- Each display has its own Freeze Frame panel. Convert `NSEvent.mouseLocation` with `window.convertPoint(fromScreen:)` before using it in a view, because raw screen coordinates are only correct on the display at origin 0,0.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on the public repo mia-cx/wadjet. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
