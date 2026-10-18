# Markup and annotation tools in other screenshot apps

Research for wadjet's markup feature, checked 2026. Sources are first-party docs, changelogs, issue trackers, or source code; anything not confirmed from a primary source is marked *unverified*.

## Short answer

Every surveyed tool ships the same core set: **arrow, rectangle, ellipse, freehand pen, text, highlighter/marker, blur-or-pixelate, and crop**. Step counters, callout/speech bubbles, spotlight (dim-outside), and magnifier loupe are common but not universal.

The differentiators:

- **Editable objects vs flat pixels.** Snagit, CleanShot X, ShareX, Shottr, Snipaste, Apple Markup, and Greenshot treat placed annotations as selectable objects you can move, restyle, and delete before finishing. Flameshot added post-placement editing in v0.10 but it stays session-only. Only Snagit (`.snagx`, auto-saved to a Library) and CleanShot X (`.cleanshot` project files) let you re-open a saved capture with annotations still editable.
- **Where markup happens.** Windows/Linux tools (ShareX, Greenshot, Flameshot, Snipaste) annotate inline on the capture overlay before committing. macOS apps (CleanShot, Shottr, Xnapper, Apple Markup) annotate in a separate editor opened from a floating thumbnail, or a dedicated window. Snagit does both: inline Screen Draw during video, full editor after.
- **Smart redaction.** Snagit Smart Redact auto-detects emails, credit cards, phone numbers, faces, URLs etc. Xnapper has one-click automatic redaction of emails/cards/API keys plus OCR text selection. Shottr's pixelate has a "Text mode" that hides text without corrupting the rest. Nobody else auto-detects content to redact.
- **Snagit alone** offers Smart Move (move detected UI elements), Simplify (replace UI with placeholder objects), and Capture-step generation from clicks.
- **Video annotation** is rare: Snagit Screen Draw (arrow/shape/step/pen drawn on screen during recording, fading after N seconds) and CleanShot's Studio Mode (post-recording zooms, cursor, keystrokes) are the only two.

## Feature matrix

| Tool | Arrow | Line | Rect/Ellipse | Pen | Highlighter | Text | Callout | Counter | Blur | Pixelate | Solid redact | Spotlight | Loupe | Crop | Stickers/img | Editable objects | Re-editable file |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| CleanShot X | ✓ (4 styles) | ✓ | ✓ | ✓ smoothed | ✓ | ✓ | partial (text+shape) | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ (combine imgs) | ✓ | ✓ `.cleanshot` |
| Shottr | ✓ bendable | ✓ | ✓ | ✓ | ✓ | ✓ | partial | ✓ | partial (erase) | ✓ text mode | partial | ✓ | ✓ (v1.9) | ✓ | ✓ overlays | ✓ | ✗ |
| Apple Markup | via shapes | ✓ | ✓ | ✓ sketch/draw | ✓ box | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ loupe | ✓ | ✗ | ✓ | partial (PDF) |
| Snagit | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ step | ✓ | ✓ | ✓ | ✓ (Mac) | ✓ | ✓ | ✓ stamps | ✓ | ✓ `.snagx` |
| ShareX | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | via shape | ✓ | ✓ | ✓ | ✓ sticker/emoji | ✓ session | ✗ |
| Greenshot | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ counter | ✓ | ✓ | via shape | ✓ (highlight area) | ✓ | ✓ | ✗ | ✓ session | partial `.greenshot` |
| Flameshot | ✓ | ✓ | ✓ | ✓ | ✓ marker | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ box | ✗ | ✗ | via selection | ✗ | partial | ✗ |
| Snipaste | ✓ (linestrip) | ✓ | ✓ | ✓ pencil | ✓ marker | ✓ | ✗ | ✓ (PRO group) | ✓ gaussian | ✓ mosaic | via shape | ✗ | ✓ (PRO) | via selection | ✓ paste imgs | ✓ | ✗ |
| Skitch | ✓ tapered | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✓ stamps | partial | ✗ |
| Xnapper | ✓ | ✗ | ✓ shapes | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ redact | ✓ | ✗ | ✗ | via ratio | ✗ | ✓ | ✗ |

