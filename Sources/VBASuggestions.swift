import Foundation

/// A suggestion to insert at the caret.
struct VBASuggestion: Equatable {
    /// What appears in the popup.
    let label: String
    /// Replaces the last `replacing` characters before the caret, then inserts `text`.
    let text: String
    let replacing: Int
}

/// Offline VBA suggestions: block snippets, matching closers, names from the module and common Excel idioms.
enum VBASuggestions {
    static let maxCount = 4

    /// Suggestions for the caret at `caret` (a character offset) in `module`.
    static func suggest(module: String, caret: Int) -> [VBASuggestion] {
        let chars = Array(module)
        let caret = min(max(caret, 0), chars.count)
        let lineStart = chars[..<caret].lastIndex(of: "\n").map { $0 + 1 } ?? 0
        let lineBefore = String(chars[lineStart..<caret])
        let lineEnd = chars[caret...].firstIndex(of: "\n") ?? chars.count
        guard chars[caret..<lineEnd].allSatisfy({ $0 == " " || $0 == "\r" }) else { return [] }  // only at line end

        let indent = String(lineBefore.prefix { $0 == " " || $0 == "\t" })
        let typed = String(lineBefore.dropFirst(indent.count))
        let before = String(chars[..<lineStart])

        if typed.isEmpty {
            return closer(before: before, indent: indent).map { [$0] } ?? []
        }
        guard !typed.hasSuffix("."), !isInsideStringOrComment(typed) else { return [] }  // leave members to the editor

        var results = snippets(for: typed, indent: indent)
        let word = trailingWord(typed)
        if word.count >= 2 {
            results += idioms(for: word, isWholeLine: word == typed)
            results += names(in: module, excludingLine: lineStart..<lineEnd, prefix: word)
        }
        var seen = Set<String>()
        return Array(results.filter { seen.insert($0.text).inserted }.prefix(maxCount))
    }

    // MARK: Snippets

    private static let indentUnit = "    "

    /// Block templates offered when the line so far is just the keyword, e.g. "for" or "if".
    private static func snippets(for typed: String, indent: String) -> [VBASuggestion] {
        let key = typed.lowercased()
        let inner = indentUnit  // template lines are relative; the current indent is added below
        let templates: [(keys: [String], label: String, lines: [String])] = [
            (["sub"], "Sub … End Sub", ["Sub Macro1()", inner, "End Sub"]),
            (["function"], "Function … End Function", ["Function Calculate() As Double", inner, "End Function"]),
            (["for"], "For i = 1 To 10 … Next i", ["For i = 1 To 10", inner, "Next i"]),
            (["for each", "foreach"], "For Each cell In Range … Next", ["For Each cell In Range(\"A1:A10\")", inner, "Next cell"]),
            (["if"], "If … Then … End If", ["If condition Then", inner, "End If"]),
            (["ifelse", "if else"], "If … Else … End If", ["If condition Then", inner, "Else", inner, "End If"]),
            (["select", "select case"], "Select Case … End Select",
             ["Select Case value", "\(indentUnit)Case 1", inner + indentUnit, "\(indentUnit)Case Else", inner + indentUnit, "End Select"]),
            (["do", "do while"], "Do While … Loop", ["Do While condition", inner, "Loop"]),
            (["while"], "While … Wend", ["While condition", inner, "Wend"]),
            (["with"], "With … End With", ["With ActiveSheet", inner, "End With"]),
            (["on error", "onerror"], "On Error GoTo handler", ["On Error GoTo ErrorHandler", inner, "Exit Sub", "ErrorHandler:",
                                                               inner + "MsgBox \"Error \" & Err.Number & \": \" & Err.Description"]),
        ]
        return templates.filter { $0.keys.contains(key) }.map { template in
            let body = template.lines.enumerated().map { index, line in
                index == 0 ? line : indent + line
            }.joined(separator: "\n")
            return VBASuggestion(label: template.label, text: body, replacing: typed.count)
        }
    }

    // MARK: Closers

