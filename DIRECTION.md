# wadjet

wadjet is a macOS-native capture tool in the spirit of ShareX, built for Mia's own capture and upload workflows.
It starts as a private Swift app for macOS 26+.

## Current effort

The [wadjet v1 map](https://github.com/mia-cx/wadjet/issues/1) holds the decisions; the [macOS v1 PRD](https://github.com/mia-cx/wadjet/issues/17) turns them into a build plan, sliced into #18–#45. The [Wadjet Server PRD](https://github.com/mia-cx/wadjet/issues/47) does the same for the server (#48–#56); its 18 drafting decisions follow their recommendations until Mia reviews them.
The [wadjet Markup map](https://github.com/mia-cx/wadjet/issues/89) charts Markup Tools, the Canvas, and the Editor toward a Markup PRD that ships before the v1 release.
The native prototype of the Freeze Frame overlay, toolbar, and toast became the app itself: `apps/macos`, an Xcode project with the UI-free `WadjetKit` package, built by CI on every change.
Shipped on the Mac: sandbox, the live `config.json` store, the Workflow runner with every local Step, Shortcuts, the Settings window, and the History store with OCR and the Recent submenu. Still simulated: Recording and uploads; the History window, Destinations, and GIF are not built yet.
Shipped on the server: the protocol doc with replayed fixtures, the Hono core on Node (filesystem + SQLite), the Docker image (S3 + Postgres optional), and the Cloudflare Worker (R2, D1, edge purge; dry-run only, not deployed). Multipart uploads, thumbnails, deletion links, and the `.sxcu` are in review; OAuth, Helm, and deployment follow.
Not yet checked on a real Mac: anything that needs a capture, because Wadjet has no Screen Recording grant yet.

## Direction

- Capture the cursor and select regions on a Freeze Frame of every screen. It looks like macOS's own screenshot UI.
- Whether a Tool opens on a Freeze Frame or the live screen follows, from weakest to strongest: the global toggle, an optional while-recording setting, an optional per-Shortcut setting, and an optional per-Shortcut while-recording setting. Markup defaults to the live screen during a Recording.
- The toolbar shows on every display at once: as the notch on the built-in display, or a black fake Dynamic Island on other displays, showing the current Tool. It expands on hover into Liquid Glass with touch-size Tool buttons; on displays without a notch it drops below the menu bar instead of covering it. Only the hovered toolbar expands, and only the pointer's display shows the loupe.
- The expanded toolbar groups its Tools: still (Region, Window, Screen) | video (Region, Window, Screen) | utilities (Pick colour, Copy text, Measure), split by thin dividers. One group is open at a time and shows all its Tools; the others collapse to their group's icon (camera, video camera, tools) with a tiny badge of their last-used Tool. Hovering a group opens it, and so does dragging the lens into it, with the same smooth centred expand either way. Markup is its own group: Markup Tools draw Annotations on the live screen or the Freeze Frame, and Capture and Record Tools capture them.
- Region selection either confirms on release or waits for a manual confirm, so a region can be moved and resized before the Screenshot is taken or the Recording starts. A toggle switches between the two. There are no typed width/height fields.
- Clicking the selected Tool opens its menu: its Workflow, Recording options, copy format, or Measure mode. Each Tool keeps its own Workflow.
- Each Tool shows a short permanent label under its icon (collapsed groups read Still / Video / Utilities); Tools have no hover tooltips — the recording and confirm buttons keep theirs. The loupe flips to stay on screen.
- Scroll cycles the selected Tool's variants: Region, Window, Screen (within Capture or within Record), Measure modes, or copy formats. Option+scroll changes the Tool's value, such as Measure's tolerance. Space toggles Region and Window, as in macOS.
- Freeze Frames and Screenshots keep HDR on HDR displays; HDR Screenshots save as HEIC with a gain map. Recordings are SDR in v1.
- Tools are Capture region, window, and screen; Record region, window, and screen; Pick colour; Copy text; and Measure. Markup Tools arrive with the Markup map.
- Pick colour, Copy text, and Measure put their result on the clipboard and run no Workflow.
- Measure works like PowerToys Screen Ruler: Bounds (drag a box; Shift keeps it), Spacing, Horizontal, and Vertical, which find edges from the pointer on the Freeze Frame. Values are in points; a click copies them.
- Pick colour's loupe shows hex, rgb, hsl, oklch, and lab. It copies hex by default; the format is set in Settings or the Tool's menu.
- Use Workflows to control local outputs, upload, and post-upload behavior. A Workflow accepts Screenshots or Recordings, and Recording Workflows choose MP4 or GIF.
- Mia chooses the order of Steps separately after capture and after upload.
- Shortcuts open one Tool with set options, and can name a Workflow; otherwise the default Workflow runs. URL scheme and CLI triggers are deferred.
- The menu bar icon's menu lists Tools with their Shortcuts, Destinations, history, and Settings, like ShareX.
- A Workflow can repeat a Step, with separate options for each instance.
- Use built-in Steps in v1. Custom command and script Steps are deferred.
- After-capture Steps are Save file, Copy image, Copy file, Open in an app, Show toast, and Pin to screen.
- Show toast is an iOS-style thumbnail in the top-right; clicking it opens the file until the Editor exists, then the Screenshot's Canvas in the Editor.
- Pin to screen opens a Screenshot in a borderless, always-on-top window you can drag, pan, zoom, and resize. Once Markup ships, it places the Screenshot's Canvas on screen as an image Annotation instead.
- After-upload Steps retain that catalogue and add Copy link, Copy image + link in one clipboard item, and Open link.
- Order Copy image before Copy link for the image-then-link sequence.
- Copy image is unavailable for Recordings; use Copy file instead.
- Every Capture has a file. It is temporary unless a Save file Step keeps a permanent copy.
- Steps have no conditions. A failed Step is skipped, the rest still run, and the error shows in the toast and history.
- A new Capture can start while earlier Captures still run their Steps or upload. Only one Freeze Frame or Recording is on screen at a time.
- Recordings can pause, so wadjet writes them with its own `AVAssetWriter` instead of ScreenCaptureKit's file recorder.
- Recording controls (time, Pause, Stop) sit on the menu bar icon and in the island. Either one stops, as does the Shortcut again. Esc never cancels a Recording.
- Record Tool options: countdown, system audio, microphone, cursor, click circles, and show island while recording. Cursor and island are on by default; the rest are off.
- A resized window is scaled into the Recording's starting size, with bars where the shape changes.
- MP4 resolution and fps are configurable (1920 px, 30 fps by default) with no length limit.
- GIFs default to 960 px, 15 fps, a 60 s max, 128 colours, and ordered dithering, all configurable.
- GIFs are encoded by ditherette's GPU encoder, not ffmpeg. GIF Recording is in v1 but waits for that encoder; TestFlight alphas ship without it.
- The app is sandboxed so alphas can go through TestFlight; the store listing stays a public-release concern. Screenshots save to `~/Pictures/Wadjet` and Recordings to `~/Movies/Wadjet` by default; other folders are granted through a folder picker.
- The selection lens keeps its private glass patch behind a build flag. With the flag off, the lens sits behind the toolbar icons so blur and tint never hide them.
- A Recording goes straight to its Workflow. An optional Trim video Step opens a trim window first.
- v1 Destinations are Wadjet Servers, Google Drive, Dropbox, OneDrive, S3-compatible storage, WebDAV, SFTP, and Custom `.sxcu` imports. Imgur and FTP are out.
- A Wadjet Server supports upload, list, and delete, so history can span several Macs. It authenticates with an API key or OAuth, through its own OAuth server or an external IdP.
- The protocol starts at `/.well-known/wadjet`, uploads large files in resumable parts, takes a wadjet-made thumbnail per file, and serves short links.
- wadjet ships a Wadjet Server like Caelestis's backend: one Hono codebase for Cloudflare (Worker, R2, D1), Docker (filesystem or S3, SQLite or Postgres), and a Helm chart.
- v1 server auth is an API key plus an external IdP (Hecate). It serves a `.sxcu` and single-file deletion links so ShareX on Windows can share it.
- The repo is a Turborepo: the macOS app and the server live under `apps/`, shared code under `packages/`. The Turborepo tooling arrives with the server.
- `apps/macos` becomes an Xcode project, for the Settings window, other Apple platforms, and a possible Mac App Store build. Its UI-free core (Workflows, config, `.sxcu`, Destinations, history) is a testable library.
- The Mac app and the Wadjet Server get separate PRDs, joined by the protocol. The Swift protocol client is hand-written.
- v1 builds in this order: Workflows, history, Recording, Wadjet Server uploads, then the other Destinations.
- Shortcuts use the KeyboardShortcuts package for hotkeys and the Settings recorder.
- i.mia.cx stays as it is. w.mia.cx runs the Wadjet Server once it can replace iShare.
- S3, WebDAV, and SFTP links come from a public URL prefix the user sets. Cloud drives create an anyone-with-the-link share.
- Destinations are edited in a Settings form. Secret-looking values move to the Keychain, and deletion URLs stay there too.
- Failed uploads retry 3 times on network and server errors, then offer Retry. Offline uploads fail at once instead of queueing.
- The toast shows upload progress and Cancel. Known size limits are checked before uploading.
- History shows in a Recent submenu (last 10) and a History window. Entries outlive their temporary files, which wadjet deletes after 7 days by default.
- History searches the text inside Screenshots, filters by kind, Destination, and date, and merges Wadjet Server listings from other Macs.
- Include Screenshots, MP4 and GIF Recording, capture history, and every Tool above in v1.
- Keep settings in a human-readable JSON config file in the app's container, reloaded live on outside edits, and secrets in the Keychain.
- Settings is a System Settings-style sidebar window; its panes and the menu bar menu get refined after Mia has used v1.

## Starter Workflows

Ship Screenshot (Save file → Copy image → Show toast), MP4, and GIF (Save file → Show toast) Workflows.
Upload starts disabled. wadjet ships no Shortcuts, like iShare, and flags a hotkey that clashes with an enabled Apple screenshot shortcut.

## Later efforts

Scrolling capture and public release are later efforts.
A free public Wadjet Server with 30-day storage may come with public release.
Use [CONTEXT.md](CONTEXT.md) for the glossary and the map's linked tickets for decision details.
