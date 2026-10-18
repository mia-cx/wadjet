# Vector Annotations in Swift

Research for [#91](https://github.com/mia-cx/wadjet/issues/91). The settled tool list (#89): Shapes, Line (heads/tails, dash, weight), Pen, Brush (editable bezier on release), Highlighter, Censor, Text, Magnify, Step counter — all objects that can be selected, moved, restyled, and edited point-by-point.

## Short answer

- **Brush → bezier:** fit a piecewise cubic bezier to the raw points on stroke release with Schneider's "Algorithm for Automatically Fitting Digitized Curves" (Graphics Gems 1990) — the same algorithm paper.js uses in `PathFitter`. It's ~300 lines of well-documented C; port it into WadjetKit where it's unit-testable. Keep the raw points alongside the fitted path so "faithful" is verifiable and refit-tolerant. [FitCurves.c](https://github.com/erich666/GraphicsGems/blob/master/gems/FitCurves.c), [paper.js PathFitter](https://github.com/paperjs/paper.js/blob/develop/src/path/PathFitter.js), [paper](https://lhf.impa.br/cursos/tmg/Schneider-1990.pdf)
- **Rendering:** keep a `CGPath`/`NSBezierPath` per Annotation and render through Core Animation `CAShapeLayer`s (or one `CAShapeLayer` per annotation inside the overlay panel) — `lineCap`, `lineJoin`, `lineDashPattern`, `strokeColor`, `fillColor` are all built in. SwiftUI `Canvas` can draw it too but gives you a single flattened drawing pass per view; CAShapeLayer matches "editable objects" better. Heads/tails are our own path math: compute the end tangent from the last bezier segment and append a small arrowhead/dot subpath. [CAShapeLayer](https://developer.apple.com/documentation/quartzcore/cashapelayer), [CGPath stroking](https://developer.apple.com/documentation/coregraphics/cgpath)
- **Hit testing:** `CGPath.contains(_:using:)` for fills; for strokes, `path.copy(strokingWithWidth:lineCap:lineJoin:miterLimit:)` produces the outline path — hit-test the pointer against that. Selection handles and point editing are plain AppKit: draw handle sublayers, drag the underlying model points, rebuild the `CGPath`. [copy(strokingWithWidth:)](https://developer.apple.com/documentation/coregraphics/cgpath/copy(strokingwithwidth:linecap:linejoin:miterlimit:transform:))
- **Base:** own code. PencilKit on native macOS is effectively unusable for this (below); no open-source Swift library fits "editable bezier annotation objects with heads/tails/dashes" closely enough to be a base rather than a reference. Pressure: `NSEvent.pressure` covers Force Touch trackpads (0…1) and tablet pens carry pressure through `NSEvent` tablet subtypes — optional, additive width mapping on Brush only.

## Turning a Brush stroke into an editable bezier path

The established algorithm is Philip J. Schneider's adaptive cubic fit: chord-length parameterize the digitized points, least-squares-fit a cubic, split at the point of maximum error when it exceeds tolerance, reparameterize with Newton–Raphson. Fits G1-continuous curves, which is what a drawn stroke wants. [Schneider 1990](https://lhf.impa.br/cursos/tmg/Schneider-1990.pdf), [reference C source](https://github.com/erich666/GraphicsGems/blob/master/gems/FitCurves.c)

Notes for wadjet's use:

- Fit *on release*, not live — the settled behavior. Live rendering can be a `NSBezierPath` polyline (or a simple Catmull-Rom through recent points) while fitting runs on a background queue; the overlay swaps in the fitted path. Sub-millisecond for a few hundred points — unverified, but Schneider fits are cheap; measure.
- The `error` tolerance is squared distance in the same units as the input — i.e. points², not pixels — expose it as a fixed internal constant, not a user knob (YAGNI).
- Keep the raw `[CGPoint]` in the Annotation model next to the fitted segments. It costs ~16 bytes/point, enables refit at a different tolerance, and gives Edit mode the option to show original vs fitted.
- Highlighter = same path with low-alpha stroke and round cap; no separate model needed.
- An existing MIT Swift port to compare against: *unverified — several JS/TS ports exist ([odiak/fit-curve](https://github.com/odiak/fit-curve)), no canonical Swift port found; port from FitCurves.c.*

## Rendering Line / Pen / Brush with heads, tails, dashes

`CAShapeLayer` gives stroke color/width, `lineDashPattern`, `lineCap` (`.butt/.round/.square`), `lineJoin`, and `lineDashPhase` — everything Line and Pen need. Render each Annotation as its own shape layer so selection highlight is a layer swap, not a redraw. [CAShapeLayer](https://developer.apple.com/documentation/quartzcore/cashapelayer)

Heads and tails (arrowheads, dots) have no built-in API. Standard approach: derive the tangent at path end/start from the final/first bezier segment's control points (de Casteljau evaluation at t=1/t=0), then build a small filled subpath (triangle arrowhead scaled by stroke weight, or a circle) oriented along that tangent. One helper does both ends. *No Apple API; plain geometry.*

`NSBezierPath` is the AppKit-flavored equivalent (`lineDashPattern` via `setLineDash`, same hit-test story via `CGPath` conversion); CAShapeLayer is the better fit since the overlay is already layer-hostile territory and animations (selection) are free. `CGPath` stays the source of truth either way — `NSBezierPath` and `CAShapeLayer.path` both bridge it.

Text/Step counter annotations render as `CATextLayer` or `NSLayoutManager`-backed layers; Censor and Magnify are effect rectangles over the sampled screen (see live-screen-markup.md), not paths.

## Hit testing, handles, point editing

- Hit test order: walk annotations top-most first; test `copy(strokingWithWidth:)` for strokes, `contains` for fills/text bounds. Add a few points of slack to stroke width for thin lines — standard practice, no API.
- Multi-select/shift-click: model-level, trivial once each annotation is an object.
- Selection handles: draw a bounding box + point handles as temporary sublayers; drag updates model points; stroke re-renders on change. For Pen/Brush, expose bezier anchor/control-point handles (draggable dots) only in an explicit "edit points" mode — the map's Brush promise ("becomes an editable bezier path") implies anchor editing is in scope.
- Undo/redo: annotation objects are value types → snapshot diffs, cheap. Open question in #89 (undo across a session, cleared-annotation resurrection) resolves naturally with a model-level stack.

## PencilKit vs libraries vs own code

- **PencilKit:** `PKCanvasView`/`PKDrawing` are documented for iOS and Mac Catalyst; the Xamarin/Apple SDK bindings mark key members `NoMac`, and several PencilKit symbols only gained native-Mac availability in macOS 13–14 (e.g. `PKEraserType.fixedWidthBitmap` Mac 13.3, `PKContentVersion` Mac 14+). `PKCanvasView` itself shows no clean native-`NSView` story and the tool picker is Catalyst-only. Even where it compiles, `PKDrawing` strokes aren't exposed as editable bezier paths with per-point editing, and we need custom tools (Step counter, Censor, Magnify) it can't express. **Not a viable base.** [PKCanvasView](https://developer.apple.com/documentation/pencilkit/pkcanvasview), [Xamarin PencilKit bindings showing NoMac/Mac availability](https://github.com/xamarin/xamarin-macios/blob/main/src/pencilkit.cs)
- **Open-source libraries:** nothing on macOS provides "screenshot-style editable vector annotations" — the space is iOS drawing pads (PencilKit wrappers) or full SVG editors. Overkill or wrong platform. Own code, ~a few hundred lines for paths + heads/tails + hit-testing, is the smallest dependency.
- **Pen pressure:** wadjet draws on a screen with a mouse/trackpad — `NSEvent.pressure` reports Force Touch trackpad pressure (0–1) and `NSEvent` tablet subtypes (`.tabletPoint`, `.tabletProximity`) carry real pen pressure/proximity for Wacom-class devices. Map pressure→stroke width on Brush only, behind an option; everything else ignores it. [NSEvent.pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure), [NSEvent.EventSubtype](https://developer.apple.com/documentation/appkit/nsevent/eventsubtype)

## What to try on a real Mac

- `hitTest` on the annotation overlay (see live-screen-markup.md) doubles as the vector hit-test check — one prototype covers both.
- Force Touch pressure on the built-in trackpad while drawing: confirm `NSEvent.pressure` reports during a tracked mouse drag on the overlay (it should — it's delivered with the drag's event stream, but verify inside a `nonactivatingPanel`).