    private static let openers: [(pattern: String, closer: (String) -> String)] = [
        (#"^for\s+each\s+(\w+)"#, { "Next \($0)" }),
        (#"^for\s+(\w+)\s*="#, { "Next \($0)" }),
        (#"^if\b.*\bthen\s*(?:'.*)?$"#, { _ in "End If" }),
        (#"^select\s+case\b"#, { _ in "End Select" }),
        (#"^do\b"#, { _ in "Loop" }),
        (#"^while\b"#, { _ in "Wend" }),
        (#"^with\b"#, { _ in "End With" }),
        (#"^(?:(?:public|private|friend)\s+)?(?:static\s+)?sub\b"#, { _ in "End Sub" }),
        (#"^(?:(?:public|private|friend)\s+)?(?:static\s+)?function\b"#, { _ in "End Function" }),
    ]

    private static let closerPatterns = [
        #"^next\b"#, #"^end\s+if\b"#, #"^end\s+select\b"#, #"^loop\b"#, #"^wend\b"#, #"^end\s+with\b"#,
        #"^end\s+sub\b"#, #"^end\s+function\b"#,
    ]

    /// The closer for the innermost block still open above the caret, at that block's indentation.
    private static func closer(before: String, indent: String) -> VBASuggestion? {
        var stack: [(closer: String, indent: String)] = []
        for raw in before.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let code = line.trimmingCharacters(in: .whitespaces)
            let lower = code.lowercased()
            if lower.isEmpty || lower.hasPrefix("'") { continue }
            if closerPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            for opener in openers {
                guard let match = lower.range(of: opener.pattern, options: .regularExpression) else { continue }
                // Single-line "If x Then y" has code after Then: not a block.
                if opener.closer("") == "End If", lower.range(of: #"\bthen\s*\S"#, options: .regularExpression) != nil,
                   lower.range(of: #"\bthen\s*'"#, options: .regularExpression) == nil { break }
                let name = capture(code, pattern: opener.pattern, near: match) ?? ""
                stack.append((opener.closer(name), String(line.prefix { $0 == " " || $0 == "\t" })))
                break
            }
        }
        guard let open = stack.last, indent.count <= open.indent.count + indentUnit.count else { return nil }
        let text = open.indent + open.closer
        return VBASuggestion(label: open.closer, text: text, replacing: indent.count)
    }

    /// The variable name in "For i = …" / "For Each cell …", with the user's own capitalisation.
    private static func capture(_ code: String, pattern: String, near _: Range<String.Index>) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: code) else { return nil }
        return String(code[range])
    }

    // MARK: Names and idioms

    private static func trailingWord(_ typed: String) -> String {
        String(typed.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
    }

    private static func isInsideStringOrComment(_ typed: String) -> Bool {
        typed.filter { $0 == "\"" }.count % 2 == 1 || typed.contains("'")
    }

    private static let idiomTable: [(keys: [String], text: String)] = [
        (["lastrow"], "lastRow = Cells(Rows.Count, \"A\").End(xlUp).Row"),
        (["lastcol", "lastcolumn"], "lastCol = Cells(1, Columns.Count).End(xlToLeft).Column"),
        (["ws", "setws"], "Set ws = ThisWorkbook.Worksheets(\"Sheet1\")"),
        (["wb", "setwb"], "Set wb = ThisWorkbook"),
        (["msgbox"], "MsgBox \"Done\""),
        (["screenupdating", "application"], "Application.ScreenUpdating = False"),
        (["dimws"], "Dim ws As Worksheet"),
        (["dimi"], "Dim i As Long"),
        (["optionexplicit", "option"], "Option Explicit"),
        (["inputbox"], "answer = InputBox(\"Enter a value\")"),
    ]

    /// Whole-line Excel idioms, offered only when the word is the whole line so far.
    private static func idioms(for word: String, isWholeLine: Bool) -> [VBASuggestion] {
        guard isWholeLine else { return [] }
        let key = word.lowercased()
        return idiomTable.filter { $0.keys.contains(where: { $0.hasPrefix(key) }) }
            .map { VBASuggestion(label: $0.text, text: $0.text, replacing: word.count) }
    }

    private static let declarationPatterns = [
        #"(?im)^\s*(?:dim|private|public|static|const|global)\s+(?:const\s+)?(\w+)"#,
        #"(?im),\s*(\w+)\s+as\b"#,
        #"(?im)^\s*(?:(?:public|private|friend)\s+)?(?:static\s+)?(?:sub|function|property\s+(?:get|let|set))\s+(\w+)"#,
        #"(?im)^\s*(?:(?:public|private|friend)\s+)?(?:static\s+)?(?:sub|function)\s+\w+\s*\(([^)]*)\)"#,
        #"(?im)^\s*for\s+(?:each\s+)?(\w+)"#,
    ]

    private static let keywords: Set<String> = [
        "as", "byval", "byref", "optional", "paramarray", "dim", "set", "const", "sub", "function", "end", "next",
        "each", "in", "to", "step", "then", "else", "if", "loop", "with", "new", "private", "public", "static",
    ]

    /// Names declared in the module that start with `prefix` (but aren't exactly it).
    private static func names(in module: String, excludingLine line: Range<Int>, prefix: String) -> [VBASuggestion] {
        var chars = Array(module)
        chars.removeSubrange(line.clamped(to: 0..<chars.count))
        let text = String(chars)
        var found = [String]()
        for pattern in declarationPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let captured = String(text[range])
                // Parameter lists: "ByVal x As Long, y As String" -> x, y
                let candidates = captured.contains(" ") || captured.contains(",")
                    ? captured.split(separator: ",").compactMap { part in
                        part.split(separator: " ").map(String.init).first { !keywords.contains($0.lowercased()) }
                    }
                    : [captured]
                found += candidates
            }
        }
        let lowerPrefix = prefix.lowercased()
        var seen = Set<String>()
        return found
            .filter { $0.lowercased().hasPrefix(lowerPrefix) && $0.lowercased() != lowerPrefix }
            .filter { !keywords.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
            .map { VBASuggestion(label: $0, text: $0, replacing: prefix.count) }
    }
}
