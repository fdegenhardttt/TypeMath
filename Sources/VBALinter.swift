import Foundation

struct VBAIssue: Equatable {
    enum Kind { case mistake, style }

    /// 1-based line number in the module.
    let line: Int
    let message: String
    let kind: Kind
    /// Identifies the rule and its subject, to spot the same mistake made twice.
    let key: String
}

/// Offline checks for common VBA mistakes. Strings and comments are ignored.
enum VBALinter {
    private struct Line {
        let number: Int
        /// The code with comments removed and string contents blanked ("" stays as two quotes).
        let code: String
        var lower: String { code.lowercased() }
        let hasUnclosedString: Bool
    }

    private struct Block {
        let kind: String     // "for", "if", "do", …
        let variable: String // the For variable, if any
        let line: Int
    }

    static func lint(_ module: String) -> [VBAIssue] {
        let lines = logicalLines(module)
        var issues = [VBAIssue]()
        issues += blockIssues(lines)
        for line in lines { issues += lineIssues(line) }
        issues += typoIssues(lines, module: module)
        issues += setIssues(lines)
        issues += undeclaredIssues(lines)
        issues += styleIssues(lines)
        return issues.sorted { ($0.line, $0.kind == .style ? 1 : 0) < ($1.line, $1.kind == .style ? 1 : 0) }
    }

    // MARK: Preparing lines

    /// Splits the module into lines, joins "_" continuations, strips comments and blanks out strings.
    private static func logicalLines(_ module: String) -> [Line] {
        let raw = module.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result = [Line]()
        var pending: (number: Int, code: String, unclosed: Bool)?
        for (index, text) in raw.enumerated() {
            let (code, unclosed) = stripped(text)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let continues = trimmed.hasSuffix(" _") || trimmed == "_"
            let piece = continues ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed
            if var open = pending {
                open.code += " " + piece
                open.unclosed = open.unclosed || unclosed
                pending = open
            } else {
                pending = (index + 1, piece, unclosed)
            }
            if !continues, let done = pending {
                result.append(Line(number: done.number, code: done.code, hasUnclosedString: done.unclosed))
                pending = nil
            }
        }
        if let done = pending { result.append(Line(number: done.number, code: done.code, hasUnclosedString: done.unclosed)) }
        return result
    }

