# Attachments live on the attaching Annotation, and geometry stays resolved

An attached point or Annotation records its attachment on itself: which point (start, end, a node, a Line's bend, or the whole Annotation), the target's id, and an anchor on the target. The target records nothing. Every Annotation's geometry is still stored in absolute screen points, already resolved. The layer stack re-solves attachments after every change, so renderers, flattening, hit testing and snapping never read attachments. Undo works unchanged, because it snapshots the stack after the re-solve.

## Considered Options

- **Separate binding records beside the Annotations (tldraw).** These need a second list in `annotations.json`, and every stack operation (erase, Knife, Clear, restack, paste) has to keep both lists in step. The bindings also need ids and their own undo story. An attachment has exactly one owner, the Annotation that follows, so it doesn't need to be a record of its own.
- **References on both sides (Excalidraw's `startBinding` on the arrow plus `boundElements` on the target).** The two sides can drift apart: a delete or an undo that touches one side and not the other leaves a stale reference. With one-sided references, a missing target is just a dangling id that the stack drops, so deleting a target frees its followers with no extra code.
- **Storing attached geometry relative to the target.** Every reader would need the resolver, including the Canvas flattener, Quick Look, and builds from before attaching. Those older builds would draw attached Lines in the wrong place, where they now ignore the unknown `attachments` key and draw them correctly.

## Anchors

An anchor is either a position in the target's untransformed bounds, normalised 0…1 (tldraw's `normalizedAnchor`), or a segment index plus parameter on a Line or path. A corner is just (0, 0) or (1, 1), and an edge midpoint is (0.5, 0). Both kinds of anchor survive resize, rotation and flips. Points on an ellipse, polygon or star stay on its outline, because those shapes scale with their rect. A segment anchor survives reshaping, and splitting a segment at t maps it exactly. A corner or vertex index was the alternative, but it can't name a point along an edge, and it means something different on each kind.

## Consequences

- An attachment that would close a cycle is refused. A file with a cycle (only a hand edit can make one) loads with the closing attachment dropped.
- Moving several Annotations together goes through `LayerStack.translate`. It moves each once and lets the re-solve place their followers, so a multi-selection holding an arrow and its target never moves the arrow's ends twice.
- Inserting or removing path nodes, or refitting a Brush stroke, shifts `node(i)` and `segment(i, t)` indices. Those edits go through `LayerStack.replaceReshaping`, which moves each affected attachment to the nearest spot on the new geometry. Ends are named `start` and `end`, not numbered, so they survive this.
- The re-solve skips an attachment whose target is missing instead of dropping it, because a reorder can briefly remove the target. `remove(id:)` frees followers on purpose, and saving and loading leave out dangling attachments.
