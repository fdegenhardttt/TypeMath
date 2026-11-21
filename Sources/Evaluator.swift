import Foundation

enum Evaluator {
    /// How answers are written.
    struct Options {
        var groupThousands = false
        /// Fixed number of decimals, or nil for as many as needed.
        var decimals: Int?
    }
    static var options = Options()

    /// The last answer the user saw or accepted, used by "ans".
    static var lastAnswer: Double?
    /// Today's date and the locale for dates; replaceable in tests.
    static var now: () -> Date = Date.init
    static var locale = Locale.current

    /// A function of x the user typed, e.g. "x^2 - 4" or "sin(x)".
    struct Graph {
        let function: (Double) -> Double
        /// Uses sin/cos/tan, so a range of -2π…2π reads better than -10…10.
        let isTrigonometric: Bool
    }

    /// What to show for the equation at the end of the typed text.
    struct Match {
        /// The answer to type in, or nil when the equation is a function to graph.
        let answer: String?
        var graph: Graph? = nil
        /// How many characters at the end of the text make up the equation (for replacing it).
        let length: Int
        /// The numeric answer, for "ans".
        var value: Double? = nil
        /// Whether the equation itself uses "ans".
        var usesAns = false
    }

    /// Finds an equation the user just finished typing, e.g. "total 4*4 = " -> 16,
    /// "what's 15% of 80?" -> 12, "5 km in miles =" -> 3.1069 miles, or "y = x^2 =" -> a graph.
    static func match(in text: String) -> Match? {
        var chars = Array(text)
        while chars.last == " " { chars.removeLast() }
        if chars.last == "?" {
            // Questions only count when they read like one: "what's 15% of 80?"
            chars.removeLast()
            while chars.last == " " { chars.removeLast() }
            guard let (match, hasLeadIn) = solve(chars, textLength: text.count),
                  hasLeadIn, match.graph == nil else { return nil }
            return match
        }
        guard chars.last == "=" else { return functionDefinition(chars, textLength: text.count) }
        chars.removeLast()
        while chars.last == " " { chars.removeLast() }
        return solve(chars, textLength: text.count)?.match
    }