    /// The line without its comment and with string contents removed; whether a string is left open.
    private static func stripped(_ text: String) -> (String, Bool) {
        var out = ""
        var inString = false
        for c in text {
            if inString {
                if c == "\"" { inString = false; out.append(c) }
                continue
            }
            if c == "\"" { inString = true; out.append(c); continue }
            if c == "'" { break }
            out.append(c)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "rem" || trimmed.lowercased().hasPrefix("rem ") { return ("", false) }
        return (out, inString)
    }

    private static func firstWords(_ line: Line, _ count: Int) -> [String] {
        Array(line.lower.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(count).map(String.init))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func capture(_ text: String, _ pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Blocks

    private static let procedurePattern = #"^(?:(?:public|private|friend)\s+)?(?:static\s+)?(sub|function|property)\b"#

    private static func opener(_ line: Line) -> Block? {
        let code = line.code
        if let variable = capture(code, #"^for\s+each\s+(\w+)"#) { return Block(kind: "for", variable: variable, line: line.number) }
        if let variable = capture(code, #"^for\s+(\w+)\s*="#) { return Block(kind: "for", variable: variable, line: line.number) }
        if matches(code, #"^if\b"#) {
            // "If x Then y" on one line is not a block.
            let afterThen = capture(code, #"\bthen\b(.*)$"#)?.trimmingCharacters(in: .whitespaces) ?? ""
            return afterThen.isEmpty ? Block(kind: "if", variable: "", line: line.number) : nil
        }
        if matches(code, #"^select\s+case\b"#) { return Block(kind: "select", variable: "", line: line.number) }
        if matches(code, #"^do\b"#) { return Block(kind: "do", variable: "", line: line.number) }
        if matches(code, #"^while\b"#) { return Block(kind: "while", variable: "", line: line.number) }
        if matches(code, #"^with\b"#) { return Block(kind: "with", variable: "", line: line.number) }
        if let kind = capture(code, procedurePattern) { return Block(kind: kind.lowercased(), variable: "", line: line.number) }
        return nil
    }

    /// The block kind a line closes, and the variable after Next if any.
    private static func closer(_ line: Line) -> (kind: String, variable: String, word: String)? {
        let code = line.code
        if matches(code, #"^next\b"#) { return ("for", capture(code, #"^next\s+(\w+)"#) ?? "", "Next") }
        if matches(code, #"^end\s+if\b"#) { return ("if", "", "End If") }
        if matches(code, #"^end\s+select\b"#) { return ("select", "", "End Select") }
        if matches(code, #"^loop\b"#) { return ("do", "", "Loop") }
        if matches(code, #"^wend\b"#) { return ("while", "", "Wend") }
        if matches(code, #"^end\s+with\b"#) { return ("with", "", "End With") }
        if matches(code, #"^end\s+sub\b"#) { return ("sub", "", "End Sub") }
        if matches(code, #"^end\s+function\b"#) { return ("function", "", "End Function") }
        if matches(code, #"^end\s+property\b"#) { return ("property", "", "End Property") }
        return nil
    }

    private static let closingWord = ["for": "Next", "if": "End If", "select": "End Select", "do": "Loop",
                                      "while": "Wend", "with": "End With", "sub": "End Sub",
                                      "function": "End Function", "property": "End Property"]
    private static let openingWord = ["for": "For", "if": "If", "select": "Select Case", "do": "Do", "while": "While",
                                      "with": "With", "sub": "Sub", "function": "Function", "property": "Property"]
    private static let procedures: Set<String> = ["sub", "function", "property"]

    private static func describe(_ block: Block) -> String {
        let name = openingWord[block.kind] ?? block.kind
        return block.variable.isEmpty ? name : "\(name) \(block.variable)"
    }

    private static func blockIssues(_ lines: [Line]) -> [VBAIssue] {
        var issues = [VBAIssue]()
        var stack = [Block]()

        func unclosed(_ blocks: ArraySlice<Block>, at line: Int) {
            for block in blocks.reversed() {
                issues.append(VBAIssue(line: line, message: "\(describe(block)) on line \(block.line) never got its \(closingWord[block.kind]!)",
                                       kind: .mistake, key: "unclosed-\(block.kind)"))
            }
        }

        for line in lines where !line.code.isEmpty {
            if let close = closer(line) {
                if procedures.contains(close.kind), stack.lastIndex(where: { $0.kind == close.kind }) == nil,
                   let procIndex = stack.lastIndex(where: { procedures.contains($0.kind) }) {
                    let proc = stack[procIndex]  // "End Sub" closing a Function, or the other way round
                    issues.append(VBAIssue(line: line.number,
                                           message: "\(close.word) closes the \(describe(proc)) from line \(proc.line): use \(closingWord[proc.kind]!)",
                                           kind: .mistake, key: "wrong-end"))
                    unclosed(stack[(procIndex + 1)...], at: line.number)
                    stack.removeSubrange(procIndex...)
                    continue
                }
                guard let matchIndex = stack.lastIndex(where: { $0.kind == close.kind }) else {
                    let what = close.kind == "for" ? "For" : (openingWord[close.kind] ?? close.kind)
                    issues.append(VBAIssue(line: line.number, message: "\(close.word) without a \(what) to close",
                                           kind: .mistake, key: "orphan-\(close.kind)"))
                    continue
                }
                let open = stack[matchIndex]
                if procedures.contains(close.kind) {
                    unclosed(stack[(matchIndex + 1)...], at: line.number)
                } else if matchIndex < stack.count - 1 {
                    let inner = stack.last!
                    issues.append(VBAIssue(line: line.number,
                                           message: "\(close.word) closes the \(describe(open)) from line \(open.line), but \(describe(inner)) from line \(inner.line) is still open",
                                           kind: .mistake, key: "crossed-\(close.kind)"))
                }
                if close.kind == "for", !close.variable.isEmpty, close.variable.lowercased() != open.variable.lowercased() {
                    issues.append(VBAIssue(line: line.number, message: "Next \(close.variable) doesn't match For \(open.variable)",
                                           kind: .mistake, key: "next-mismatch"))
                }
                stack.removeSubrange(matchIndex...)
                continue
            }
            if let block = opener(line) {
                if procedures.contains(block.kind), let previous = stack.first(where: { procedures.contains($0.kind) }) {
                    issues.append(VBAIssue(line: line.number,
                                           message: "\(describe(block)) starts before the \(describe(previous)) from line \(previous.line) has ended",
                                           kind: .mistake, key: "nested-procedure"))
                    stack.removeAll()
                }
                stack.append(block)
                continue
            }
            let lower = line.lower
            if matches(lower, #"^(else|elseif)\b"#), stack.last?.kind != "if" {
                issues.append(VBAIssue(line: line.number, message: "\(lower.hasPrefix("elseif") ? "ElseIf" : "Else") outside an If block",
                                       kind: .mistake, key: "orphan-else"))
            }
            if matches(lower, #"^case\b"#), stack.last?.kind != "select" {
                issues.append(VBAIssue(line: line.number, message: "Case outside a Select Case", kind: .mistake, key: "orphan-case"))
            }
        }
        return issues
    }

    // MARK: Single lines

    private static func lineIssues(_ line: Line) -> [VBAIssue] {
        var issues = [VBAIssue]()
        let lower = line.lower
        if line.hasUnclosedString {
            issues.append(VBAIssue(line: line.number, message: "This string is missing its closing \"", kind: .mistake, key: "string"))
        }
        if matches(lower, #"^(if|elseif)\b"#), !matches(lower, #"\bthen\b"#) {
            issues.append(VBAIssue(line: line.number, message: "\(lower.hasPrefix("elseif") ? "ElseIf" : "If") needs a Then at the end",
                                   kind: .mistake, key: "then"))
        }
        let open = line.code.filter { $0 == "(" }.count, close = line.code.filter { $0 == ")" }.count
        if open > close {
            issues.append(VBAIssue(line: line.number, message: "Missing \(open - close == 1 ? "a )" : "\(open - close) )s")",
                                   kind: .mistake, key: "brackets"))
        } else if close > open {
            issues.append(VBAIssue(line: line.number, message: "One ) too many", kind: .mistake, key: "brackets"))
        }
        return issues
    }

    // MARK: Typos

    private static let statementKeywords = [
        "dim", "set", "next", "end", "loop", "wend", "for", "each", "if", "then", "else", "elseif", "with", "select",
        "case", "sub", "function", "exit", "call", "const", "private", "public", "static", "option", "explicit",
        "redim", "preserve", "goto", "resume", "while", "do", "until", "debug", "property", "msgbox",
    ]

    /// Real VBA statements and common objects that start lines, so they're never taken for typos.
    private static let validStarts: Set<String> = [
        "beep", "stop", "kill", "load", "unload", "open", "close", "print", "input", "get", "put", "seek", "lock",
        "unlock", "name", "date", "time", "erase", "randomize", "event", "enum", "type", "implements", "declare",
        "let", "lset", "rset", "error", "on", "mid", "width", "write", "reset", "chdir", "mkdir", "rmdir", "filecopy",
        "sendkeys", "appactivate", "shell", "doevents", "application", "worksheets", "range", "cells", "activesheet",
        "activeworkbook", "thisworkbook", "sheets", "workbooks", "selection", "rem", "global", "friend", "attribute",
    ]

    /// Optimal string alignment distance (a swap of two neighbours counts as one edit).
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    private static func typoIssues(_ lines: [Line], module: String) -> [VBAIssue] {
        let known = Set(declaredNames(lines).map { $0.lowercased() })
        var issues = [VBAIssue]()
        for line in lines {
            guard let word = capture(line.code, #"^([A-Za-z]+)"#) else { continue }
            let lower = word.lowercased()
            let rest = line.code.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            guard lower.count >= 3, !statementKeywords.contains(lower), !validStarts.contains(lower), !known.contains(lower),
                  !rest.hasPrefix("="), !rest.hasPrefix("."), !rest.hasPrefix("("), !rest.hasPrefix(":") else { continue }
            let limit = lower.count >= 7 ? 2 : 1
            if let keyword = statementKeywords.filter({ abs($0.count - lower.count) <= limit })
                .min(by: { distance($0, lower) < distance($1, lower) }),
               distance(keyword, lower) <= limit {
                let suggestion = keyword == "msgbox" ? "MsgBox" : keyword.prefix(1).uppercased() + keyword.dropFirst()
                issues.append(VBAIssue(line: line.number, message: "\(word)? Did you mean \(suggestion)?",
                                       kind: .mistake, key: "typo-\(keyword)"))
            }
        }
        return issues
    }

    // MARK: Set

    private static let objectTypes: Set<String> = [
        "worksheet", "workbook", "range", "object", "collection", "dictionary", "chart", "chartobject", "shape",
        "listobject", "pivottable", "window", "name", "comment", "hyperlink", "scripting.dictionary",
    ]

    private static func declaredTypes(_ lines: [Line]) -> [String: String] {
        var types = [String: String]()
        for line in lines {
            guard let regex = try? NSRegularExpression(pattern: #"(\w+)\s+As\s+(?:New\s+)?([\w.]+)"#, options: .caseInsensitive)
            else { continue }
            for match in regex.matches(in: line.code, range: NSRange(line.code.startIndex..., in: line.code)) {
                guard let name = Range(match.range(at: 1), in: line.code), let type = Range(match.range(at: 2), in: line.code)
                else { continue }
                types[line.code[name].lowercased()] = line.code[type].lowercased()
            }
        }
        return types
    }

    private static func setIssues(_ lines: [Line]) -> [VBAIssue] {
        let types = declaredTypes(lines)
        var issues = [VBAIssue]()
        for line in lines {
            guard !matches(line.code, #"^(set|let|dim|const|private|public|static|for|if|elseif|while|do|loop|select|case)\b"#),
                  let name = capture(line.code, #"^(\w+)\s*=\s*(.+)$"#, group: 1),
                  let value = capture(line.code, #"^(\w+)\s*=\s*(.+)$"#, group: 2) else { continue }
            let alwaysObject = matches(value, #"^(new\s|createobject\s*\(|(this|active)workbook\b|activesheet\b|(work)?sheets\s*\(|workbooks\s*\()"#)
            let isObjectVariable = types[name.lowercased()].map(objectTypes.contains) ?? false
            if alwaysObject || isObjectVariable {
                issues.append(VBAIssue(line: line.number, message: "Objects need Set: Set \(name) = …", kind: .mistake, key: "set"))
            }
        }
        return issues
    }

    // MARK: Option Explicit

    private static func declaredNames(_ lines: [Line]) -> [String] {
        var names = [String]()
        let patterns = [
            #"^(?:dim|private|public|static|const|global|redim(?:\s+preserve)?)\s+(.+)$"#,
            #"^(?:(?:public|private|friend)\s+)?(?:static\s+)?(?:sub|function|property\s+(?:get|let|set))\s+(\w+)"#,
        ]
        for line in lines {
            if let list = capture(line.code, patterns[0]) {
                for part in list.split(separator: ",") {
                    let words = part.split(separator: " ").map(String.init).filter { !["const", "withevents"].contains($0.lowercased()) }
                    if let first = words.first?.split(separator: "(").first { names.append(String(first)) }
                }
            }
            if let name = capture(line.code, patterns[1]) { names.append(name) }
            if let params = capture(line.code, procedurePattern + #"\s+\w+\s*\(([^)]*)\)"#, group: 2) {
                for part in params.split(separator: ",") {
                    let words = part.split(separator: " ").map(String.init)
                        .filter { !["optional", "byval", "byref", "paramarray"].contains($0.lowercased()) }
                    if let first = words.first?.split(separator: "(").first { names.append(String(first)) }
                }
            }
        }
        return names
    }

    private static let builtIns: Set<String> = ["me", "err", "application", "activesheet", "activecell", "selection",
                                                "debug", "true", "false", "nothing", "empty", "null"]

    private static func undeclaredIssues(_ lines: [Line]) -> [VBAIssue] {
        guard lines.contains(where: { matches($0.code, #"^option\s+explicit\b"#) }) else { return [] }
        let declared = Set(declaredNames(lines).map { $0.lowercased() })
        var reported = Set<String>()
        var issues = [VBAIssue]()
        for line in lines {
            let name = capture(line.code, #"^for\s+(?:each\s+)?(\w+)"#)
                ?? capture(line.code, #"^(?:set\s+|let\s+)?(\w+)\s*="#)
            guard let name, !declared.contains(name.lowercased()), !builtIns.contains(name.lowercased()),
                  !statementKeywords.contains(name.lowercased()), reported.insert(name.lowercased()).inserted else { continue }
            issues.append(VBAIssue(line: line.number, message: "\(name) isn't declared (Option Explicit is on): add Dim \(name)",
                                   kind: .mistake, key: "undeclared"))
        }
        return issues
    }

    // MARK: Style

    private static func styleIssues(_ lines: [Line]) -> [VBAIssue] {
        var issues = [VBAIssue]()
        for line in lines {
            if matches(line.code, #"\.(select|activate)\s*$"#) {
                issues.append(VBAIssue(line: line.number, message: "Tip: you rarely need .Select, work with the range directly",
                                       kind: .style, key: "select"))
            }
            if let name = capture(line.code, #"^dim\s+(\w*row\w*|r)\s+as\s+integer\b"#) {
                issues.append(VBAIssue(line: line.number, message: "Tip: use Long for \(name): Integer stops at 32,767",
                                       kind: .style, key: "integer-rows"))
            }
        }
        return issues
    }
}
