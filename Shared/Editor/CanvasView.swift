import SwiftUI

/// The picture on its workspace: a checkerboard where it is transparent,
/// every layer mixed the way it will be exported, and the outlines of
/// whatever the tool in hand is doing.
///
/// Each layer is its own image view, scaled and turned by the GPU, so moving
/// or zooming never redraws pixels and a stroke redraws only its own layer.
struct CanvasView: View {
    let composition: Composition
    @Bindable var state: EditorState
    var history: CompositionHistory
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let viewport = state.viewport
        ZStack(alignment: .topLeading) {
            Color(.secondarySystemBackground)

            picture(viewport.level)
                .rotationEffect(.radians(viewport.rotation))
                .frame(width: state.viewportSize.width, height: state.viewportSize.height)
                .allowsHitTesting(false)

            CanvasInteraction(
                began: { sample in
                    state.toolBegan(
                        at: state.viewport.canvasPoint(sample.location), pressure: sample.pressure,
                        azimuth: sample.azimuth, altitude: sample.altitude, time: sample.time
                    )
                },
                moved: { samples in
                    let viewport = state.viewport
                    state.toolMoved(to: samples.map {
                        StrokePoint(
                            location: viewport.canvasPoint($0.location), pressure: $0.pressure,
                            azimuth: $0.azimuth, altitude: $0.altitude, time: $0.time
                        )
                    })
                },
                ended: { isTap, point in
                    state.toolEnded(isTap: isTap, at: state.viewport.canvasPoint(point))
                },
                cancelled: { state.toolCancelled() },
                hovered: { point in state.hoverPoint = point.map { state.viewport.canvasPoint($0) } },
                zoomed: { factor, anchor in state.zoom(by: factor, around: anchor) },
                panned: { state.pan(by: $0) },
                rotates: state.rotatesWithGestures,
                turned: { angle, anchor in state.rotate(by: angle, around: anchor) },
                turnEnded: { withAnimation(.snappy) { state.settleRotation() } },
                undo: { history.undo() },
                redo: { history.redo() },
                rulerContains: { state.rulerContains($0) },
                rulerMoved: { state.moveRuler(by: $0) },
                rulerTurnBegan: { state.beginTurningRuler() },
                rulerTurned: { state.turnRuler(by: $0, around: $1) },
                rulerResized: { state.resizeRuler(by: $0) }
            )
            .accessibilityIdentifier("canvas")

            // The scales run along the view's edges, which only line up
            // with the canvas while it is upright.
            if state.showsRulers, viewport.rotation == 0 {
                Rulers(state: state, viewport: viewport)
            }
        }
        .coordinateSpace(.named(Rulers.coordinateSpace))
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { state.viewportSize = $0 }
    }

    /// Everything drawn on the canvas, laid out level on `viewport`.
    private func picture(_ viewport: CanvasViewport) -> some View {
        ZStack(alignment: .topLeading) {
            // Only the part on screen is drawn: zoomed in, the whole canvas
            // would be many screens of squares.
            let visible = viewport.canvasFrame.intersection(CGRect(origin: .zero, size: viewport.viewportSize))
            if !visible.isNull {
                Checkerboard(phase: CGSize(
                    width: visible.minX - viewport.canvasFrame.minX, height: visible.minY - viewport.canvasFrame.minY
                ))
                .frame(width: visible.width, height: visible.height)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .offset(x: visible.minX, y: visible.minY)
            }

            layerStack(viewport)

            CanvasOverlay(composition: composition, state: state, viewport: viewport)

            if state.showsRuler, let ruler = state.ruler {
                RulerView(ruler: ruler, viewport: viewport, dockedSide: state.dockedEdge?.side)
            }
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
    }

    private func layerStack(_ viewport: CanvasViewport) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(composition.displayLayers.clippingUnits) { unit in
                let clipped = unit.clipped.filter(\.isVisible)
                if unit.base.isVisible, clipped.isEmpty {
                    layerView(unit.base, viewport)
                } else if unit.base.isVisible {
                    clippingGroup(unit.base, clipped: clipped, viewport)
                }
            }
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
        // Blend modes mix with the layers beneath, not with the checkerboard.
        .compositingGroup()
        .mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: viewport.canvasFrame.width, height: viewport.canvasFrame.height)
                .offset(x: viewport.canvasFrame.minX, y: viewport.canvasFrame.minY)
        }
        .allowsHitTesting(false)
    }

    /// Which part of a layer with effects to show; see `StyledLayer`.
    private enum LayerPart {
        case whole, behind, content, front
    }

    /// One layer as it shows, with whatever is being done to it.
    @ViewBuilder
    private func layerView(_ layer: Layer, _ viewport: CanvasViewport, part: LayerPart = .whole) -> some View {
        if let bent = state.transformPreview, bent.layerID == layer.id {
            // A layer being bent shows as it will be: lined up with the
            // canvas, its mask already in it.
            if part == .whole || part == .content {
                LayerView(
                    layer: Self.canvasAligned(layer, image: bent.image, canvasSize: composition.size),
                    displayed: bent.image, strokes: [], maskStrokes: [], retouch: nil,
                    canvasSize: composition.size, viewport: viewport, displayScale: displayScale
                )
            }
        } else if let preview = state.layerPreview, preview.layerID == layer.id {
            if part == .whole || part == .content {
                liveLayerView(layer, displayed: preview.image, viewport)
            }
        } else if let styled = state.styledDisplay(for: layer) {
            switch part {
            case .whole:
                liveLayerView(layer, displayed: styled.composite, padding: styled.padding, viewport)
            case .content:
                liveLayerView(layer, displayed: styled.content, padding: styled.padding, viewport)
            case .behind, .front:
                if let image = part == .behind ? styled.behind : styled.front {
                    LayerView(
                        layer: layer, displayed: image, padding: styled.padding, masksItself: false,
                        strokes: [], maskStrokes: [], retouch: nil,
                        canvasSize: composition.size, viewport: viewport, displayScale: displayScale
                    )
                }
            }
        } else if part == .whole || part == .content {
            liveLayerView(layer, displayed: state.displayImage(for: layer), viewport)
        }
    }

    /// A layer with the strokes and retouching being done to it drawn over.
    /// An image with effects worked out has its mask in it already.
    private func liveLayerView(
        _ layer: Layer, displayed: CGImage, padding: Double? = nil, _ viewport: CanvasViewport
    ) -> some View {
        LayerView(
            layer: layer,
            displayed: displayed,
            padding: padding ?? 0,
            masksItself: padding == nil,
            strokes: strokes(on: layer.id, mask: false),
            maskStrokes: strokes(on: layer.id, mask: true),
            retouch: retouch(on: layer.id),
            canvasSize: composition.size,
            viewport: viewport,
            displayScale: displayScale
        )
    }

    /// A base and the layers clipped to it, as `CompositionRenderer` draws
    /// them: the base made opaque, the clipped layers mixed over it, all cut
    /// back to the base's shape between the base's effects behind and in
    /// front of it, and put down as the base would be.
    private func clippingGroup(_ base: Layer, clipped: [Layer], _ viewport: CanvasViewport) -> some View {
        let plain = base.with(opacity: 1, blendMode: .normal)
        return ZStack(alignment: .topLeading) {
            layerView(plain, viewport, part: .behind)
            ZStack(alignment: .topLeading) {
                layerView(plain, viewport, part: .content)
                    .colorEffect(ShaderLibrary.opaqueColor())
                ForEach(clipped) { layer in
                    layerView(layer, viewport)
                }
            }
            .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
            .compositingGroup()
            .mask(alignment: .topLeading) { layerView(plain, viewport, part: .content) }
            layerView(plain, viewport, part: .front)
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
        .compositingGroup()
        .opacity(base.opacity)
        .blendMode(base.blendMode.swiftUI)
    }

    /// `layer` showing `image`, a shrunk copy of the whole canvas, instead
    /// of its own pixels.
    private static func canvasAligned(_ layer: Layer, image: CGImage, canvasSize: CGSize) -> Layer {
        var shown = layer
        shown.image = LayerImage(image)
        shown.mask = nil
        shown.transform = LayerTransform(
            position: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
            scaleX: canvasSize.width / Double(image.width), scaleY: canvasSize.height / Double(image.height)
        )
        return shown
    }

    /// What the retouching brushes are doing to a layer right now.
    private func retouch(on layerID: Layer.ID) -> RetouchOverlay? {
        let strokes = strokes(on: layerID, mask: false).filter { !$0.kind.isPaint }
        let smudge = state.smudge?.layerID == layerID ? state.smudge?.patches ?? [] : []
        guard !strokes.isEmpty || !smudge.isEmpty else { return nil }
        let effect = state.retouchEffect.flatMap { $0.layerID == layerID ? $0 : nil }
        return RetouchOverlay(
            effectStrokes: strokes.filter { $0.kind == effect?.kind },
            effectImage: effect?.image,
            healStrokes: strokes.filter { $0.kind == .heal },
            smudgePatches: smudge
        )
    }

    private func strokes(on layerID: Layer.ID, mask: Bool) -> [Stroke] {
        var strokes = state.pendingStrokes.filter { $0.layerID == layerID && $0.isMask == mask }.map(\.stroke)
        if let active = state.activeStroke, state.activeLayerID == layerID, state.editsMask == mask {
            strokes.append(contentsOf: state.mirrored(active))
        }
        return strokes
    }
}

