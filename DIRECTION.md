# wadjet

wadjet is a macOS-native capture tool in the spirit of ShareX, built for Mia's own capture and upload workflows.
It starts as a private Swift app for macOS 26+.

## Current effort

The [wadjet v1 map](https://github.com/mia-cx/wadjet/issues/1) holds the decisions needed for an implementation PRD.
The research, the Workflow model, and the Tools are settled.
There is no app implementation yet.

## Direction

- Capture the cursor and select regions on a Freeze Frame of every screen. It looks like macOS's own screenshot UI.
- A toolbar at the notch, or a fake Dynamic Island on screens without one, holds the Tools and a Workflow picker.
- Tools are Capture region, window, and screen; Record region, window, and screen; Pick colour; Copy text; and Measure. Brushes and markup are deferred.
- Pick colour, Copy text, and Measure put their result on the clipboard and run no Workflow.
- Measure works by region, by line (including diagonals), or by edge detection in X, Y, or both. It shows pixels, points, inches, and centimetres.
- Pick colour copies hex by default; the format is set in Settings or the toolbar.
- Use Workflows to control local outputs, upload, and post-upload behavior. A Workflow accepts Screenshots or Recordings, and Recording Workflows choose MP4 or GIF.
- Mia chooses the order of Steps separately after capture and after upload.
- Shortcuts open one Tool with set options, and can name a Workflow; otherwise the default Workflow runs. URL scheme and CLI triggers are deferred.
- The menu bar icon's menu lists Tools with their Shortcuts, Destinations, history, and Settings, like ShareX.
- A Workflow can repeat a Step, with separate options for each instance.
- Use built-in Steps in v1. Custom command and script Steps are deferred.
- After-capture Steps are Save file, Copy image, Copy file, Open in an app, Show toast, and Pin to screen.
- Show toast is an iOS-style thumbnail in the top-right; clicking it opens the file until the editor exists.
- Pin to screen opens a Screenshot in a borderless, always-on-top window you can drag, pan, zoom, and resize.
- After-upload Steps retain that catalogue and add Copy link, Copy image + link in one clipboard item, and Open link.
- Order Copy image before Copy link for the image-then-link sequence.
- Copy image is unavailable for Recordings; use Copy file instead.
- Every Capture has a file. It is temporary unless a Save file Step keeps a permanent copy.
- Steps have no conditions. A failed Step is skipped, the rest still run, and the error shows in the toast and history.
- A new Capture can start while earlier Captures still run their Steps or upload. Only one Freeze Frame or Recording is on screen at a time.
- Import custom Destinations from ShareX's `.sxcu` format.
- Include Screenshots, MP4 and GIF Recording, capture history, and every Tool above in v1.
- Keep settings in a human-readable config file and secrets in the Keychain.

## Starter Workflows

Ship Screenshot (Save file → Copy image → Show toast), MP4, and GIF (Save file → Show toast) Workflows.
Upload starts disabled. wadjet ships no Shortcuts, like iShare, and flags a hotkey that clashes with an enabled Apple screenshot shortcut.

## Later efforts

Scrolling capture, an annotation editor, and public release are later efforts.
Use [CONTEXT.md](CONTEXT.md) for the glossary and the map's linked tickets for decision details.
