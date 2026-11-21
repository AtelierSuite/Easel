# Plan: Easel for the web (WebAssembly + offline PWA)

## Goal

Ship Easel as an installable Progressive Web App that runs **entirely on the device**: it opens, shows, edits and saves Photoshop, Pixelmator Pro and Easel images and pictures, with no network connection after the first visit. The engine is Paintbrush, the same Swift the Apple apps use, so documents draw the same everywhere.

Constraints, as for Tables, Libretto and Dazzle: **no Node packages**, and **Paintbrush is compiled as it is**: Apple frameworks are replaced by portable stand-ins of the same names rather than by changes to Paintbrush.

## Stages

1. **Open, show and export** (done). Photoshop, Pixelmator Pro and Easel documents and pictures open; layers and groups show with thumbnails; visibility, opacity and blend modes can be changed; PNG, JPEG, Photoshop, SVG and Easel export.
2. **Paint and edit.** Share the editor's state (`Shared/Editor/EditorState*`, which uses no UIKit or AppKit) as Dazzle shares `Common/Editing`. Draw the canvas on the GPU in the page (a WebGL2 port of `Shared/Editor/Shaders.metal`) so live strokes don't wait for the engine, which commits them. Undo, tools, selection, transform.
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

- [ ] Exact boolean operations on paths (`CGPath.union`, `intersection`, `subtracting`): they're approximated, which affects vector boolean and shape-builder commands, not drawing.
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
