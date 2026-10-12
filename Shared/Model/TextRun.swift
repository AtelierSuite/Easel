import Foundation

/// Styling for a run of a text layer's characters, over the layer's own.
/// Unset settings follow the layer.
struct TextRun: Codable, Hashable, Sendable {
    struct Style: Codable, Hashable, Sendable {
        var color: RGBAColor?
        /// The run's size as a multiple of the layer's.
        var sizeScale: Double?
        var isBold: Bool?
        var isItalic: Bool?
        var isUnderlined: Bool?
        /// Extra room after each character, as a fraction of the font size:
        /// kerning set by hand between the letters picked.
        var kerning: Double?
        /// How far the characters sit above the line, as a fraction of the
        /// font size; negative below it.
        var baselineShift: Double?

        var isPlain: Bool { self == Style() }
    }

    /// In UTF-16 code units, as text views count.
    var location: Int
    var length: Int
    var style: Style

    var range: NSRange { NSRange(location: location, length: length) }
}

extension TextContent {
    /// The style each UTF-16 unit of the string has, one entry a unit.
    private var unitStyles: [TextRun.Style] {
        var styles = [TextRun.Style](repeating: TextRun.Style(), count: string.utf16.count)
        for run in runs ?? [] {
            let start = max(0, run.location), end = min(styles.count, run.location + run.length)
            guard start < end else { continue }
            for index in start..<end { styles[index] = run.style }
        }
        return styles
    }

    /// Runs again from a style a unit, joining neighbours alike and leaving
    /// plain stretches out.
    private static func runs(from styles: [TextRun.Style]) -> [TextRun]? {
        var runs: [TextRun] = []
        var index = 0
        while index < styles.count {
            let style = styles[index]
            var end = index + 1
            while end < styles.count, styles[end] == style { end += 1 }
            if !style.isPlain { runs.append(TextRun(location: index, length: end - index, style: style)) }
            index = end
        }
        return runs.isEmpty ? nil : runs
    }

    /// The style shared by every unit in `range`, setting by setting: what
    /// the controls for a selection show.
    func style(in range: NSRange) -> TextRun.Style {
        let styles = unitStyles
        let start = max(0, range.location), end = min(styles.count, range.location + max(range.length, 1))
        guard start < end else { return TextRun.Style() }
        let picked = styles[start..<end]
        var shared = picked.first ?? TextRun.Style()
        func keep<Value: Equatable>(_ keyPath: WritableKeyPath<TextRun.Style, Value?>) {
            if picked.contains(where: { $0[keyPath: keyPath] != shared[keyPath: keyPath] }) { shared[keyPath: keyPath] = nil }
        }
        keep(\.color)
        keep(\.sizeScale)
        keep(\.isBold)
        keep(\.isItalic)
        keep(\.isUnderlined)
        keep(\.kerning)
        keep(\.baselineShift)
        return shared
    }

    /// Changes the style of the characters in `range`.
    mutating func restyle(_ range: NSRange, _ change: (inout TextRun.Style) -> Void) {
        var styles = unitStyles
        let start = max(0, range.location), end = min(styles.count, range.location + range.length)
        guard start < end else { return }
        for index in start..<end { change(&styles[index]) }
        runs = Self.runs(from: styles)
    }

    /// Takes the styling off the characters in `range`.
    mutating func clearStyle(_ range: NSRange) {
        restyle(range) { $0 = TextRun.Style() }
    }

    /// Replaces the words, keeping each run on the characters it was on:
    /// typing inside a run carries its style, and runs past the change move
    /// along with their characters.
    mutating func setString(_ newValue: String) {
        guard let runs, !runs.isEmpty else {
            string = newValue
            return
        }
        let old = Array(string.utf16), new = Array(newValue.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let styles = unitStyles
        // What was typed takes the style of the character before it.
        let typed = new.count - prefix - suffix
        let carried = prefix > 0 ? styles[prefix - 1] : (styles.first ?? TextRun.Style())
        let restyled = Array(styles[..<prefix]) + Array(repeating: carried, count: typed)
            + Array(styles[(old.count - suffix)...])
        string = newValue
        self.runs = Self.runs(from: restyled)
    }
}
