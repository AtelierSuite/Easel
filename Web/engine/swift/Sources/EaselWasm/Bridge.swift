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
            return [:]

        case "describe":
            return describe(try document(request))

        case "render":
            let composition = try document(request)
            let maxSize = request["maxSize"] as? Int ?? Int(max(composition.size.width, composition.size.height))
            let image = maxSize >= Int(max(composition.size.width, composition.size.height))
                ? CompositionRenderer.render(composition)
                : CompositionRenderer.thumbnail(composition, maxPixelSize: maxSize)
            output = Pixels.straight(image)
            return ["width": image.width, "height": image.height]

        case "thumbnail":
            let composition = try document(request)
            let size = request["size"] as? Int ?? 96
            guard let layerID = (request["layer"] as? String).flatMap(UUID.init(uuidString:)),
                  let layer = composition.layers.first(where: { $0.id == layerID }) else { throw Failure(message: "No such layer") }
            let image = Thumbnails.image(of: layer, in: composition, size: size)
            output = Pixels.straight(image)
            return ["width": image.width, "height": image.height]

        case "update":
            let documentID = try id(request)
            guard var composition = documents[documentID] else { throw Failure(message: "No such document") }
            Edits.apply(request, to: &composition)
            documents[documentID] = composition
            return describe(composition)

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
        var result = describe(composition)
        result["doc"] = id
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
                ]
            }
        }
        return [
            "width": Double(composition.size.width), "height": Double(composition.size.height),
            "resolution": composition.resolution ?? 72, "rows": rows,
            "blendModes": LayerBlendMode.allCases.map { ["id": $0.rawValue, "label": $0.label] },
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
