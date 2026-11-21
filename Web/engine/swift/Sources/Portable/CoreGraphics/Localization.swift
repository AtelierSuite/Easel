import Foundation

// String(localized:) on the web: keys are looked up in a table the page
// loads (converted from Shared/Support/Localizable.xcstrings by build.sh).

public enum LocalizedStrings {
    nonisolated(unsafe) public static var table: [String: String] = [:]

    static func format(_ key: String, _ arguments: [String]) -> String {
        let template = table[key] ?? key
        guard !arguments.isEmpty else { return template }
        var result = ""
        var index = 0
        var characters = Array(template)
        var i = 0
        characters.append("\0")
        while i < characters.count - 1 {
            let c = characters[i]
            guard c == "%" else {
                result.append(c)
                i += 1
                continue
            }
            if characters[i + 1] == "%" {
                result.append("%")
                i += 2
                continue
            }
            // %[n$][flags][width][.precision][length]conversion
            var j = i + 1
            var position: Int?
            var digits = ""
            while characters[j].isNumber { digits.append(characters[j]); j += 1 }
            if characters[j] == "$", let n = Int(digits) {
                position = n - 1
                j += 1
            } else {
                j = i + 1
            }
            while "-+ #0.123456789".contains(characters[j]) { j += 1 }
            while "hlqLzjt".contains(characters[j]) { j += 1 }
            let argument = position ?? index
            if position == nil { index += 1 }
            result += argument < arguments.count ? arguments[argument] : ""
            i = j + 1
        }
        return result
    }
}

extension String {
    public struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
        var key: String
        var arguments: [String]

        public init(_ key: String) {
            self.key = key
            arguments = []
        }

        public init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        public struct StringInterpolation: StringInterpolationProtocol, Sendable {
            var key = ""
            var arguments: [String] = []

            public init(literalCapacity: Int, interpolationCount: Int) {}

            public mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }

            public mutating func appendInterpolation(_ value: String) {
                key += "%@"
                arguments.append(value)
            }

            public mutating func appendInterpolation<T: BinaryInteger>(_ value: T) {
                key += "%lld"
                arguments.append(String(value))
            }

            public mutating func appendInterpolation(_ value: Double) {
                key += "%lf"
                arguments.append(Self.decimal(value))
            }

            public mutating func appendInterpolation(_ value: Float) {
                key += "%f"
                arguments.append(Self.decimal(Double(value)))
            }

            public mutating func appendInterpolation(_ value: CGFloat) {
                key += "%lf"
                arguments.append(Self.decimal(Double(value)))
            }

            public mutating func appendInterpolation<T>(_ value: T) {
                key += "%@"
                arguments.append(String(describing: value))
            }

            static func decimal(_ value: Double) -> String {
                value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(format: "%g", value)
            }
        }
    }

    public init(localized value: LocalizationValue, table: String? = nil, comment: StaticString? = nil) {
        self = LocalizedStrings.format(value.key, value.arguments)
    }

    public init(localized value: LocalizationValue, defaultValue: LocalizationValue, table: String? = nil, comment: StaticString? = nil) {
        let key = value.key
        if LocalizedStrings.table[key] == nil {
            self = LocalizedStrings.format(defaultValue.key, defaultValue.arguments)
        } else {
            self = LocalizedStrings.format(key, value.arguments)
        }
    }

    public init(localized key: String, defaultValue: String, table: String? = nil, comment: StaticString? = nil) {
        self = LocalizedStrings.table[key] ?? defaultValue
    }
}