*partial = exists in a different form; details in the per-tool sections.*

## Per-tool notes

### CleanShot X (macOS, paid)

- **Tools:** crop (aspect ratios, edge snapping), pixelate (randomized for security), arrow (4 styles incl. curved), blur (secure and smooth variants), spotlight, counter (step marks), pencil (auto-smoothed), highlighter (smart text-size detection), text, shapes, plus rotate/flip and combining multiple screenshots on one canvas. [features](https://cleanshot.com/features)
- **Vector vs raster:** annotations are editable objects; `.cleanshot` project files keep annotations, redactions and styling editable on re-open. [features](https://cleanshot.com/features)
- **Where markup happens:** separate Annotate window, reachable from the Quick Access Overlay thumbnail after capture or as a post-capture action (`action=annotate` in the URL API). [docs-api](https://cleanshot.com/docs-api)
- **Styling:** screen color picker with saved favorite colors, 7 predefined styles, brand presets. [features](https://cleanshot.com/features)
- **Smart features:** highlighter detects text size; OCR tool detects links. [features](https://cleanshot.com/features), [changelog](https://cleanshot.com/changelog)
- **Video:** Studio Mode adds post-recording smooth zooms, cursor smoothing, motion blur, backgrounds, keystroke/camera adjustments. [changelog](https://cleanshot.com/changelog)
- **Quirk:** counter objects were changed to always render on top. [changelog](https://cleanshot.com/changelog)
- Single-letter tool shortcuts in Annotate: *unverified*.

### Shottr (macOS, freemium)

- **Tools:** text, freehand drawing (stroke variability via cmd+enter, smoothness via opt+↑/↓), text highlighter (cap style via cmd+enter), spotlight (background opacity via keys 1–9), arrows (every type bendable since v1.9), magnifier (v1.9), selection cutout (v1.9), pixelate with a "Text mode" that hides text without corrupting surroundings, "remove objects" erasure, screen ruler (↑↓/←→ then click to imprint measurement), image overlays with opacity and before/after GIF generation, scrolling screenshots, OCR+QR. [shottr.cc](https://shottr.cc/), [v1.7 release notes](https://shottr.cc/newversion.html)
- **Vector vs raster:** annotations are objects over the original raster; raster ops (crop, blur, erase, measure, color-pick) only apply to the original screenshot until `Edit → Rasterize Image` flattens everything irreversibly. [FAQ](https://shottr.cc/kb/faq)
- **Re-editable file:** none — Rasterize is the only merge path. [FAQ](https://shottr.cc/kb/faq)
- **Where markup happens:** editor window after capture (`then=edit`/`then=thumbnail` URL params). [urlschemes](https://shottr.cc/kb/urlschemes)
- **Styling:** custom annotation colors, color inspector with OKLCH, WCAG/APCA contrast checker, hand-drawn style for arrows/ovals/rects/labels (v1.9). [newversion](https://shottr.cc/newversion.html)
- **Smart features:** OCR, object snapping (v1.9), WCAG contrast ratio shown above the selection marquee. [newversion](https://shottr.cc/newversion.html)

### Apple Markup (macOS 26/27 built-in)

- **Tools:** selection tools (rect, ellipse, lasso, smart lasso), Instant Alpha background removal, Sketch (auto-recognized standard shapes), Draw (Force Touch pressure), shapes palette including **Loupe** (stackable magnifier with green/blue handles) and a Highlight box shape, text, text-highlight (PDFs), signatures, crop, rotate. [Mark up files on Mac](https://support.apple.com/guide/mac-help/mark-up-files-mchl1fd88863/mac)
- **No arrow-with-line tool, no counter, no blur/pixelate/redact, no spotlight** — notable gaps for a screenshot tool.
- **Vector vs raster:** placed items are objects (option-drag duplicates with yellow alignment guides; Revert strips all markup). [same](https://support.apple.com/guide/mac-help/mark-up-files-mchl1fd88863/mac) On PDFs the marks persist as standard PDF annotations (editable on re-open in Preview); on flat image formats they're flattened on save — *unverified for every format*.
- **Where markup happens:** floating post-capture thumbnail, Quick Look, Preview, Mail, Photos, Continuity Markup on iPhone/iPad. [same](https://support.apple.com/guide/mac-help/mark-up-files-mchl1fd88863/mac), [screenshots](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac)

### Snagit (Windows/macOS, paid)

- **Tools:** arrows, lines, shapes, pen, highlighter, text, callouts (multi-tail, cloud tails), Step tool (numbered markers), stamps, spotlight (Mac only, dims *and* blurs outside), magnify, blur, fill, plus Smart Eraser and "add capture info". [features](https://www.techsmith.com/snagit/features/), [tools index](https://www.techsmith.com/learn/tutorials/section/snagit/snagit-tools/)
- **Vector vs raster:** all placed items are vector-style objects editable until flattened (Ctrl+T / Flatten All). `.snagx` is a cross-platform project format; captures auto-save as snagx into the Library so every past capture stays editable. [file-save-tips](https://www.techsmith.com/learn/tutorials/snagit/file-save-tips/), [SNAGX objects](https://support.techsmith.com/hc/en-us/articles/115002473092)
- **Where markup happens:** Snagit Editor after capture; Library keeps history.
- **Styling:** themes/Quick Styles, custom color palettes, favorites, templates. [simplify tutorial](https://www.techsmith.com/learn/tutorials/snagit/simplify/)
- **Smart features:** **Smart Redact** auto-detects addresses, credit cards, dates, emails, faces, IPs, phone numbers, SSNs, URLs — applied as black shapes, switchable to blur/pixelate, per-category toggles, editable before flattening. [smart-redact](https://www.techsmith.com/snagit/features/smart-redact/), [hide-sensitive-info](https://www.techsmith.com/learn/tutorials/snagit/hide-sensitive-information/) **Smart Move** detects UI elements so they can be moved; **Simplify** auto-overlays text/UI with simplified objects with a Detail slider; step recorder builds guides from clicks; text recognition edits text in place. [features](https://www.techsmith.com/snagit/features/)
- **Video:** **Screen Draw** — arrow (A), square (S), step counter (1), pen (P, Mac) drawn onto the screen mid-recording via Ctrl+Shift+D; marks fade after a configurable duration (default 3s); colors follow the editor theme. [screen-draw](https://www.techsmith.com/learn/tutorials/snagit/screen-draw/)

### ShareX (Windows, OSS)

- **Tools:** rectangle, ellipse, line, arrow, freehand, text (outline and background), speech balloon, step counter (numeric/alpha/roman sequences, per changelog), magnify, highlight, spotlight (with blur amount), blur, pixelate, smart eraser, cursor insert, image/sticker/emoji insert, crop, cut-out. [image-editor docs](https://getsharex.com/docs/image-editor), [repo readme](https://github.com/ShareX/ShareX.ImageEditor), [changelog 21.0.0](https://getsharex.com/changelog.html)
- **Vector vs raster:** annotations are objects — select, move (mouse or arrow keys), duplicate, restyle, reorder, delete — until flattened on completion. Rotation supported on most effect annotations since 21.0. No project file format; editability ends at export. [image-editor docs](https://getsharex.com/docs/image-editor)
- **Where markup happens:** two places — lightweight annotation inline on the region-capture overlay, and the full image editor (Greenshot-derived lineage) after capture. [getsharex.com](https://getsharex.com/)
- **Styling:** per-tool border/fill colors, thickness, corner radius, border styles (solid/dash/dot/dash-dot), text alignment, bold/italic; customizable toolbar with remappable tool hotkeys. [changelog](https://getsharex.com/changelog.html)
- **Keyboard:** single-letter tool keys — M select, R rect, E ellipse, F freehand, L line, A arrow, O text-outline, T text-bg, S speech balloon, I step, B blur, P pixelate; Enter commits, Esc cancels. [keybinds](https://getsharex.com/docs/keybinds.html)
- **Smart features:** none beyond smart eraser (color-blend painting). Massive non-annotation **Image Effects** library (manipulations, adjustments, filters). [repo readme](https://github.com/ShareX/ShareX.ImageEditor)

### Greenshot (Windows, OSS)

- **Tools:** rectangle (R), ellipse (E), line (L), arrow (A), freehand (F), text (T), speech bubble, counter (adjustable start value), crop; **highlight** tool (H) with four modes: text highlighter color, highlight-area (blurs+darkens outside = spotlight), grayscale-outside, magnify; **obfuscate** tool (O): pixelize or blur. Effects like drop shadows and torn edges. [help](https://getgreenshot.org/help/), [1.2.9 release](https://getgreenshot.org/2016/12/19/our-present-for-you-greenshot-129/)
- **Vector vs raster:** elements are objects — select (Esc), move/resize with mouse or arrow keys, restyle per element type after placement. Double-click re-edits text. [help](https://getgreenshot.org/help/)
- **Re-editable file:** Greenshot can save its own `.greenshot` format preserving editable elements — *unverified against current docs*.
- **Where markup happens:** editor window opens on every capture by default (disable-able). [help](https://getgreenshot.org/help/)

### Flameshot (cross-platform, OSS)

- **Tools:** pencil, line, arrow, selection, rectangle, circle, marker (highlighter), text, pixelate, counter (incrementing number), solid color box, pin. [flameshot.org](https://flameshot.org/)
- **Vector vs raster:** raster-oriented but since v0.10.0 drawn objects can be clicked afterwards to move, resize (scroll), and recolor (right-click) within the session; directional (edge) resizing of placed objects is still missing (issue #1852 open since 2021). Saved output is flat; pinned images can't re-enter edit mode (issue #3772 closed as duplicate of open requests). [issue #1852](https://github.com/flameshot-org/flameshot/issues/1852), [issue #16 comment](https://github.com/lupoDharkael/flameshot/issues/16), [issue #3772](https://github.com/flameshot-org/flameshot/issues/3772)
- **Where markup happens:** inline on the capture overlay — the defining trait; there is no editor window.
- **Styling:** color wheel on right-click before/during annotation; mouse wheel sets tool thickness; Ctrl constrains line/arrow/marker to 45° and keeps rect/circle aspect; customizable colors/shortcuts. [key-bindings](https://flameshot.org/docs/guide/key-bindings/), [README](https://github.com/flameshot-org/flameshot/blob/master/README.md)
- **Keyboard:** single letters — P pencil, D line, A arrow, S selection, R rectangle, C circle, M marker, T text, B pixelate, G color picker; Ctrl+Z/Ctrl+Shift+Z undo/redo. [key-bindings](https://flameshot.org/docs/guide/key-bindings/)
- **Known UX complaints (first-party tracker):** can't resize placed objects by edge (#1852); can't re-edit pinned images (#3772/#3653); intermittent "cannot move annotations" reports (#4712, unconfirmed).

### Snipaste (Windows/macOS/Linux, freemium)

- **Tools:** rectangle, ellipse, linestrip/arrow (Tab toggles rect↔ellipse, line↔arrow), pencil, marker pen, text, mosaic (pixelate), gaussian blur, eraser, undo/redo; PRO adds magnify annotation, ellipse shape for highlight/mosaic/blur/eraser, more arrow styles, grouped number marking, OCR. [snipaste.com](https://www.snipaste.com/), [changelog](https://github.com/Snipaste/feedback/wiki/Changelog)
- **Vector vs raster:** annotations are re-editable objects — auto-select on creation (configurable), select to restyle/scale (Shift+wheel), `Disable reedition for Eraser` option implies objects persist; eraser rotatable. Editability ends when the snip is committed; no project file. [changelog](https://github.com/Snipaste/feedback/wiki/Changelog), [advanced configs](https://github.com/Snipaste/feedback/wiki/Advanced-Configs)
- **Where markup happens:** inline on the snipping overlay (F1), including on pinned image windows. Snip-to-pin (F3) is the signature flow.
- **Styling:** preset color/thickness per tool; corner radius for snips.
- **Keyboard:** T text, B pencil (v2.6+); WASD moves cursor by pixel; Space toggles paint bar; Ctrl+Z undo, Ctrl+Shift+Z **removes all edits irreversibly** (not a redo). [key-bindings wiki](https://github.com/Snipaste/feedback/wiki/Key-Bindings)
- **Smart features:** window/UI-element detection during snip (Tab toggles window vs element detection). [key-bindings wiki](https://github.com/Snipaste/feedback/wiki/Key-Bindings)

### Skitch (macOS/iOS, discontinued Evernote app)

- **Tools:** seven-tool toolbar: tapered arrow, text, shapes (rectangle/ellipse/line), highlighter, pen, pixelate, crop, plus feedback stamps (✓ ✗ ? ♥); deliberate minimalism — eight-color palette. [PCWorld review](https://www.pcworld.com/article/457096/review-skitch-lets-you-visually-highlight-images-to-help-your-point.html), [App Store](https://apps.apple.com/us/app/skitch-snap-mark-up-send/id490505997), [TechCrunch on Skitch 2.0](https://techcrunch.com/2012/09/19/evernote-pares-down-soups-up-image-annotation-app-skitch-extends-it-to-iphone-ipod/)
- **"Drag Me" tab** hanging off the window bottom for drag-out export — a UX detail wadjet's overlay already echoes.
- Skitch's legacy is worth noting because it defined the category's vocabulary (tapered arrow, pixelate, minimal palette). The app is unmaintained; modern clones (Sitch, iSkitch) re-implement its toolset. [Sitch](https://phalladar.github.io/Sitch/), [iSkitch](https://iskitch.com/)
- Editable-object behavior after placement: *unverified* from primary sources.

### Xnapper (macOS, paid)

- **Tools:** text, arrows, rectangle/oval shapes, redact tool (Key 3), blur; headline feature is **automatic beautification** — content detection, balanced padding, rounded corners, drop shadow, gradient/image backgrounds, social-media ratios, mockup frames (web version). [annotate-screenshot](https://xnapper.com/blog/annotate-screenshot), [changelog](https://xnapper.com/changelog), [xnapper.com](https://xnapper.com/)
- **Smart features:** **automatic redact** of emails, credit cards, IPs, API keys in one click; built-in Vision OCR for selecting/copying text. [xnapper.com](https://xnapper.com/)
- **Vector vs raster:** annotations remain editable/resizable (a v1.18 fix specifically restored pixelated redactions being "editable and resizable"); no project file. [changelog](https://xnapper.com/changelog)
- **Where markup happens:** editor window after capture; markup is a small add-on to the beautify pipeline, not the core product.
- **Keyboard:** numeric tool keys (3 = redact, 4 = shape). [changelog v1.16](https://xnapper.com/archives/Xnapper-1.17.1.html)

## Takeaways for wadjet

1. The expected minimum tool set: arrow, rect, ellipse, line, pen, highlighter, text, blur/pixelate, counter, crop — plus spotlight if we want parity with CleanShot/Snagit/Shottr/Greenshot.
2. Editable annotation objects are the norm (9 of 10 tools); a `.wadjet`-style project file would match only Snagit and CleanShot, so session-only editability is acceptable but a project format is a differentiator we could skip.
3. Auto-redaction (Snagit Smart Redact, Xnapper) is the highest-leverage smart feature — both market it as a headline feature.
4. Inline-on-overlay annotation (Flameshot, Snipaste, ShareX region) vs post-capture editor is a real fork in the road; wadjet's Freeze Frame overlay already sits at the capture moment, putting it closest to the Flameshot/Snipaste model.
5. Video annotation is nearly untapped: only Snagit Screen Draw (live, fading marks) exists; even CleanShot only does post-hoc zooms.
