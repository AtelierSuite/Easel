import Foundation

/// Pixelmator Pro's colour adjustments that Easel has a filter for: one
/// control at a time, of invert, black and white, sepia, saturation,
/// vibrance, exposure, brightness and contrast.
///
/// Pixelmator keeps a layer's colour adjustments as JSON, `[3, {...}]`,
/// with a section for each group of controls, each `[1, {"E": 1, ...}]`
/// when it is turned on. Each control's value is in its own natural units
/// there, as Easel's are: saturation and brightness from -1 to 1, vibrance
/// as a fraction, exposure in stops. Pixelmator works them out its own way,
/// so they look alike in both but not the same. Easel's filter is kept
/// beside them exactly, and used again for as long as Pixelmator's setting
/// is what Easel wrote.
enum PXDAdjustments {
    static let key = "color-adjustments"
    /// Easel's own filter and the section it was written as.
    static let easelKey = "easel-adjustment"

    private struct Kept: Codable {
        var filter: LayerFilter
        var section: String
    }

    /// The section a filter is in Pixelmator, and its settings, when it has
    /// one.
    static func section(for filter: LayerFilter) -> (name: String, settings: [String: Double])? {
        switch filter.kind {
        case .invert:
            return ("i", ["i": 1])
        case .blackAndWhite where filter.values == nil || filter.values == LayerFilter(kind: .blackAndWhite).values:
            return ("b", ["i": clamp(filter.amount, 0...1), "t": 0])
        case .sepia:
            return ("s", ["i": clamp(filter.amount, 0...1)])
        case .saturation:
            return ("hS", ["h": 0, "s": clamp(filter.amount, -1...1), "v": 0, "A": 0])
        case .vibrance where filter.value(1) == 0:
            return ("hS", ["h": 0, "s": 0, "v": clamp(filter.value(0) / 100, -2...2), "A": 0])
        case .exposure where filter.value(1) == 0 && filter.value(2) == 1:
            return ("l", light(["e": clamp(filter.value(0), -4...4)]))
        case .brightness where !filter.hasPhotoshopSettings:
            return ("l", light(["b": clamp(filter.amount, -2...2)]))
        case .contrast where !filter.hasPhotoshopSettings:
            return ("l", light(["c": clamp(filter.amount, -2...2)]))
        default:
            return nil
        }
    }

