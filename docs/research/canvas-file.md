# The Canvas file and opening images in the sandbox

Research for [#92](https://github.com/mia-cx/wadjet/issues/92). A Canvas is the document behind the Editor and History: the whole uncropped screen (possibly several displays, possibly HDR), the crop + corner radius, and every Annotation as an editable layer. wadjet is sandboxed (`apps/macos/Resources/Wadjet.entitlements`) with `user-selected.read-write` and `bookmarks.app-scope` already granted.

## Short answer

- **Package.** A `.wadjet` Canvas should be a *package* (directory-as-document, `NSFileWrapper` directory) — one image file per display plus a small `annotations.json` + `canvas.json` (crop, radius, per-display scale/HDR flags). Single-flat-file formats would force re-encoding all image data through a container every save; a package keeps each display's HEIC/PNG as a plain file that Quick Look and ImageIO can read directly. [File packages](https://developer.apple.com/documentation/foundation/filewrapper), [document types in AppKit](https://developer.apple.com/documentation/appkit/documents-data-and-pasteboard-management)
- **Type + Quick Look + Open With:** export a `cx.mia.wadjet.canvas` UTType conforming to `public.composite-content` (packages must not conform to `public.data`-only types or Finder shows them as folders; `com.apple.package` conformance makes it document-like), declare a `CFBundleDocumentTypes` entry, and ship a Quick Look **Preview** extension (`QLPreviewProvider` or view-controller `QLPreviewingController`) plus a **Thumbnailing** extension (`QLThumbnailProvider`). Both are app extensions (`.appex`), fully sandbox-compatible. [UTExportedTypeDeclarations](https://developer.apple.com/documentation/bundleresources/information-property-list/utexportedtypedeclarations), [Quick Look preview extensions](https://developer.apple.com/documentation/quicklookui), [Thumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing)
- **Opening arbitrary images:** covered by existing entitlements. `NSOpenPanel`, Finder Open With (declared document types for `public.image`), and drag-and-drop all hand the app security-scoped URLs that work under `user-selected.read-write`; persist access with app-scope security-scoped bookmarks for History re-opens. Saving edits *back* to the original file is allowed by the same scope while it lasts; a bookmark makes it durable. [App Sandbox file access](https://developer.apple.com/documentation/security/app-sandbox/protected-resources-and-user-specific-permissions), [Security-scoped bookmarks](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))
- **NSDocument vs DocumentGroup:** `DocumentGroup`. It's a Scene alongside the existing `MenuBarExtra`/window scenes, drives the open/save panels and recent-documents menu for free, and `ReferenceFileDocument` maps onto a class-based Canvas model with `NSUndoManager`. `NSDocument` buys nothing here — its extras (file presenters, versioned browsing, iCloud) aren't needed, and wiring it into an `LSUIElement`-style menu-bar app costs more. Caveat: `DocumentGroup` creates a window per open document — fine, that *is* the Editor. [DocumentGroup](https://developer.apple.com/documentation/SwiftUI/DocumentGroup), [ReferenceFileDocument](https://developer.apple.com/documentation/swiftui/referencefiledocument)

## Package layout

```
Capture.wadjet/
  display-1.heic        # full uncropped screen, HDR HEIC w/ gain map when captured that way
  display-2.heic
  canvas.json           # per-display sizes/scales, crop rect + corner radius, display refs
  annotations.json      # ordered annotation objects: kind, geometry, style
  thumbnail.png         # flattened preview for Fast Preview fallback / web contexts
```

Why this shape:

- **One image per display** keeps the format honest about what a Screenshot is (the Freeze Frame is per-display already — `Freeze.displays` / `FrozenDisplay` in `apps/macos/Sources/Wadjet/main.swift:149-185`) and avoids stitching multiple displays into a synthetic mega-image with unusable geometry.
- **HEIC with gain map** matches the DIRECTION.md line "HDR Screenshots save as HEIC with a gain map" — the stored display image is the *uncropped* original; crop is metadata, so "a too-tight crop can be redone" costs nothing. [#89 settled decision]
- **Annotations as JSON** keeps them diffable and format-evolvable; annotation payloads are paths/transforms/strings — trivially Codable.
- A flattened `thumbnail.png` inside the package doubles as the Quick Look reply and the share-sheet preview without decoding the model.

Size: a 5 K HDR display is one ~1–3 MB HEIC; a 3-display Canvas stays single-digit MB. Compare Snagit's `.snagx` (a package with per-capture assets — [Snagit docs](https://www.techsmith.com/learn/tutorials/snagit/file-save-tips/)) and CleanShot's `.cleanshot` project ([CleanShot](https://cleanshot.com/features)) — both are multi-asset documents, not flat files.

Alternative considered: a single flat file (zip or a custom binary with images embedded). Rejected — the OS can't peek inside without our code, the whole file rewrites on every save, and no thumbnail fallback exists. Packages get Finder "Show Package Contents" for free debugging too.

## Declaring the type

- `UTExportedTypeDeclarations`: identifier e.g. `cx.mia.wadjet.canvas`, conformances `com.apple.package, public.composite-content` (conforming a *package* to `public.data` makes Finder treat it as a file already handled by the package type; the doc-type side is `public.composite-content`). Tag it with the `.wadjet` extension. [UTType](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype), [declaring UTIs](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app)
- `CFBundleDocumentTypes`: `LSItemContentTypes = [cx.mia.wadjet.canvas]`, role Editor, plus `public.image` (PNG/JPEG/HEIC) so Open With lists wadjet for ordinary images. [CFBundleDocumentTypes](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes)
- Quick Look Thumbnail extension: `QLThumbnailProvider` returning the package's `thumbnail.png`. Quick Look Preview extension: `QLPreviewingController` rendering the flattened Canvas (compose displays + crop + annotations — read-only). Both are `.appex` targets embedded in the sandboxed host app; the extension declares `QLSupportedContentTypes = [cx.mia.wadjet.canvas]`. [Quick Look UI overview](https://developer.apple.com/documentation/quicklookui), [QLThumbnailProvider](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailprovider)

## Opening and saving arbitrary images in the sandbox

- **Open With / drag-and-drop / NSOpenPanel** all deliver scoped URLs — the `com.apple.security.files.user-selected.read-write` entitlement already in `Wadjet.entitlements` covers reading *and writing* them. [App Sandbox docs](https://developer.apple.com/documentation/security/app-sandbox)
- **History re-opening** a Canvas days later needs a persisted grant: create an app-scope security-scoped bookmark (`bookmarkData(options:.withSecurityScope)`) at first save — entitlement already present (`bookmarks.app-scope`). [Security-scoped bookmarks](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))
- **Saving edits back to a non-`.wadjet` image** (the "Preview-style" Editor flow): while the scope lasts, writing the file in place is permitted. Once the scope lapses the app can't write without asking — that's expected; re-open via the panel or use a bookmark. Save-as to a new path always works via the save panel.
- `~/Pictures/Wadjet` and `~/Movies/Wadjet` are already in-scope via the pictures/movies read-write entitlements for default Workflow saves. [entitlements file](apps/macos/Resources/Wadjet.entitlements)

## NSDocument vs SwiftUI DocumentGroup

- `DocumentGroup(newDocument:)` + `ReferenceFileDocument` gives the Editor open/create/save, recent-documents menu, multiple windows, and undo tracking via `EnvironmentValues.undoManager`. It sits beside `MenuBarExtra` — a menu-bar app can host document scenes. [DocumentGroup](https://developer.apple.com/documentation/SwiftUI/DocumentGroup), [menu bar scenes](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)
- Known frictions to design around (documented, not blockers): the File/Open/Save menus are system-provided and only customisable through `commands`; the file URL lives on the `configuration`, not the document — plan the model around that. [Eclectic Light on SwiftUI documents](https://eclecticlight.co/2024/05/16/swiftui-on-macos-documents/)
- `NSDocument` would give document-change callbacks (`NSFilePresenter`), iCloud/versioning machinery, and a heavier AppKit lifecycle — none of which the Editor needs. It also wants an `NSDocumentController` and Xcode-style document plumbing that fights the menu-bar shape. Skip it.
- The Save file Step's "format: image | Canvas" option (#89) writes a `.wadjet` package directly with `FileWrapper` — that path doesn't need document machinery at all; it's just file output in the Workflow runner. [FileWrapper](https://developer.apple.com/documentation/foundation/filewrapper)

## What to try on a real Mac

- Confirm a `DocumentGroup` opens a window from a menu-bar-first app without producing an unwanted extra window or activation quirk (LSUIElement-style apps have a history of "window opens behind" oddities — sanity-check).
- Confirm Finder shows the `.wadjet` package as a document (not a folder) with the declared UTType + package conformance, and that Open With offers wadjet for `public.image`.
- Confirm the Quick Look preview extension renders for a package UTType inside the sandbox (the extension is itself sandboxed; file access comes through `QLFilePreviewRequest`).
