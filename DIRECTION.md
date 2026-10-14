# wadjet

wadjet is a macOS-native capture tool in the spirit of ShareX, built for Mia's own capture and upload workflows.
It starts as a private Swift app for macOS 26+.

## Current effort

The [wadjet v1 map](https://github.com/mia-cx/wadjet/issues/1) holds the decisions needed for an implementation PRD.
The research and the Workflow model are settled.
There is no app implementation yet.

## Direction

- Capture the cursor and select regions on a Freeze Frame.
- Use Workflows to control capture, local outputs, upload, and post-upload behavior.
- Mia chooses the order of Steps separately after capture and after upload.
- Workflows launch through hotkeys and the menu bar. Hotkeys are optional; URL scheme and CLI triggers are deferred.
- A Workflow can repeat a Step, with separate options for each instance.
- Use built-in Steps in v1. Custom command and script Steps are deferred.
- After-capture Steps are Save file, Copy image, Copy file, Open in an app, and Show toast.
- After-upload Steps retain that catalogue and add Copy link, Copy image + link in one clipboard item, and Open link.
- Order Copy image before Copy link for the image-then-link sequence.
- Copy image is unavailable for Recordings; use Copy file instead.
- Every Capture has a file. It is temporary unless a Save file Step keeps a permanent copy.
- Steps have no conditions. A failed Step is skipped, the rest still run, and the error shows in the toast and history.
- A new Capture can start while earlier Captures still run their Steps or upload. Only one Freeze Frame or Recording is on screen at a time.
- Import custom Destinations from ShareX's `.sxcu` format.
- Include screenshot capture, MP4 and GIF Recording, capture history, OCR, Pin, and Color Picker in v1.
- Keep settings in a human-readable config file and secrets in the Keychain.

## Starter Workflows

Ship region, window, and full-screen screenshot Workflows, plus region MP4 and region GIF Workflows.
Screenshots run Save file → Copy image → Show toast. Recordings run Save file → Show toast.
Upload starts disabled. Starters have no hotkeys, like iShare; wadjet flags a hotkey that clashes with an enabled Apple screenshot shortcut.

## Later efforts

Scrolling capture, an annotation editor, and public release are later efforts.
Use [CONTEXT.md](CONTEXT.md) for the glossary and the map's linked tickets for decision details.