    /// The Light section with one control set and the rest at nothing.
    private static func light(_ set: [String: Double]) -> [String: Double] {
        var settings: [String: Double] = ["e": 0, "h": 0, "s": 0, "b": 0, "c": 0, "B": 0, "A": 0, "C": 0, "T": 0]
        settings.merge(set) { $1 }
        return settings
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value.isFinite ? value : 0, range.lowerBound), range.upperBound)
    }

    // MARK: - Writing

    /// Colour adjustments with `filter`'s section turned on, laid over
    /// `existing` when there are any: every other section is turned off.
    static func json(for filter: LayerFilter, existing: [UInt8]? = nil) -> [UInt8]? {
        guard let (name, settings) = section(for: filter) else { return nil }
        var sections = existing.flatMap(self.sections) ?? [:]
        for (key, value) in sections {
            sections[key] = turnedOff(value)
        }
        var body: [String: Any] = settings
        body["E"] = 1
        body["V"] = 1
        sections[name] = [1, body]
        if sections["av"] == nil { sections["av"] = 1 }
        guard let data = try? JSONSerialization.data(withJSONObject: [3, sections], options: [.sortedKeys]) else { return nil }
        return [UInt8](data)
    }

    /// Easel's filter and what it was written as, kept beside Pixelmator's.
    static func kept(_ filter: LayerFilter, json: [UInt8]) -> [UInt8]? {
        guard let (name, _) = section(for: filter), let written = sections(json)?[name],
              let section = try? JSONSerialization.data(withJSONObject: written, options: [.sortedKeys]),
              let data = try? JSONEncoder().encode(Kept(filter: filter, section: String(decoding: section, as: UTF8.self)))
        else { return nil }
        return [UInt8](data)
    }

    private static func turnedOff(_ value: Any) -> Any {
        if var pair = value as? [Any], pair.count == 2, var body = pair[1] as? [String: Any], body["E"] != nil {
            body["E"] = 0
            pair[1] = body
            return pair
        }
        if var container = value as? [String: Any], var inner = container["versionSpecifiContainer"] as? [String: Any],
           inner["E"] != nil {
            inner["E"] = false
            container["versionSpecifiContainer"] = inner
            return container
        }
        return value
    }

    // MARK: - Reading

    private static func sections(_ json: [UInt8]) -> [String: Any]? {
        guard let top = try? JSONSerialization.jsonObject(with: Data(json)) as? [Any], top.count == 2 else { return nil }
        return top[1] as? [String: Any]
    }

    /// The settings of each section turned on, by name.
    private static func enabled(_ sections: [String: Any]) -> [String: [String: Any]] {
        var on: [String: [String: Any]] = [:]
        for (name, value) in sections {
            if let pair = value as? [Any], pair.count == 2, let body = pair[1] as? [String: Any] {
                if isOn(body["E"]) { on[name] = body }
            } else if let container = value as? [String: Any],
                      let inner = container["versionSpecifiContainer"] as? [String: Any], isOn(inner["E"]) {
                on[name] = inner
            }
        }
        return on
    }

    private static func isOn(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        return false
    }

    /// The one filter colour adjustments amount to, or nil when they are
    /// more than one control or one Easel has nothing like. Easel's own
    /// filter comes back while the setting is what Easel wrote.
    static func filter(json: [UInt8], kept: [UInt8]? = nil) -> LayerFilter? {
        guard let sections = sections(json) else { return nil }
        if let kept, let stored = try? JSONDecoder().decode(Kept.self, from: Data(kept)),
           let (name, _) = section(for: stored.filter), let current = sections[name],
           let data = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]),
           String(decoding: data, as: UTF8.self) == stored.section, enabled(sections).keys.sorted() == [name] {
            return stored.filter
        }
        let on = enabled(sections)
        guard on.count == 1, let (name, body) = on.first else { return nil }
        func number(_ key: String) -> Double { (body[key] as? NSNumber)?.doubleValue ?? 0 }
        /// The one setting of `keys` that is not nothing, when the rest are.
        func only(_ keys: [String]) -> (String, Double)? {
            let set = keys.filter { abs(number($0)) > 1e-9 }
            return set.count == 1 ? (set[0], number(set[0])) : nil
        }
        var filter: LayerFilter
        switch name {
        case "i":
            filter = LayerFilter(kind: .invert)
            filter.amount = 1
        case "b" where number("t") == 0:
            filter = LayerFilter(kind: .blackAndWhite)
            filter.amount = body["i"] == nil ? 1 : number("i")
        case "s":
            filter = LayerFilter(kind: .sepia)
            filter.amount = body["i"] == nil ? 1 : number("i")
        case "hS":
            guard let (key, value) = only(["h", "s", "v"]) else { return nil }
            switch key {
            case "s":
                filter = LayerFilter(kind: .saturation)
                filter.amount = value
            case "v":
                filter = LayerFilter(kind: .vibrance)
                filter.amount = 1
                filter.setValue(value * 100, at: 0)
            default:
                return nil
            }
        case "l":
            guard let (key, value) = only(["e", "h", "s", "b", "c", "B", "C", "T", "A"]) else { return nil }
            switch key {
            case "e":
                filter = LayerFilter(kind: .exposure)
                filter.amount = 1
                filter.setValue(value, at: 0)
            case "b":
                filter = LayerFilter(kind: .brightness)
                filter.amount = value
            case "c":
                filter = LayerFilter(kind: .contrast)
                filter.amount = value
            default:
                return nil
            }
        default:
            return nil
        }
        return filter
    }
}
