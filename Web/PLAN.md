# Plan: Easel for the web (WebAssembly + offline PWA)

## Goal

Ship Easel as an installable Progressive Web App that runs **entirely on the device**: it opens, shows, edits and saves Photoshop, Pixelmator Pro and Easel images and pictures, with no network connection after the first visit. The engine is Paintbrush, the same Swift the Apple apps use, so documents draw the same everywhere.

Constraints, as for Tables, Libretto and Dazzle: **no Node packages**, and **Paintbrush is compiled as it is**: Apple frameworks are replaced by portable stand-ins of the same names rather than by changes to Paintbrush.

## Stages

1. **Open, show and export** (done). Photoshop, Pixelmator Pro and Easel documents and pictures open; layers and groups show with thumbnails; visibility, opacity and blend modes can be changed; PNG, JPEG, Photoshop, SVG and Easel export.
2. **Paint and edit** (started). The tools are along the bottom on phones and down the side elsewhere, grouped as the Apple apps group them; Brush, Eraser, Fill and Eyedropper work, with Undo and Redo. The engine paints with Paintbrush's `Painter`, the code `EditorState` commits strokes with; `EditorState` itself needs SwiftUI, so the engine keeps its own history. Tools share one interface (`app/tools.js`): begin, update, end and cancel, drawing through the canvas and changing the picture through the engine.
   - [x] Move (tap picks the layer seen there), Select (rectangle, ellipse, lasso, magic; replace, add, subtract, intersect; all, none, invert, clear), Crop, Gradient (five kinds, three presets), Shape (vector layers), Text, and the retouching tools: Censor, Tone, Heal, Clone, Liquify. Selections clip brushes, fills, gradients and retouching. Drafts and marching ants are an SVG over the canvas; a moved layer shifts on the GPU until the engine's picture comes.
   - [x] Transform (distort, warp, cylinder), Pen and Nodes (moving points and handles, corners and curves, adding and deleting points; fill, gradient and pattern fills, stroke and its style; live shape settings; text on a path; offset, outline, combine and the shape builder).
   - [ ] Nodes: fills from the document's own patterns, and gradient stops.
   - [ ] What the tools' options don't yet offer: gradient stops, crop aspect ratios, straighten and perspective, magnetic and object selection, feathering and other selection changes, text formatting, shape corner radius, sides and points.
   - [ ] Retouching, Liquify, gradients and shapes show only a mark or outline until the engine's picture comes.
   - [x] Layers inspector as in the Apple apps: add (empty, adjustment, from a file, pasted), duplicate, merge down, delete, copy, group, flatten; a row's menu (right-click or long press) to rename, lock, move, clip, rasterize and move between groups; mouse drag to reorder; fill opacity, lock and clipping; group settings; adjustment amounts and settings; masks (add, from the selection, paint on with brush, eraser and gradient, use, invert, hide or reveal the selection, apply, delete).
   - [x] The view turns with two fingers (past 10°, settling square within 8°) and with Safari's trackpad rotate; a toolbar button shows the angle and turns it back.
   - [ ] Levels, Curves, Colour Balance, Gradient Map, HSL and Replace Colour adjustments have no editors of their own yet; layer filters and effects, layer comps and smart object editing aren't in the inspector.
   - [ ] Brush tips, pressure from a pen, symmetry.
   - [x] The canvas is drawn on the GPU (`app/canvas.js`). The engine cuts the picture into parts (`CanvasParts.swift`): the layer being painted alone, runs of normal layers flattened, each layer in another mode alone, everything up to the last adjustment flattened. WebGL2 mixes them with the engine's own blend formulas, so the canvas matches exports to within a level; a stroke shows inside its layer as it's drawn, and only that layer is redrawn after.
   - [ ] The layer being painted can't stand alone under an adjustment layer or inside a group that doesn't pass through: strokes then show over the picture (and the eraser not at all) until painted. Adjustments on the GPU (as the Apple apps' `colorCube` shader) and groups as their own passes would lift this.
   - [ ] Strokes show without the layer's filters, effects or clipped layers applied until painted.
3. **Parity.** Filters and effects panels, text editing, vectors, autosave and Open Recent, saving packages back into their folders.

## What porting the engine took

| Problem | Fix |
| --- | --- |
| Paintbrush draws with Core Graphics | A software `CGContext`, `CGImage` and `CGPath` (`Portable/CoreGraphics`) |
| Core Image filters, adjustments and effects | A region-based software Core Image (`Portable/CoreImage`) |
| ImageIO | PNG in Swift over zlib; JPEG and GIF in Swift; other formats decoded by the browser |
| Text through AppKit and Core Text | A text system that asks the page's `OffscreenCanvas`, synchronously, from the worker |
| `import CoreImage.CIFilterBuiltins` (a submodule) | Guarded with `#if canImport`, the one kind of change made to Paintbrush's imports |
| `Int` is 32 bits on wasm32 | `Int(UInt32.max)` and `& 0xFFFF_FFFF` in `ZipArchive` and `PSDWriter` made width-independent |
| `.atomic` writes don't exist on WASI | Dropped for a fresh temporary file in `ImageFiles` |
| The compiler treats `DispatchQueue.concurrentPerform` as concurrent by name | A serial stand-in under another name, aliased |
| Pixelmator Pro's SQLite opens a temporary file | An in-memory file system in the WASI host |

## Next

### Fidelity

- [x] Exact boolean operations on paths (`CGPath.union`, `intersection`, `subtracting`, `normalized`, `componentsSeparated`), on outlines flattened to lines (`PathBoolean.swift`); results come back as straight segments where Core Graphics keeps curves.
- [ ] Colour management: Display P3 and sRGB pictures keep their numbers; Core Graphics would convert.
- [ ] Compare renders against the Apple apps' for a set of Photoshop and Pixelmator Pro documents, and tune the Core Image stand-ins (highlights and shadows, noise reduction, bokeh, photo effects are approximations).
- [ ] Open real Pixelmator Pro documents in the browser (SQLite over the in-memory file system is built but not yet tried on one).
- [ ] Audit Paintbrush's `Int(…)` conversions of 32-bit file fields for values over 2 GB on wasm32.

### Engine quality

- [ ] Run Paintbrush's tests (`EaselTests`) under WASI.
- [ ] **Speed.** WebAssembly SIMD (`-msimd128`) for compositing and filters; the release module renders the sample (1200×800, eight layers with effects) in about half a second.
- [ ] **Size.** The release module is 55 MB (about 20 MB gzipped), mostly ICU data Foundation links. As for Tables: `wasm-opt -Oz`, `FoundationEssentials`, or trimmed ICU data.

### Release

- [ ] Social sharing picture; maskable icons.
- [ ] Browser tests in Chromium, WebKit and Firefox.