/// Retouching shown over a layer before it is painted in.
struct RetouchOverlay {
    /// Blur or mosaic strokes, and the blurred or tiled layer they reveal.
    var effectStrokes: [Stroke]
    var effectImage: CGImage?
    /// Where the healing brush has been, shown until it heals.
    var healStrokes: [Stroke]
    /// The smudged pixels so far, canvas-aligned.
    var smudgePatches: [(rect: CGRect, image: CGImage)]
}

/// One layer, placed on screen, with any strokes not yet painted into it.
private struct LayerView: View {
    let layer: Layer
    /// The layer's pixels as they show, filters applied.
    let displayed: CGImage
    /// How far `displayed` reaches past the layer's edges, in its own pixels.
    var padding = 0.0
    /// Whether the layer's mask still has to be applied to `displayed`.
    var masksItself = true
    let strokes: [Stroke]
    /// Strokes on their way into the layer's mask.
    let maskStrokes: [Stroke]
    let retouch: RetouchOverlay?
    let canvasSize: CGSize
    let viewport: CanvasViewport
    let displayScale: Double

    var body: some View {
        let image = displayed
        let transform = layer.transform
        let scale = viewport.scale
        // Past twice the screen's resolution, pixels show as squares, which
        // is what someone zoomed that far in is looking for.
        let pixelScale = scale * abs(transform.scaleX) * displayScale
        let content = placed(
            Image(decorative: image, scale: 1).interpolation(pixelScale > 2 ? .none : .high),
            rect: layer.paddedRect(imageWidth: image.width, padding: padding)
        )

        let paintStrokes = strokes.filter(\.kind.isPaint)
        Group {
            if paintStrokes.isEmpty && retouch == nil {
                content
            } else {
                ZStack(alignment: .topLeading) {
                    content
                    if let retouch { RetouchPreview(retouch: retouch, canvasSize: canvasSize, viewport: viewport) }
                    StrokePreview(
                        strokes: paintStrokes.filter { $0.blendMode == .normal || $0.isEraser },
                        canvasSize: canvasSize, viewport: viewport
                    )
                    // Strokes that blend with the layer under them can only
                    // do so as views of their own.
                    let multiplied = paintStrokes.filter { $0.blendMode == .multiply }
                    if !multiplied.isEmpty {
                        StrokePreview(strokes: multiplied, canvasSize: canvasSize, viewport: viewport)
                            .blendMode(.multiply)
                    }
                    let lit = paintStrokes.filter { $0.blendMode == .plusLighter }
                    if !lit.isEmpty {
                        StrokePreview(strokes: lit, canvasSize: canvasSize, viewport: viewport)
                            .blendMode(.plusLighter)
                    }
                }
                // The strokes and the layer become one before the layer's
                // opacity and blend mode apply, and the eraser cuts only
                // this layer.
                .compositingGroup()
            }
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
        .mask(alignment: .topLeading) { maskView }
        .opacity(layer.opacity)
        .blendMode(layer.blendMode.swiftUI)
    }

    /// An image covering `rect` of the layer's own pixels — all of them
    /// unless told otherwise — placed where the layer is on screen.
    private func placed(_ image: Image, rect: CGRect? = nil) -> some View {
        let transform = layer.transform
        let size = (rect ?? CGRect(origin: .zero, size: layer.image.size)).size
        let scale = viewport.scale
        return image
            .resizable()
            .frame(width: size.width * abs(transform.scaleX) * scale, height: size.height * abs(transform.scaleY) * scale)
            .scaleEffect(x: transform.scaleX < 0 ? -1 : 1, y: transform.scaleY < 0 ? -1 : 1)
            .rotationEffect(.radians(transform.rotation))
            .position(viewport.screenPoint(transform.position))
    }

    /// What of the layer shows: its mask with any strokes on their way into
    /// it, or everything when it has no mask in use.
    @ViewBuilder
    private var maskView: some View {
        if masksItself, let mask = layer.activeMask {
            ZStack(alignment: .topLeading) {
                placed(Image(decorative: mask.image.cgImage, scale: 1))
                if !maskStrokes.isEmpty {
                    StrokePreview(strokes: maskStrokes, canvasSize: canvasSize, viewport: viewport)
                }
            }
            .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
            .compositingGroup()
        } else {
            Rectangle()
        }
    }
}

/// The retouching brushes' work in progress: the blur or mosaic showing
/// through the stroke, the smear so far, and a translucent band where the
/// healing brush has been.
private struct RetouchPreview: View {
    let retouch: RetouchOverlay
    let canvasSize: CGSize
    let viewport: CanvasViewport