    /// The answer for highlighted text such as "12*7", "15% of 80" or "x^2", if all of it is maths.
    static func selectionMatch(_ text: String) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200, !trimmed.contains("\n") else { return nil }
        for candidate in [trimmed, trimmed + " ="] {
            if let match = match(in: candidate), match.length == candidate.count { return match }
        }
        return nil
    }

    /// Solves the maths that ends at the end of `chars` (the "=" or "?" already removed).
    private static func solve(_ chars: [Character], textLength: Int) -> (match: Match, hasLeadIn: Bool)? {
        let normalized = Normalizer.normalize(chars)
        let text = normalized.chars

        var found: (answer: String?, graph: Graph?, value: Double?, usesAns: Bool, start: Int)?
        if let (answer, start) = dateAnswer(String(text)) ?? currencyConversion(text) ?? conversion(text) {
            found = (answer, nil, nil, false, start)
        } else if let (parsed, start) = expressionSuffix(text), parsed.operations > 0 {
            if parsed.usesX {
                found = (nil, Graph(function: parsed.function, isTrigonometric: parsed.usesTrig), nil, false, start)
            } else if let value = parsed.value {
                found = (format(value), nil, value, parsed.usesAns, start)
            }
        }
        guard let found else { return nil }

        var start = normalized.origin[found.start]
        let leadIn = leadInStart(chars, before: start)
        if let leadIn { start = leadIn }
        let match = Match(answer: found.answer, graph: found.graph, length: textLength - start,
                          value: found.value, usesAns: found.usesAns)
        return (match, leadIn != nil)
    }

    private static let leadIns = ["what is", "what's", "what’s", "whats", "what are", "how much is",
                                  "how much are", "calculate", "compute", "evaluate"]

    /// Where a lead-in like "what is" starts, if one comes right before `index`, so Tab replaces the whole question.
    private static func leadInStart(_ chars: [Character], before index: Int) -> Int? {
        var end = index
        while end > 0, chars[end - 1] == " " { end -= 1 }
        let before = String(chars[..<end]).lowercased()
        for leadIn in leadIns where before.hasSuffix(leadIn) {
            let start = end - leadIn.count
            if start == 0 || !isLetter(chars[start - 1]) { return start }
        }
        return nil
    }

    /// Evaluates a plain-text expression like "4*4", "(2+3)^2", "sqrt(2)".
    /// By default returns nil for input with no actual operation (e.g. "2024").
    static func evaluate(_ input: String, requireOperation: Bool = true) -> Double? {
        var parser = Parser(input)
        guard let parsed = parser.parse(), !parsed.usesX,
              !requireOperation || parsed.operations > 0 else { return nil }
        return parsed.value
    }

    static func format(_ value: Double, maxFractionDigits: Int = 10, minFractionDigits: Int = 0) -> String {
        let value = abs(value) < 1e-12 ? 0 : value  // hide floating-point noise like sin(pi) = 1.2e-16
        if value == value.rounded(), abs(value) < 1e15, minFractionDigits == 0, !options.groupThousands {
            return String(Int64(value))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = options.groupThousands
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        if abs(value) >= 1e15 || (abs(value) < 1e-6 && value != 0) {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 6
        } else {
            formatter.numberStyle = .decimal
            let maxDigits = min(options.decimals ?? maxFractionDigits, maxFractionDigits)
            formatter.maximumFractionDigits = abs(value) < 0.01 && options.decimals == nil ? 10 : maxDigits
            formatter.minimumFractionDigits = min(minFractionDigits, formatter.maximumFractionDigits)
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A function being typed as "f(x) = …" or "y = …", graphed live as it is written.
    private static func functionDefinition(_ chars: [Character], textLength: Int) -> Match? {
        guard let equals = chars.lastIndex(of: "=") else { return nil }
        var parser = Parser(String(chars[(equals + 1)...]))
        guard let parsed = parser.parse(), parsed.usesX else { return nil }

        var end = equals
        while end > 0, chars[end - 1] == " " { end -= 1 }
        let name = String(chars[..<end])
        var start = end
        if name.hasSuffix("(x)") {
            start -= 3
            guard start > 0, isLetter(chars[start - 1]) else { return nil }  // f(x), g(x)
            while start > 0, isLetter(chars[start - 1]) { start -= 1 }
        } else if name.hasSuffix("y") {
            start -= 1
        } else {
            return nil
        }
        if start > 0, isLetter(chars[start - 1]) || chars[start - 1].isNumber { return nil }  // "may = …"

        let graph = Graph(function: parsed.function, isTrigonometric: parsed.usesTrig)
        return Match(answer: nil, graph: graph, length: textLength - start)
    }

    // MARK: Finding the expression

    static func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    private static let symbols = Set("0123456789.,+-*/×÷^%()√π°! ")
    private static let validStart = Set("0123456789.(-√π")

    /// The longest maths expression at the end of `chars`, and the index where it starts.
    /// Tries each word boundary from the left, so "the total is 12+30" finds "12+30".
    private static func expressionSuffix(_ chars: [Character]) -> (Parsed, Int)? {
        var start = chars.count
        while start > 0, symbols.contains(chars[start - 1]) || isLetter(chars[start - 1]) { start -= 1 }

        for i in start..<chars.count {
            let c = chars[i]
            guard validStart.contains(c) || isLetter(c) else { continue }
            if i > start, isLetter(chars[i - 1]) || chars[i - 1].isNumber { continue }  // mid-word
            var parser = Parser(String(chars[i...]))
            if let parsed = parser.parse() { return (parsed, i) }
        }
        return nil
    }

    // MARK: Currency

    /// Parses "<amount> <currency> in|to|as <currency>", also "$100 in eur" and "50€ to $".
    private static func currencyConversion(_ chars: [Character]) -> (String, Int)? {
        guard !Currency.rates.isEmpty else { return nil }
        func name(endingAt end: Int) -> (String, Int)? {
            var start = end
            while start > 0, isLetter(chars[start - 1]) || Currency.symbols.contains(chars[start - 1]) { start -= 1 }
            return start < end ? (String(chars[start..<end]), start) : nil
        }
        func skipSpaces(from end: Int) -> Int {
            var i = end
            while i > 0, chars[i - 1] == " " { i -= 1 }
            return i
        }

        guard let (toName, toStart) = name(endingAt: chars.count), let to = Currency.code(for: toName) else { return nil }
        var i = skipSpaces(from: toStart)
        guard i < toStart, let (connector, connectorStart) = name(endingAt: i),
              ["in", "to", "as"].contains(connector.lowercased()) else { return nil }
        i = skipSpaces(from: connectorStart)

        var from: String?
        if let (fromName, fromStart) = name(endingAt: i), let code = Currency.code(for: fromName) {
            from = code
            i = skipSpaces(from: fromStart)
        }
        guard let (parsed, exprStart) = expressionSuffix(Array(chars[..<i])),
              !parsed.usesX, let amount = parsed.value else { return nil }

        var start = exprStart
        if from == nil {  // "$100", "€ 50"
            let j = skipSpaces(from: exprStart)
            guard j > 0, Currency.symbols.contains(chars[j - 1]),
                  let code = Currency.code(for: String(chars[j - 1])) else { return nil }
            from = code
            start = j - 1
        }
        guard let from, let result = Currency.convert(amount, from: from, to: to) else { return nil }

        let number = format(result, maxFractionDigits: 2, minFractionDigits: 2)
        if toName.count == 1 { return ("\(toName)\(number)", start) }       // "$54.12"
        let label = toName.count == 3 && toName.lowercased() == to.lowercased() ? to : toName
        return ("\(number) \(label)", start)                                // "54.12 EUR", "54.12 euros"
    }

    // MARK: Unit conversion

    private static let unitChars = Set("°/²³µ").union("0123456789")

    /// Parses "<amount> <unit> in|to|as <unit>" at the end of `chars`.
    private static func conversion(_ chars: [Character]) -> (String, Int)? {
        func word(endingAt end: Int) -> (String, Int)? {
            var start = end
            while start > 0, isLetter(chars[start - 1]) || unitChars.contains(chars[start - 1]) { start -= 1 }
            while start < end, chars[start].isNumber { start += 1 }  // "5km" -> "km"
            return start < end ? (String(chars[start..<end]), start) : nil
        }
        func skipSpaces(from end: Int) -> Int {
            var i = end
            while i > 0, chars[i - 1] == " " { i -= 1 }
            return i
        }

        guard let (toName, toStart) = word(endingAt: chars.count) else { return nil }
        var i = skipSpaces(from: toStart)
        guard i < toStart, let (connector, connectorStart) = word(endingAt: i),
              ["in", "to", "as"].contains(connector.lowercased()) else { return nil }
        i = skipSpaces(from: connectorStart)
        guard i < connectorStart, let (fromName, fromStart) = word(endingAt: i) else { return nil }
        i = skipSpaces(from: fromStart)

        guard let from = units[fromName.lowercased()], let to = units[toName.lowercased()],
              from.dimension == to.dimension,
              let (parsed, start) = expressionSuffix(Array(chars[..<i])),
              !parsed.usesX, let amount = parsed.value else { return nil }

        let result = (amount * from.factor + from.offset - to.offset) / to.factor
        guard result.isFinite else { return nil }
        return ("\(format(result, maxFractionDigits: 4)) \(toName)", start)
    }

    private struct Unit {
        let dimension: String
        let factor: Double  // to the base unit
        var offset: Double = 0
    }

    private static let units: [String: Unit] = {
        var table = [String: Unit]()
        func add(_ dimension: String, _ factor: Double, _ names: String, offset: Double = 0) {
            for name in names.split(separator: " ") {
                table[String(name)] = Unit(dimension: dimension, factor: factor, offset: offset)
            }
        }
        add("length", 1, "m metre metres meter meters")
        add("length", 1000, "km kilometre kilometres kilometer kilometers")
        add("length", 0.01, "cm centimetre centimetres centimeter centimeters")
        add("length", 0.001, "mm millimetre millimetres millimeter millimeters")
        add("length", 1e-6, "µm um micron microns micrometre micrometres micrometer micrometers")
        add("length", 1e-9, "nm nanometre nanometres nanometer nanometers")
        add("length", 1609.344, "mi mile miles")
        add("length", 0.9144, "yd yard yards")
        add("length", 0.3048, "ft foot feet")
        add("length", 0.0254, "in inch inches")
        add("length", 1852, "nmi")
        add("length", 149_597_870_700, "au")
        add("length", 9_460_730_472_580_800, "ly lightyear lightyears")

        add("area", 1, "m2 m² sqm")
        add("area", 1e6, "km2 km² sqkm")
        add("area", 1e-4, "cm2 cm²")
        add("area", 1e-6, "mm2 mm²")
        add("area", 10_000, "ha hectare hectares")
        add("area", 4046.8564224, "acre acres")
        add("area", 0.09290304, "ft2 ft² sqft")
        add("area", 0.00064516, "in2 in² sqin")
        add("area", 0.83612736, "yd2 yd²")
        add("area", 2_589_988.110336, "mi2 mi² sqmi")

        add("mass", 1, "kg kilo kilos kilogram kilograms")
        add("mass", 0.001, "g gram grams")
        add("mass", 1e-6, "mg milligram milligrams")
        add("mass", 1e-9, "µg ug mcg microgram micrograms")
        add("mass", 1000, "t tonne tonnes")
        add("mass", 907.18474, "ton tons")
        add("mass", 0.45359237, "lb lbs pound pounds")
        add("mass", 0.028349523125, "oz ounce ounces")
        add("mass", 6.35029318, "st stone stones")
        add("mass", 0.0002, "ct carat carats")

        add("volume", 1, "l litre litres liter liters")
        add("volume", 0.1, "dl")
        add("volume", 0.01, "cl")
        add("volume", 0.001, "ml millilitre millilitres milliliter milliliters cm3 cm³ cc")
        add("volume", 1000, "m3 m³")
        add("volume", 3.785411784, "gal gallon gallons")
        add("volume", 4.54609, "ukgal")
        add("volume", 0.946352946, "qt quart quarts")
        add("volume", 0.473176473, "pt pint pints")
        add("volume", 0.56826125, "ukpt ukpint")
        add("volume", 0.2365882365, "cup cups")
        add("volume", 0.0295735295625, "floz")
        add("volume", 0.01478676478125, "tbsp")
        add("volume", 0.00492892159375, "tsp")
        add("volume", 28.316846592, "ft3 ft³")
        add("volume", 0.016387064, "in3 in³")

        add("temperature", 1, "c °c celsius", offset: 273.15)
        add("temperature", 5.0 / 9, "f °f fahrenheit", offset: 273.15 - 32 * 5.0 / 9)
        add("temperature", 1, "k kelvin")

        add("time", 1e-9, "ns nanosecond nanoseconds")
        add("time", 1e-6, "µs us microsecond microseconds")
        add("time", 0.001, "ms millisecond milliseconds")
        add("time", 1, "s sec secs second seconds")
        add("time", 60, "min mins minute minutes")
        add("time", 3600, "h hr hrs hour hours")
        add("time", 86400, "d day days")
        add("time", 604_800, "wk week weeks")
        add("time", 2_629_800, "mo month months")
        add("time", 31_557_600, "yr year years")
        add("time", 315_576_000, "decade decades")
        add("time", 3_155_760_000, "century centuries")

        add("speed", 1, "m/s")
        add("speed", 1 / 3.6, "km/h kph kmh")
        add("speed", 1000, "km/s")
        add("speed", 0.44704, "mph")
        add("speed", 0.3048, "ft/s")
        add("speed", 0.514444, "kn knot knots")
        add("speed", 343, "mach")

        add("energy", 1, "j joule joules")
        add("energy", 1000, "kj kilojoule kilojoules")
        add("energy", 1e6, "mj megajoule megajoules")
        add("energy", 4.184, "cal calorie calories")
        add("energy", 4184, "kcal")
        add("energy", 3600, "wh")
        add("energy", 3.6e6, "kwh")
        add("energy", 1055.05585, "btu")
        add("energy", 1.602176634e-19, "ev")

        add("power", 1, "w watt watts")
        add("power", 1000, "kw kilowatt kilowatts")
        add("power", 1e6, "mw megawatt megawatts")
        add("power", 745.69987, "hp horsepower")

        add("pressure", 1, "pa pascal pascals")
        add("pressure", 1000, "kpa")
        add("pressure", 100_000, "bar")
        add("pressure", 100, "mbar hpa")
        add("pressure", 6894.757293, "psi")
        add("pressure", 101_325, "atm")
        add("pressure", 133.322387, "mmhg")

        add("angle", 1, "rad radian radians")
        add("angle", Double.pi / 180, "° deg degree degrees")
        add("angle", Double.pi / 200, "grad gon")
        add("angle", 2 * Double.pi, "turn turns rev revs")

        add("frequency", 1, "hz")
        add("frequency", 1000, "khz")
        add("frequency", 1e6, "mhz")
        add("frequency", 1e9, "ghz")
        add("frequency", 1.0 / 60, "rpm")

        add("data", 1, "b byte bytes")
        add("data", 0.125, "bit bits")
        add("data", 1e3, "kb")
        add("data", 1e6, "mb")
        add("data", 1e9, "gb")
        add("data", 1e12, "tb")
        add("data", 1024, "kib")
        add("data", 1_048_576, "mib")
        add("data", 1_073_741_824, "gib")
        add("data", 1_099_511_627_776, "tib")

        add("data rate", 1, "bps")
        add("data rate", 1e3, "kbps")
        add("data rate", 1e6, "mbps")
        add("data rate", 1e9, "gbps")
        add("data rate", 8e3, "kb/s")
        add("data rate", 8e6, "mb/s")
        add("data rate", 8e9, "gb/s")
        return table
    }()
}

// MARK: - Parser

/// A parsed expression, as a function of x.
private struct Parsed {
    let function: (Double) -> Double
    let usesX: Bool
    let usesTrig: Bool
    let usesAns: Bool
    let operations: Int

    /// The value of an expression without x, if it is a real number.
    var value: Double? {
        let v = function(0)
        return v.isFinite ? v : nil
    }
}

private struct Parser {
    typealias Fn = (Double) -> Double

    private let chars: [Character]
    private var pos = 0
    private var operations = 0
    private var usesX = false
    private var usesTrig = false
    private var usesAns = false
    /// Whether the last postfix parsed ended in "%", so "200 + 10%" can mean 200 + 10% of 200.
    private var lastWasPercent = false

    init(_ input: String) { chars = Array(input) }

    mutating func parse() -> Parsed? {
        guard let f = expression() else { return nil }
        skipSpaces()
        guard pos == chars.count else { return nil }
        return Parsed(function: f, usesX: usesX, usesTrig: usesTrig, usesAns: usesAns, operations: operations)
    }

    private mutating func skipSpaces() {
        while pos < chars.count, chars[pos] == " " { pos += 1 }
    }

    private mutating func peek() -> Character? {
        skipSpaces()
        return pos < chars.count ? chars[pos] : nil
    }

    // expression = term (('+' | '-') term)*
    private mutating func expression() -> Fn? {
        guard var f = term()?.function else { return nil }
        while let c = peek(), c == "+" || c == "-" {
            pos += 1
            guard let (g, isPercent) = term() else { return nil }
            let lhs = f
            let amount: Fn = isPercent ? { lhs($0) * g($0) } : g  // calculator-style: 200 + 10% = 220
            f = c == "+" ? { lhs($0) + amount($0) } : { lhs($0) - amount($0) }
            operations += 1
        }
        return f
    }

    // term = unary (('*' | '/' | '×' | '÷' | 'x' between numbers | implicit) unary)*
    private mutating func term() -> (function: Fn, isPercent: Bool)? {
        guard var f = unary() else { return nil }
        var isPercent = lastWasPercent
        while let c = peek() {
            let lhs = f
            if c == "*", pos + 1 < chars.count, chars[pos + 1] == "*" {
                break  // "**" is power
            } else if c == "*" || c == "×" || ((c == "x" || c == "X") && xIsTimes()) {
                pos += 1
                guard let rhs = unary() else { return nil }
                f = { lhs($0) * rhs($0) }
            } else if c == "/" || c == "÷" {
                pos += 1
                guard let rhs = unary() else { return nil }
                f = { lhs($0) / rhs($0) }
            } else if c == "(" || c == "√" || c == "π" || (c.isASCII && c.isLetter) {
                guard let rhs = unary() else { return nil }  // implicit: 2x, 3(4+1), 2pi
                f = { lhs($0) * rhs($0) }
            } else {
                break
            }
            isPercent = false
            operations += 1
        }
        return (f, isPercent)
    }

    /// "x" at `pos` means multiply in "4x4", "4 x 4" and "4 x (2+3)", and the variable in "2x" or "2x(x+1)".
    private func xIsTimes() -> Bool {
        var before = pos - 1
        while before >= 0, chars[before] == " " { before -= 1 }
        var after = pos + 1
        while after < chars.count, chars[after] == " " { after += 1 }
        guard before >= 0, after < chars.count else { return false }
        let prev = chars[before], next = chars[after]
        guard prev.isNumber || prev == ")" || prev == "%" else { return false }
        if next.isNumber || next == "." || next == "√" { return true }
        let spaced = before < pos - 1 && after > pos + 1
        return spaced && next == "("
    }

    // unary = ('-' | '+') unary | power
    private mutating func unary() -> Fn? {
        if let c = peek(), c == "-" || c == "+" {
            pos += 1
            guard let f = unary() else { return nil }
            return c == "-" ? { -f($0) } : f
        }
        return power()
    }

    // power = postfix (('^' | '**') unary)?   (right-associative)
    private mutating func power() -> Fn? {
        guard let base = postfix() else { return nil }
        guard let c = peek() else { return base }
        if c == "^" {
            pos += 1
        } else if c == "*", pos + 1 < chars.count, chars[pos + 1] == "*" {
            pos += 2
        } else {
            return base
        }
        guard let exponent = unary() else { return nil }
        operations += 1
        lastWasPercent = false
        return { pow(base($0), exponent($0)) }
    }

    // postfix = primary ('%' | '°' | '!')*
    private mutating func postfix() -> Fn? {
        guard var f = primary() else { return nil }
        lastWasPercent = false
        while let c = peek(), c == "%" || c == "°" || c == "!" {
            pos += 1
            let g = f
            switch c {
            case "%": f = { g($0) / 100 }
            case "°": f = { g($0) * .pi / 180 }
            default: f = { factorial(g($0)) }
            }
            operations += 1
            lastWasPercent = c == "%"
        }
        return f
    }

    // primary = number | '(' expression ')' | '√' postfix | name | function postfix
    private mutating func primary() -> Fn? {
        guard let c = peek() else { return nil }
        if c == "(" {
            pos += 1
            guard let f = expression(), peek() == ")" else { return nil }
            pos += 1
            return f
        }
        if c == "√" {
            pos += 1
            guard let f = postfix() else { return nil }
            operations += 1
            return { sqrt(f($0)) }
        }
        if c == "π" {
            pos += 1
            operations += 1
            return { _ in .pi }
        }
        if c.isASCII && c.isLetter {
            return name()
        }
        return number()
    }

    private mutating func name() -> Fn? {
        var word = ""
        while pos < chars.count, chars[pos].isASCII, chars[pos].isLetter {
            word.append(chars[pos])
            pos += 1
        }
        switch word.lowercased() {
        case "x":
            usesX = true
            return { $0 }
        case "pi":
            operations += 1
            return { _ in .pi }
        case "tau":
            operations += 1
            return { _ in 2 * .pi }
        case "e":
            return { _ in M_E }
        case "ans":
            guard let answer = Evaluator.lastAnswer else { return nil }
            usesAns = true
            return { _ in answer }
        case let name:
            guard let function = Parser.functions[name], let argument = postfix() else { return nil }
            if ["sin", "cos", "tan"].contains(name) { usesTrig = true }
            operations += 1
            return { function(argument($0)) }
        }
    }

    private static let functions: [String: (Double) -> Double] = [
        "sin": sin, "cos": cos, "tan": tan,
        "asin": asin, "acos": acos, "atan": atan,
        "arcsin": asin, "arccos": acos, "arctan": atan,
        "sinh": sinh, "cosh": cosh, "tanh": tanh,
        "sqrt": sqrt, "cbrt": cbrt,
        "ln": log, "log": log10, "lg": log10, "log2": log2,
        "exp": exp, "abs": abs,
        "floor": floor, "ceil": ceil, "round": { $0.rounded() },
    ]

    private mutating func number() -> Fn? {
        var digits = ""
        while pos < chars.count, chars[pos].isNumber || chars[pos] == "." || chars[pos] == "," {
            if chars[pos] != "," { digits.append(chars[pos]) }  // commas are thousands separators
            pos += 1
        }
        guard let value = Double(digits) else { return nil }
        return { _ in value }
    }
}

private func factorial(_ n: Double) -> Double {
    guard n >= 0, n <= 170 else { return .nan }
    return tgamma(n + 1)
}
