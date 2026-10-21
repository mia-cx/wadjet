# wadjet

A macOS-native capture tool in the spirit of ShareX, for macOS 26+.

## Why it exists

CleanShot X couldn't upload to my own server.
iShare couldn't capture the cursor during region capture, or hand me the file once the link reached the clipboard.
Its recording never worked for me, either.
I'm building wadjet to fix these frustrations without adding complexity.

## Screenshots

![Expanded toolbar hanging from the notch](docs/images/toolbar-notch.png)

![Selection lens over a Tool on an external display's fake Dynamic Island toolbar](docs/images/toolbar-lens.png)

![Notch during a Recording](docs/images/recording-notch.png)

## Status

**v0.0.1. Early, with working Screenshot, Recording, and Markup Tools. Uploads aren't built yet.**

What works today:

- Freeze Frame on every display, cursor included. Capture a region, window, or screen.
  Window Capture reaches the real window through the Freeze Frame.
- HDR Freeze Frames and HDR Screenshots on HDR displays, with HEIC gain-map output.
- Pick colour, Copy text via Vision OCR, and Measure copy their results to the clipboard.
- Markup Tools that draw Annotations on the live screen or the Freeze Frame, which Capture and Record Tools then capture.
- An editable Canvas for every Screenshot in `~/Pictures/Wadjet/original/`.
  Save file writes the flattened image to `~/Pictures/Wadjet/flattened/` under the same name.
- The Editor, which opens a Canvas or any image file to recrop it and edit its Annotations, then save, copy, share, export, or run a Screenshot Workflow.
- Thumbnail toasts that open the Editor, and Pin to screen, which places a Screenshot on screen as a Markup image.
- MP4 Recording with pause, saved to `~/Movies/Wadjet`. Recordings have no audio yet.
- Workflows of local Steps, Shortcuts, and a Settings window.
- History of every Capture, with the text found in Screenshots, and a Recent submenu of the last 10.
- A toolbar on every display, integrated with the notch or a fake Dynamic Island, expanding on hover.

Uploads, Destinations, GIF Recording, and the History window aren't built yet.

## Where it's heading

- Workflows of ordered Steps for saving, copying, opening, pinning, and uploading each Capture.
- Destinations including Wadjet Servers, cloud storage, and custom `.sxcu` imports from ShareX.
- GIF Recording, audio, and an optional trim Step.
- Searchable history across Macs through Wadjet Server listings.
- A self-hostable Wadjet Server for Cloudflare, Docker, and Kubernetes through a Helm chart.

See [DIRECTION.md](DIRECTION.md) for the full picture.

## Build and run

Requires macOS 26+ and Xcode 26 or newer. From the repo root:

```sh
apps/macos/run.sh
```

The script builds, bundles, signs, and opens `apps/macos/build/Wadjet.app`, replacing any running copy.
It uses an Apple Development signing identity when available, or ad-hoc signing otherwise.
`swift test --package-path apps/macos/WadjetKit` runs the UI-free unit tests without building the app.
To build and sign without launching, as CI does:

```sh
WADJET_NO_OPEN=1 apps/macos/run.sh
```

Grant Screen Recording permission in **System Settings > Privacy & Security > Screen & System Audio Recording**.
Then trigger a Tool again.

wadjet ships no Shortcuts.
Add them in **Settings > Shortcuts** or in `config.json`, as [the macOS app README](apps/macos/README.md#shortcuts) shows.
A Record Shortcut pressed again stops the Recording.

The Tools are in the eye menu and toolbar. Esc dismisses the Freeze Frame or cancels a countdown.
Esc does not stop a Recording.
See [the macOS app README](apps/macos/README.md#debug-command-channel) for the debug command channel.

## Repo layout

`apps/macos/` contains the Swift macOS app. It builds with Xcode and stays outside the pnpm workspace.

`packages/protocol/` holds the [Wadjet Server protocol](packages/protocol/PROTOCOL.md), its fixtures, and Effect Schemas for every request and response.

`apps/server/` is the Wadjet Server on Node. See [its README](apps/server/README.md) for configuration.

The TypeScript side is a pnpm Turborepo. From the repo root, with Node 24+:

```sh
pnpm install
pnpm lint && pnpm build && pnpm test
pnpm dev
```