    var body: some View {
        let frame = viewport.canvasFrame
        ZStack(alignment: .topLeading) {
            if !retouch.smudgePatches.isEmpty {
                Canvas { context, _ in
                    for patch in retouch.smudgePatches {
                        context.draw(
                            Image(decorative: patch.image, scale: 1),
                            in: patch.rect.applying(viewport.transform)
                        )
                    }
                }
            }
            if let image = retouch.effectImage, !retouch.effectStrokes.isEmpty {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                        StrokePreview(
                            strokes: retouch.effectStrokes.map(\.asMask), canvasSize: canvasSize, viewport: viewport
                        )
                    }
            }
            if !retouch.healStrokes.isEmpty {
                StrokePreview(
                    strokes: retouch.healStrokes.map {
                        var band = $0.asMask
                        band.settings.color = RGBAColor(red: 1, green: 0.55, blue: 0.4)
                        band.settings.opacity = 0.45
                        return band
                    },
                    canvasSize: canvasSize, viewport: viewport
                )
            }
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
    }
}

/// Strokes drawn the way `Stroke.paint` will paint them, in screen space.
private struct StrokePreview: View {
    let strokes: [Stroke]
    let canvasSize: CGSize
    let viewport: CanvasViewport

    var body: some View {
        Canvas { context, _ in
            let transform = viewport.transform
            let scale = viewport.scale
            for stroke in strokes {
                var layer = context
                if let clip = stroke.clip {
                    layer.clip(to: Path(clip.path(in: canvasSize)).applying(transform), style: FillStyle(eoFill: true))
                }
                layer.blendMode = stroke.isEraser ? .destinationOut : .normal
                layer.opacity = stroke.settings.opacity
                layer.drawLayer { group in
                    // As when painting: the stroke is drawn solid, and only
                    // put down at the brush's opacity and blend mode.
                    group.opacity = 1
                    group.blendMode = .normal
                    if stroke.settings.tip == .watercolor && !stroke.isEraser {
                        if let wash = stroke.wash(canvasSize: canvasSize) {
                            group.draw(Image(decorative: wash.image, scale: 1), in: wash.rect.applying(transform))
                        }
                        return
                    }
                    if stroke.usesDabs {
                        drawDabs(of: stroke, in: &group, transform: transform, scale: scale)
                        return
                    }
                    if stroke.settings.tip == .neon && !stroke.isEraser {
                        drawGlow(of: stroke, in: &group, transform: transform, scale: scale)
                        return
                    }
                    if stroke.settings.featherRadius > 0.5 {
                        group.addFilter(.blur(radius: stroke.settings.featherRadius * scale * 0.5))
                    }
                    let color = stroke.isEraser ? Color.black : stroke.settings.color.withAlpha(1).color
                    drawLine(of: stroke, in: &group, color: color, transform: transform, scale: scale)
                }
            }
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height)
    }
}

extension StrokePreview {
    /// The stroke's line as `Stroke.drawShape` draws it, `widthScale` as wide.
    fileprivate func drawLine(
        of stroke: Stroke, in context: inout GraphicsContext, color: Color, transform: CGAffineTransform,
        scale: Double, widthScale: Double = 1
    ) {
        if stroke.usesVaryingWidth {
            for segment in stroke.segments {
                var path = Path()
                path.move(to: segment.from.applying(transform))
                path.addLine(to: segment.to.applying(transform))
                context.stroke(path, with: .color(color), style: StrokeStyle(
                    lineWidth: segment.width * scale * widthScale, lineCap: .round, lineJoin: .round
                ))
            }
        } else {
            context.stroke(
                Path(stroke.smoothedPath).applying(transform), with: .color(color),
                style: StrokeStyle(lineWidth: stroke.settings.size * scale * widthScale, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// A neon stroke's haze and core, as `Stroke` paints them.
    fileprivate func drawGlow(of stroke: Stroke, in context: inout GraphicsContext, transform: CGAffineTransform, scale: Double) {
        let color = stroke.settings.color.withAlpha(1).color
        context.drawLayer { haze in
            // A shadow's blur reaches about twice as far as this blur's radius.
            haze.addFilter(.blur(radius: stroke.settings.size * 0.6 * scale))
            drawLine(of: stroke, in: &haze, color: color, transform: transform, scale: scale, widthScale: 0.9)
            drawLine(of: stroke, in: &haze, color: color, transform: transform, scale: scale, widthScale: 0.5)
        }
        drawLine(of: stroke, in: &context, color: color, transform: transform, scale: scale, widthScale: 0.55)
        drawLine(of: stroke, in: &context, color: stroke.glowCore.color, transform: transform, scale: scale, widthScale: 0.3)
    }

    /// A stamped stroke's dabs, placed as `Stroke.drawDabs` places them.
    fileprivate func drawDabs(of stroke: Stroke, in context: inout GraphicsContext, transform: CGAffineTransform, scale: Double) {
        let color = stroke.isEraser ? RGBAColor.black : stroke.settings.color
        if stroke.settings.tip == .pixel {
            for dab in stroke.dabs {
                var square = context
                square.opacity = dab.opacity
                square.fill(
                    Path(dab.square.applying(transform)),
                    with: .color(stroke.paint(of: dab, brush: color).withAlpha(1).color)
                )
            }
            return
        }
        if stroke.pickup != nil, !stroke.isEraser {
            // Mixed paint: the white tip, coloured dab by dab.
            let tip = context.resolve(Image(decorative: stroke.tipImage(in: .white), scale: 1))
            for dab in stroke.dabs {
                var stamp = context
                let center = dab.center.applying(transform)
                stamp.translateBy(x: center.x, y: center.y)
                stamp.rotate(by: .radians(dab.angle))
                stamp.scaleBy(x: 1, y: dab.roundness)
                stamp.opacity = dab.opacity
                stamp.addFilter(.colorMultiply(stroke.paint(of: dab, brush: color).withAlpha(1).color))
                let size = dab.diameter * scale
                stamp.draw(tip, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
            }
            return
        }
        var tips: [RGBAColor: GraphicsContext.ResolvedImage] = [:]
        for dab in stroke.dabs {
            let paint = stroke.paint(of: dab, brush: color)
            let tip = tips[paint] ?? context.resolve(Image(decorative: stroke.tipImage(in: paint), scale: 1))
            tips[paint] = tip
            var stamp = context
            let center = dab.center.applying(transform)
            stamp.translateBy(x: center.x, y: center.y)
            stamp.rotate(by: .radians(dab.angle))
            stamp.scaleBy(x: 1, y: dab.roundness)
            stamp.opacity = dab.opacity
            let size = dab.diameter * scale
            stamp.draw(tip, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
        }
        if let grain = PaperGrain.image(for: stroke.settings.tip) {
            // The paper, pinned to the canvas so the grain stays put.
            var paper = context
            paper.blendMode = .destinationIn
            let origin = CGPoint.zero.applying(transform)
            paper.fill(
                Path(stroke.bounds.applying(transform)),
                with: .tiledImage(Image(decorative: grain, scale: 1), origin: origin, scale: stroke.grainScale * scale)
            )
        }
    }
}

/// The grey and white squares that stand for transparency.
struct Checkerboard: View {
    var squareSize: CGFloat = 8
    /// How far into the pattern the view starts, so a part of a larger
    /// board lines up with the rest of it.
    var phase: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var path = Path()
            let firstColumn = Int((phase.width / squareSize).rounded(.down))
            let firstRow = Int((phase.height / squareSize).rounded(.down))
            let columns = Int(ceil(size.width / squareSize)) + 1
            let rows = Int(ceil(size.height / squareSize)) + 1
            for row in firstRow..<(firstRow + rows) {
                for column in firstColumn..<(firstColumn + columns) where (row + column) % 2 != 0 {
                    path.addRect(CGRect(
                        x: CGFloat(column) * squareSize - phase.width, y: CGFloat(row) * squareSize - phase.height,
                        width: squareSize, height: squareSize
                    ))
                }
            }
            context.fill(path, with: .color(Color(white: 0.86)))
        }
    }
}
