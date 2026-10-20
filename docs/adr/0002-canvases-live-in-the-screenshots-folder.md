# Canvases live in the screenshots folder, beside their flattened images

History's Canvases used to be `<UUID>.wadjet` packages inside the sandbox container, out of Finder's sight, while Save file wrote the flattened image loose into `~/Pictures/Wadjet`. We moved both into the screenshots folder (default `~/Pictures/Wadjet`, or the custom folder the user picked): each Screenshot's Canvas goes to `original/` and its flattened image to `flattened/`, under one base name such as `Wadjet 2026-10-20 at 12.30.00`, so the two pair up in Finder and the editable original is never hidden. Recordings save to `~/Movies/Wadjet` (`folders.recordings`).

Because a Canvas is no longer named by its History id, the id now lives in the package's `canvas.json` store metadata, and the Canvas store finds Canvases by reading it. Links between Canvases (Pin, pasted Canvases) are absolute paths, so the Editor still refuses to rename or move History's packages.

## Consequences

- History retention keeps its stages but only touches store Canvases in the current `original/`. It still deletes them at the deletion stage, now from a user-visible folder. Flattened images and Save file Canvases carry no store metadata and are never touched, even when saved into `original/`.
- Store metadata also records the package's file name. A Finder duplicate or a renamed copy keeps the metadata but not the name, so it never belongs to History, and retention never touches it. The Editor treats only History's own packages as History's, so a user's Canvas saved into `original/` saves like any other permanent file.
- At launch, container Canvases move into `original/` under their capture's date-based name (` 2` on collision), get their id and name written into `canvas.json`, and every link to them is rewritten. A failed move or relink keeps the container folder, which triggers a retry next launch. Flattened images and recordings already in the old root stay where they are.
- Changing the screenshots folder moves nothing. Canvases already in the old `original/` stay there, but History no longer finds or sweeps them.

## Considered options

- **Keep Canvases in the container and only move the flattened images.** Rejected: the editable original would stay invisible and couldn't be shared or backed up with the image.
- **Record each Canvas's path in History (SwiftData).** Rejected: it needs a schema change and splits a Canvas's identity between two stores. An id inside the package keeps the store self-contained.
