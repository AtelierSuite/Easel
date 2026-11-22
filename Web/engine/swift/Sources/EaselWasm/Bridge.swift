import CoreGraphics
import Foundation
import Paintbrush

/// Turns the page's requests into Paintbrush calls. Every request is a JSON
/// object with an "op"; every response is one with "ok", and the error's
/// message when it isn't.
@MainActor
final class Bridge {
    static let shared = Bridge()

    private var documents: [Int: Composition] = [:]
    private var histories: [Int: History] = [:]
    private var selections: [Int: Selection] = [:]
    private var nextID = 1

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func handle(_ request: Data, payload: Data?) -> (Data, Data?) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let op = object["op"] as? String else { throw Failure(message: "Bad request") }
            var output: Data?
            var result = try perform(op, object, payload: payload, output: &output)
            result["ok"] = true
            return (try JSONSerialization.data(withJSONObject: result), output)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let json = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
            return (json, nil)
        }
    }

    private func perform(_ op: String, _ request: [String: Any], payload: Data?, output: inout Data?) throws -> [String: Any] {
        switch op {
        case "strings":
            LocalizedStrings.table = request["table"] as? [String: String] ?? [:]
            return [:]

        case "open":
            guard let payload else { throw Failure(message: "Nothing to open") }
            let name = request["name"] as? String ?? ""
            let composition = try Documents.open(payload, name: name, isPackage: request["package"] as? Bool ?? false)
            return add(composition)

        case "new":
            let width = max(1, min(request["width"] as? Double ?? 2048, Double(Bitmap.maximumDimension)))
            let height = max(1, min(request["height"] as? Double ?? 1536, Double(Bitmap.maximumDimension)))
            let fill = (request["fill"] as? [Double]).map { RGBAColor(red: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) } ?? .white
            return add(Composition.blank(size: CGSize(width: width, height: height), fill: fill))

        case "sample":
            return add(Sample.composition())

        case "close":
            documents[try id(request)] = nil
            histories[try id(request)] = nil
            selections[try id(request)] = nil
            return [:]

        case "describe":
            _ = try document(request)
            return describe(try id(request))

        case "render":
            let composition = try document(request)
            let maxSize = request["maxSize"] as? Int ?? Int(max(composition.size.width, composition.size.height))
            let image = maxSize >= Int(max(composition.size.width, composition.size.height))
                ? CompositionRenderer.render(composition)
                : CompositionRenderer.thumbnail(composition, maxPixelSize: maxSize)
            output = Pixels.straight(image)
            return ["width": image.width, "height": image.height]

        case "canvas":
            let composition = try document(request)
            let split = CanvasParts(composition, active: (request["layer"] as? String).flatMap(UUID.init(uuidString:)))
            let size = CanvasParts.size(of: composition, maxSize: request["maxSize"] as? Int ?? 4096)
            // After a stroke only the part painted on changes.
            let onlyActive = request["only"] as? String == "active"
            var pixels = Data()
            var rendered: [Int] = []
            for (index, part) in split.parts.enumerated() where !onlyActive || part.isActive {
                pixels.append(CanvasParts.pixels(of: part, in: composition, size: size))
                rendered.append(index)
            }
            output = pixels
            return [
                "width": Int(size.width), "height": Int(size.height), "parts": split.describe(),
                "key": split.key, "rendered": rendered,
            ]

        case "thumbnail":
            let composition = try document(request)
            let size = request["size"] as? Int ?? 96
            guard let layerID = (request["layer"] as? String).flatMap(UUID.init(uuidString:)),
                  let layer = composition.layers.first(where: { $0.id == layerID }) else { throw Failure(message: "No such layer") }
            let image = Thumbnails.image(of: layer, in: composition, size: size)
            output = Pixels.straight(image)
            return ["width": image.width, "height": image.height]

        case "update":
            return try edit(request, undoable: request["expanded"] == nil) { Edits.apply(request, to: &$0) }

        case "layers":
            let selection = selections[try id(request)]
            var picked: UUID?
            var result = try edit(request) { picked = try LayerActions.perform(request, in: &$0, selection: selection, payload: payload) }
            result["added"] = picked?.uuidString
            return result

        case "stroke":
            let selection = selections[try id(request)]
            return try edit(request) { try Painting.stroke(request, in: &$0, selection: selection) }

        case "fill":
            let selection = selections[try id(request)]
            return try edit(request) { try Painting.fill(request, in: &$0, selection: selection) }

        case "gradient":
            let selection = selections[try id(request)]
            return try edit(request) { try Painting.gradient(request, in: &$0, selection: selection) }

        case "clear":
            guard let selection = selections[try id(request)] else { return describe(try id(request)) }
            return try edit(request) { try Painting.clear(request, in: &$0, selection: selection) }

        case "move":
            return try edit(request) { try Arranging.move(request, in: &$0) }

        case "place":
            return try edit(request) { try Arranging.place(request, in: &$0) }

        case "turnCanvas":
            let documentID = try id(request)
            var selection = selections[documentID]
            let clockwise = request["clockwise"] as? Bool
            let horizontal = request["horizontal"] as? Bool ?? true
            let result = try edit(request) { composition in
                let transform = clockwise.map { composition.rotationTransform(clockwise: $0) } ?? composition.flipTransform(horizontal: horizontal)
                if let clockwise { composition.rotate(clockwise: clockwise) } else { composition.flip(horizontal: horizontal) }
                selection = selection.map { $0.applying(transform, canvasSize: composition.size) }
            }
            selections[documentID] = selection
            return describe(documentID).merging(result) { mine, _ in mine }

        case "hit":
            let composition = try document(request)
            let point = CGPoint(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0)
            let layer = Arranging.layer(at: point, in: composition, text: request["text"] as? Bool ?? false)
            return ["layer": layer?.id.uuidString ?? NSNull(), "string": layer?.text?.string ?? NSNull()]

        case "shape":
            var added: Layer.ID?
            var result = try edit(request) { added = Arranging.shape(request, in: &$0) }
            result["added"] = added?.uuidString
            return result

        case "paths":
            let composition = try document(request)
            guard let layerID = (request["layer"] as? String).flatMap(UUID.init(uuidString:)),
                  let layer = composition[layerID] else { return ["paths": []] }
            var result: [String: Any] = ["paths": Vectors.describe(layer), "locked": composition.isLocked(layer)]
            if request["faces"] as? Bool == true { result.merge(Vectors.faces(of: layer)) { mine, _ in mine } }
            return result

        case "vector":
            var picked: Layer.ID?
            var result = try edit(request) { picked = try Vectors.edit(request, in: &$0) }
            result["added"] = picked?.uuidString
            return result

        case "transform":
            switch request["action"] as? String {
            case "handles":
                return try Transforming.handles(request, in: try document(request))
            case "preview":
                let image = try Transforming.preview(request, in: try document(request))
                output = Pixels.straight(image)
                return ["width": image.width, "height": image.height]
            default:
                return try edit(request) { try Transforming.apply(request, in: &$0) }
            }

        case "text":
            var added: Layer.ID?
            var result = try edit(request) { added = try Arranging.text(request, in: &$0) }
            result["added"] = added?.uuidString
            return result

        case "crop":
            let documentID = try id(request)
            var selection = selections[documentID]
            let result = try edit(request) { Arranging.crop(request, in: &$0, selection: &selection) }
            selections[documentID] = selection
            return describe(documentID).merging(result) { mine, _ in mine }

        case "withSelection":
            let documentID = try id(request)
            guard let selection = selections[documentID] else { return describe(documentID) }
            if request["action"] as? String == "crop" {
                let bounds = selection.bounds(in: try document(request).size).integral
                guard bounds.width >= 1, bounds.height >= 1 else { return describe(documentID) }
                let result = try edit(request) { $0.crop(to: bounds.intersection($0.canvasRect)) }
                selections[documentID] = nil
                return describe(documentID).merging(result) { mine, _ in mine }
            }
            var picked: Layer.ID?
            var result = try edit(request) { picked = try Painting.withSelection(request, in: &$0, selection: selection) }
            result["added"] = picked?.uuidString
            return result

        case "select":
            let documentID = try id(request)
            let composition = try document(request)
            selections[documentID] = Arranging.select(request, in: composition, current: selections[documentID])
            return describe(documentID)

        case "undo", "redo":
            let documentID = try id(request)
            guard let current = documents[documentID] else { throw Failure(message: "No such document") }
            var history = histories[documentID] ?? History()
            if let state = op == "undo" ? history.undo(current) : history.redo(current) { documents[documentID] = state }
            histories[documentID] = history
            return describe(documentID)

        case "export":
            let composition = try document(request)
            let format = request["format"] as? String ?? "png"
            output = try Documents.export(composition, as: format, quality: request["quality"] as? Double ?? 0.92)
            return [:]

        default:
            throw Failure(message: "Unknown request \(op)")
        }
    }

    private func id(_ request: [String: Any]) throws -> Int {
        guard let id = request["doc"] as? Int else { throw Failure(message: "No document named") }
        return id
    }

    private func document(_ request: [String: Any]) throws -> Composition {
        guard let composition = documents[try id(request)] else { throw Failure(message: "No such document") }
        return composition
    }

    private func add(_ composition: Composition) -> [String: Any] {
        let id = nextID
        nextID += 1
        documents[id] = composition
        var result = describe(id)
        result["doc"] = id
        return result
    }

    /// Changes a document as one step that Undo takes back.
    private func edit(
        _ request: [String: Any], undoable: Bool = true, _ change: (inout Composition) throws -> Void
    ) throws -> [String: Any] {
        let documentID = try id(request)
        guard var composition = documents[documentID] else { throw Failure(message: "No such document") }
        let before = composition
        try change(&composition)
        documents[documentID] = composition
        if undoable { histories[documentID, default: History()].record(before) }
        return describe(documentID)
    }

    private func describe(_ documentID: Int) -> [String: Any] {
        guard let composition = documents[documentID] else { return [:] }
        var result = describe(composition)
        let history = histories[documentID] ?? History()
        result["canUndo"] = history.canUndo
        result["canRedo"] = history.canRedo
        result["selection"] = Arranging.outline(of: selections[documentID], in: composition.size) ?? NSNull()
        return result
    }

    private func describe(_ composition: Composition) -> [String: Any] {
        let rows: [[String: Any]] = composition.layerListRows.map { row in
            switch row {
            case .group(let group, let depth):
                return [
                    "kind": "group", "id": group.id.uuidString, "name": group.name, "depth": depth,
                    "visible": group.isVisible, "opacity": group.opacity, "blendMode": group.blendMode?.rawValue ?? "passThrough",
                    "locked": group.isLocked, "expanded": group.isExpanded, "masked": group.mask != nil,
                ]
            case .layer(let layer, let depth):
                return [
                    "kind": "layer", "id": layer.id.uuidString, "name": layer.name, "depth": depth,
                    "visible": layer.isVisible, "opacity": layer.opacity, "blendMode": layer.blendMode.rawValue,
                    "locked": layer.isLocked, "clipped": layer.isClipped, "masked": layer.mask != nil,
                    "type": Self.type(of: layer), "effects": layer.effects.count, "filters": layer.filters.count,
                    "fillOpacity": layer.fillOpacity, "maskEnabled": layer.mask?.isEnabled ?? false,
                    "canClip": composition.canClip(layer.id), "canMergeDown": composition.canMergeDown(layer.id),
                    "groupID": layer.groupID?.uuidString ?? NSNull(), "groupLocked": composition.isLocked(layer),
                    "adjustment": layer.adjustment.map(LayerActions.describe) ?? NSNull(),
                    "scale": layer.transform.uniformScale, "rotation": layer.transform.rotation * 180 / .pi,
                ]
            }
        }
        return [
            "width": Double(composition.size.width), "height": Double(composition.size.height),
            "resolution": composition.resolution ?? 72, "rows": rows,
            "blendModes": LayerBlendMode.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "adjustmentKinds": LayerActions.adjustmentKinds,
            "groups": composition.groups.map { ["id": $0.id.uuidString, "name": $0.name] },
            "patterns": composition.patterns.map { ["id": $0.id.uuidString, "name": $0.name] },
            "losses": composition.writeBackLosses.map { String(describing: $0) },
        ]
    }

    private static func type(of layer: Layer) -> String {
        if layer.text != nil { return "text" }
        if layer.vector != nil { return "vector" }
        if layer.adjustment != nil { return "adjustment" }
        if layer.smartObject != nil { return "smart" }
        return "pixel"
    }
}
