# wadjet

wadjet is a macOS-native capture tool in the spirit of ShareX, built for Mia's own capture and upload workflows.
It starts as a private Swift app for macOS 26+.

## Current effort

The [wadjet v1 map](https://github.com/mia-cx/wadjet/issues/1) holds the decisions needed for an implementation PRD.
The research, the Workflow model, the Tools, upload behavior, Recording UX, and capture history are settled.
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
- Recordings can pause, so wadjet writes them with its own `AVAssetWriter` instead of ScreenCaptureKit's file recorder.
- Recording controls (time, Pause, Stop) sit in the notch toolbar or on the menu bar icon, set per Recording or by Shortcut. The Shortcut again stops.
- Record Tool options: countdown, system audio, microphone, cursor, click circles. All off except the cursor by default.
- A resized window is scaled into the Recording's starting size, with bars where the shape changes.
- MP4 resolution and fps are configurable (1920 px, 30 fps by default) with no length limit.
- GIFs default to 960 px, 15 fps, a 60 s max, 128 colours, and ordered dithering, all configurable.
- wadjet bundles an LGPL ffmpeg build. v1 encodes GIFs with it; a ditherette GPU encoder replaces it later.
- A Recording goes straight to its Workflow. An optional Trim video Step opens a trim window first.
- v1 Destinations are Wadjet Servers, Google Drive, Dropbox, OneDrive, S3-compatible storage, WebDAV, SFTP, and Custom `.sxcu` imports. Imgur and FTP are out.
- A Wadjet Server supports upload, list, and delete, so history can span several Macs. It authenticates with an API key or OAuth, through its own OAuth server or an external IdP.
- S3, WebDAV, and SFTP links come from a public URL prefix the user sets. Cloud drives create an anyone-with-the-link share.
- Destinations are edited in a Settings form. Secret-looking values move to the Keychain, and deletion URLs stay there too.
- Failed uploads retry 3 times on network and server errors, then offer Retry. Offline uploads fail at once instead of queueing.
- The toast shows upload progress and Cancel. Known size limits are checked before uploading.
- History shows in a Recent submenu (last 10) and a History window. Entries outlive their temporary files, which wadjet deletes after 7 days by default.
- History searches the text inside Screenshots, filters by kind, Destination, and date, and merges Wadjet Server listings from other Macs.
- Include Screenshots, MP4 and GIF Recording, capture history, and every Tool above in v1.
- Keep settings in a human-readable config file and secrets in the Keychain.

## Starter Workflows

Ship Screenshot (Save file → Copy image → Show toast), MP4, and GIF (Save file → Show toast) Workflows.
Upload starts disabled. wadjet ships no Shortcuts, like iShare, and flags a hotkey that clashes with an enabled Apple screenshot shortcut.

## Later efforts

Scrolling capture, an annotation editor, and public release are later efforts.
A free public Wadjet Server with 30-day storage may come with public release.
Use [CONTEXT.md](CONTEXT.md) for the glossary and the map's linked tickets for decision details.
