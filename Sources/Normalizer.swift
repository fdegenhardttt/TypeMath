import Foundation

/// Text rewritten from words into symbols ("five plus 15% of 80" -> "5 + 15%*80").
struct Normalized {
    var chars: [Character] = []
    /// For each character, its index in the original text; one extra entry for the end.
    var origin: [Int] = []
}

/// Rewrites natural phrasing into maths the parser understands, keeping a map back to the
/// original text so Tab replaces exactly what the user typed. Unknown words pass through unchanged.
enum Normalizer {
    private enum Kind { case word, number, space, other }

    private struct Token {
        let text: String
        let start: Int
        let kind: Kind
        var word: String? { kind == .word ? text.lowercased() : nil }
    }

    static func normalize(_ chars: [Character]) -> Normalized {
        var rewriter = Rewriter(tokens: tokenize(chars))
        rewriter.run()
        var result = rewriter.output
        result.origin.append(chars.count)
        return result
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens = [Token]()
        var i = 0
        while i < chars.count {
            let start = i
            let c = chars[i]
            let kind: Kind
            if Evaluator.isLetter(c) {
                while i < chars.count, Evaluator.isLetter(chars[i]) { i += 1 }
                kind = .word
            } else if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                while i < chars.count,
                      chars[i].isNumber || chars[i] == "."
                        || (chars[i] == "," && i + 1 < chars.count && chars[i + 1].isNumber) {
                    i += 1
                }
                kind = .number
            } else if c == " " {
                while i < chars.count, chars[i] == " " { i += 1 }
                kind = .space
            } else {
                i += 1
                kind = .other
            }
            tokens.append(Token(text: String(chars[start..<i]), start: start, kind: kind))
        }
        return tokens
    }

    // MARK: Vocabulary

    private static let small: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Double] = [
        "thousand": 1e3, "million": 1e6, "billion": 1e9, "trillion": 1e12,
    ]

    /// Word sequences that become a symbol, longest first.
    private static let phrases: [([String], String)] = [
        (["raised", "to", "the", "power", "of"], "^"),
        (["to", "the", "power", "of"], "^"),
        (["raised", "to"], "^"),
        (["multiplied", "by"], "*"),
        (["divided", "by"], "/"),
        (["square", "root", "of"], "√"),
        (["square", "root"], "√"),
        (["cube", "root", "of"], "cbrt "),
        (["take", "away"], "-"),
        (["a", "half", "of"], "0.5*"),
        (["half", "of"], "0.5*"),
        (["a", "quarter", "of"], "0.25*"),
        (["quarter", "of"], "0.25*"),
        (["a", "third", "of"], "(1/3)*"),
        (["third", "of"], "(1/3)*"),
        (["per", "cent"], "%"),
        (["percent"], "%"),
        (["pct"], "%"),
        (["plus"], "+"),
        (["minus"], "-"),
        (["times"], "*"),
        (["over"], "/"),
        (["squared"], "^2"),
        (["cubed"], "^3"),
        (["double"], "2*"),
        (["twice"], "2*"),
        (["triple"], "3*"),
    ]

    // MARK: Rewriting

    private struct Rewriter {
        let tokens: [Token]
        var output = Normalized()
        /// The last thing written was a value (number, ")", "%"), so "of" and "and" can be operators.
        private var afterValue = false
        /// Where the last number starts in `output`, for reordering "20% off 50".
        private var lastNumberStart: Int?

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func run() {
            var i = 0
            outer: while i < tokens.count {
                let token = tokens[i]
                if token.kind == .space {
                    emit(token)
                    i += 1
                    continue
                }
                if let end = aggregate(at: i) ?? verb(at: i) {
                    i = end + 1
                    continue
                }
                if let (value, end) = numberValue(at: i) {
                    lastNumberStart = output.chars.count
                    emit(literal(value), origin: token.start)
                    afterValue = true
                    i = end + 1
                    continue
                }
                if let word = token.word {
                    for (words, symbol) in phrases {
                        if let end = matchWords(words, at: i) {
                            emit(symbol, origin: token.start)
                            afterValue = symbol.hasPrefix("^") && symbol.count > 1 || symbol == "%"
                            i = end + 1
                            continue outer
                        }
                    }
                    if word == "of", afterValue {  // "15% of 80"
                        emit("*", origin: token.start)
                        afterValue = false
                        i += 1
                        continue
                    }
                    if word == "and", afterValue, let next = nextToken(after: i), isValue(at: next) {  // "3 and 4"
                        emit("+", origin: token.start)
                        afterValue = false
                        i += 1
                        continue
                    }
                    if word == "off", afterValue, let end = off(at: i) {  // "20% off 50"
                        i = end + 1
                        continue
                    }
                    if word == "more" || word == "less", afterValue, let end = than(at: i) {  // "5 more than 6"
                        i = end + 1
                        continue
                    }
                    if word == "less", afterValue, let next = nextToken(after: i), isValue(at: next) {  // "10 less 3"
                        emit("-", origin: token.start)
                        afterValue = false
                        i += 1
                        continue
                    }
                }
                if token.kind == .number { lastNumberStart = output.chars.count }
                emit(token)
                afterValue = token.kind == .number || token.text == ")" || token.text == "%"
                i += 1
            }
        }

        // MARK: Output

        private mutating func emit(_ token: Token) {
            for (offset, c) in token.text.enumerated() {
                output.chars.append(c)
                output.origin.append(token.start + offset)
            }
        }

        private mutating func emit(_ text: String, origin: Int) {
            for c in text {
                output.chars.append(c)
                output.origin.append(origin)
            }
        }

        private func literal(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        }

        // MARK: Lookahead

        private func nextToken(after i: Int) -> Int? {
            var j = i + 1
            while j < tokens.count, tokens[j].kind == .space { j += 1 }
            return j < tokens.count ? j : nil
        }

        /// If `words` appear from token `i` on (separated by spaces), the index of the last one.
        private func matchWords(_ words: [String], at i: Int) -> Int? {
            var j = i
            for (n, word) in words.enumerated() {
                guard j < tokens.count, tokens[j].word == word else { return nil }
                if n < words.count - 1 {
                    guard let next = nextToken(after: j) else { return nil }
                    j = next
                }
            }
            return j
        }

        private func isValue(at i: Int) -> Bool {
            let token = tokens[i]
            if token.kind == .number || token.text == "(" { return true }
            guard let word = token.word else { return false }
            return small[word] != nil || word == "a"
        }

        // MARK: Numbers

        /// A number written in words ("two hundred and fifty") or a numeral with a scale ("1.5 million").
        private func numberValue(at i: Int) -> (Double, Int)? {
            let token = tokens[i]
            if token.kind == .number {
                guard let value = Double(token.text.replacingOccurrences(of: ",", with: "")),
                      let next = nextToken(after: i), let word = tokens[next].word, let scale = scales[word]
                else { return nil }
                return (value * scale, next)
            }
            guard let first = token.word else { return nil }

            var total = 0.0, current = 0.0
            var j = i, end: Int?
            var sawWord = false, sawHundredOrScale = false
            if first == "a" {  // "a hundred", "a dozen"
                guard let next = nextToken(after: i), let word = tokens[next].word,
                      word == "hundred" || word == "dozen" || scales[word] != nil else { return nil }
                current = 1
                j = next
            }
            while j < tokens.count {
                let token = tokens[j]
                if let word = token.word {
                    if let value = small[word] {
                        current += value
                    } else if word == "hundred" {
                        current = max(current, 1) * 100
                        sawHundredOrScale = true
                    } else if word == "dozen" {
                        current = max(current, 1) * 12
                    } else if let scale = scales[word] {
                        total += max(current, 1) * scale
                        current = 0
                        sawHundredOrScale = true
                    } else if word == "and", sawHundredOrScale, let next = nextToken(after: j),
                              let nextWord = tokens[next].word, small[nextWord] != nil {
                        j = next
                        continue
                    } else {
                        break
                    }
                    sawWord = true
                    end = j
                } else if token.text == "-", j + 1 < tokens.count, let next = tokens[j + 1].word,
                          small[next] != nil, sawWord {  // "twenty-five"
                    j += 1
                    continue
                } else if token.kind != .space {
                    break
                }
                j += 1
            }
            guard sawWord, let end else { return nil }
            return (total + current, end)
        }

        /// A single number, as written in numerals or words, and the index of its last token.
        private func operand(at i: Int) -> (String, Int)? {
            if let (value, end) = numberValue(at: i) { return (literal(value), end) }
            if tokens[i].kind == .number { return (tokens[i].text.replacingOccurrences(of: ",", with: ""), i) }
            return nil
        }

        /// "average of 3, 4 and 5" -> "((3+4+5)/3)"; also sum, product, difference and quotient.
        private mutating func aggregate(at i: Int) -> Int? {
            guard let word = tokens[i].word, var j = nextToken(after: i) else { return nil }
            let operation: (separator: String, pairOnly: Bool)
            switch word {
            case "average", "mean": operation = ("+", false)
            case "sum": operation = ("+", false)
            case "product": operation = ("*", false)
            case "difference": operation = ("-", true)
            case "quotient", "ratio": operation = ("/", true)
            default: return nil
            }
            let isAverage = word == "average" || word == "mean"
            if let connector = tokens[j].word, connector == "of" || connector == "between" {
                guard let next = nextToken(after: j) else { return nil }
                j = next
            } else if !isAverage {
                return nil  // "the sum is…" is prose, "the sum of 5 and 6" is maths
            }

            var values = [String](), end = j
            while j < tokens.count, let (value, last) = operand(at: j) {
                values.append(value)
                end = last
                guard let next = nextToken(after: last),
                      tokens[next].text == "," || tokens[next].word == "and",
                      let afterSeparator = nextToken(after: next) else { break }
                j = afterSeparator
            }
            guard values.count >= 2, !operation.pairOnly || values.count == 2 else { return nil }
            let joined = values.joined(separator: operation.separator)
            emit(isAverage ? "((\(joined))/\(values.count))" : "(\(joined))", origin: tokens[i].start)
            afterValue = true
            return end
        }

        /// "subtract 3 from 10" -> "(10-3)", "add 5 to 3", "multiply 6 by 7", "divide 10 by 4".
        private mutating func verb(at i: Int) -> Int? {
            let forms: [String: (connector: String, operator: String, reversed: Bool)] = [
                "subtract": ("from", "-", true),
                "add": ("to", "+", false),
                "multiply": ("by", "*", false),
                "divide": ("by", "/", false),
            ]
            guard let word = tokens[i].word, let form = forms[word],
                  let firstStart = nextToken(after: i), let (first, firstEnd) = operand(at: firstStart),
                  let connector = nextToken(after: firstEnd), tokens[connector].word == form.connector,
                  let secondStart = nextToken(after: connector), let (second, secondEnd) = operand(at: secondStart)
            else { return nil }
            let (lhs, rhs) = form.reversed ? (second, first) : (first, second)
            emit("(\(lhs)\(form.operator)\(rhs))", origin: tokens[i].start)
            afterValue = true
            return secondEnd
        }

        /// "5 more than 6" -> "(6+5)", "3 less than 10" -> "(10-3)".
        private mutating func than(at i: Int) -> Int? {
            guard let start = lastNumberStart, let thanIndex = nextToken(after: i), tokens[thanIndex].word == "than",
                  let next = nextToken(after: thanIndex), let (base, end) = operand(at: next) else { return nil }
            let amount = String(output.chars[start...]).trimmingCharacters(in: .whitespaces)
            let origin = output.origin[start]
            output.chars.removeSubrange(start...)
            output.origin.removeSubrange(start...)
            emit("(\(base)\(tokens[i].word == "more" ? "+" : "-")\(amount))", origin: origin)
            afterValue = true
            return end
        }

        /// "20% off 50" -> "(50-20%)", which the parser reads as 50 minus 20% of 50.
        private mutating func off(at i: Int) -> Int? {
            guard let start = lastNumberStart, let next = nextToken(after: i) else { return nil }
            let amount: String, end: Int
            if tokens[next].kind == .number {
                amount = tokens[next].text
                end = next
            } else if let (value, last) = numberValue(at: next) {
                amount = literal(value)
                end = last
            } else {
                return nil
            }
            let discount = String(output.chars[start...]).trimmingCharacters(in: .whitespaces)
            let origin = output.origin[start]
            output.chars.removeSubrange(start...)
            output.origin.removeSubrange(start...)
            emit("(\(amount)-\(discount))", origin: origin)
            afterValue = true
            return end
        }
    }
}
