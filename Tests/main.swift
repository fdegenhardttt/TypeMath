// Run with: ./test.sh
import Foundation
var failures = 0

// Fixed inputs so results don't depend on the day, locale or live exchange rates.
var fixedNow = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 20, hour: 12).date!
Evaluator.now = { fixedNow }
Evaluator.locale = Locale(identifier: "en_GB")
Currency.rates = ["EUR": 1, "USD": 1.25, "GBP": 0.8, "JPY": 160]

/// `replaced` is the text left after Tab swaps the equation for its answer.
/// Expects the text to be graphed; `samples` are (x, y) points the graph must pass through.
func checkGraph(_ text: String, _ samples: [(Double, Double)] = [], line: Int = #line) {
    guard let match = Evaluator.match(in: text), match.answer == nil, let graph = match.graph else {
        print("FAIL line \(line): \"\(text)\" was not graphed")
        failures += 1
        return
    }
    for (x, y) in samples where abs(graph.function(x) - y) > 1e-9 {
        print("FAIL line \(line): f(\(x)) = \(graph.function(x)), expected \(y)")
        failures += 1
    }
}

func check(_ text: String, _ expected: String?, replaced: String? = nil, line: Int = #line) {
    let match = Evaluator.match(in: text)
    if match?.answer != expected {
        print("FAIL line \(line): \"\(text)\" -> \(match?.answer ?? "nil"), expected \(expected ?? "nil")")
        failures += 1
    }
    if let replaced, let match {
        let got = String(text.dropLast(match.length)) + (match.answer ?? "")
        if got != replaced {
            print("FAIL line \(line): replacing gave \"\(got)\", expected \"\(replaced)\"")
            failures += 1
        }
    }
}

check("4*4 = ", "16", replaced: "16")
check("4*4=", "16", replaced: "16")
check("so the total is 12+30 =", "42", replaced: "so the total is 42")
check("(2+3)^2 = ", "25")
check("2**10 =", "1024")
check("10/4 =", "2.5")
check("1/3 =", "0.3333333333")
check("1,000 x 3 =", "3000")
check("7 × 6 =", "42")
check("9 ÷ 3 =", "3")
check("√16 + 1 =", "5")
check("2(3+4) =", "14")
check("-2^2 =", "-4")
check("box 4+4 =", "8", replaced: "box 8")
check("a = 4*4 = 16 * 2 =", "32", replaced: "a = 4*4 = 32")
check("0.1+0.2 =", "0.3")
check("5 - -3 =", "8")

// Percent, calculator-style
check("200*15% =", "30")
check("200 + 10% =", "220")
check("200 - 10% =", "180")
check("50% =", "0.5")
check("10% + 5 =", "5.1")
check("(100 + 20%) * 2 =", "240")

// Unit conversion
check("5 km in miles =", "3.1069 miles", replaced: "3.1069 miles")
check("it's 5km to mi = ", "3.1069 mi", replaced: "it's 3.1069 mi")
check("180 lb in kg =", "81.6466 kg")
check("350 F in C =", "176.6667 C")
check("100 °c to °f =", "212 °f")
check("6 ft in in =", "72 in")
check("2*3 m in cm =", "600 cm")
check("1.5 hours in min =", "90 min")
check("60 mph in km/h =", "96.5606 km/h")
check("5 km in kg =", nil)
check("5 apples in boxes =", nil)

check("6 ft in in =", "72 in")
check("1 acre in m2 =", "4046.8564 m2")
check("2 kwh in kj =", "7200 kj")
check("1 atm in psi =", "14.6959 psi")
check("180 deg in rad =", "3.1416 rad")
check("1 GiB in MB =", "1073.7418 MB")
check("100 mbps in mb/s =", "12.5 mb/s")
check("3 cups in ml =", "709.7647 ml")
check("1 ly in km =", "9460730472580.8 km")
check("5 kcal in kj =", "20.92 kj")
check("1 pa in kg =", nil)

// Functions and constants
check("sqrt(16) =", "4")
check("sin(pi/2) =", "1")
check("sin(90°) =", "1")
check("cos(pi) =", "-1")
check("sin(pi) =", "0")
check("2pi =", "6.2831853072")
check("ln(e) =", "1")
check("log(1000) =", "3")
check("5! =", "120")
check("abs(-3) + 1 =", "4")
check("the area is pi*3^2 =", "28.2743338823", replaced: "the area is 28.2743338823")
check("4x4 =", "16")
check("4 x (2+3) =", "20")
check("2 x 3 x 4 =", "24")

// Graphs
checkGraph("x^2 =", [(3, 9), (-2, 4)])
checkGraph("y = 2x + 1 =", [(0, 1), (2, 5)])
checkGraph("f(x) = sin(x) =", [(0, 0)])
checkGraph("2x(x+1) =", [(1, 4)])
checkGraph("x^2 - 4x + 3 =", [(1, 0), (3, 0)])
checkGraph("1/x =", [(2, 0.5)])
checkGraph("what is ln(x) =", [(1, 0)])

// Live graphs while typing a definition, no trailing "="
checkGraph("f(x) = x", [(3, 3)])
checkGraph("f(x) = x^2 + 1", [(2, 5)])
checkGraph("so g(x) = sin(x) ", [(0, 0)])
checkGraph("y = 2x - 1", [(1, 1)])
check("f(x) = x^", nil)
check("f(x) = 4", nil)
check("may = x", nil)
check("y = 2 + 2", nil)

// Should not trigger
check("2024 =", nil)
check("-5 =", nil)
check("x = ", nil)
check("1/0 =", nil)
check("4*4", nil)
check("4*4 = 1", nil)
check("(2+3 =", "5", replaced: "(5")
check("hello =", nil)
check("pix + 2 =", nil)
check("it is what it is =", nil)

// Natural language
check("what is 5 plus 3 =", "8", replaced: "8")
check("what's 15% of 80?", "12", replaced: "12")
check("so what is 15 percent of 80?", "12", replaced: "so 12")
check("15 percent of 80 =", "12")
check("20% off 50 =", "40", replaced: "40")
check("twenty percent off fifty =", "40")
check("half of 40 =", "20")
check("a quarter of 200 =", "50")
check("double 12 =", "24")
check("twice 7 =", "14")
check("10 divided by 4 =", "2.5")
check("6 multiplied by 7 =", "42")
check("2 to the power of 10 =", "1024")
check("5 squared =", "25")
check("3 cubed =", "27")
check("square root of 81 =", "9")
check("cube root of 27 =", "3")
check("100 minus 1 =", "99")
check("12 over 4 =", "3")
check("3 and 4 =", "7")
check("two hundred and fifty plus 1 =", "251")
check("twenty-five times four =", "100")
check("1.5 million / 3 =", "500000")
check("a dozen times 3 =", "36")
check("average of 3, 4 and 5 =", "4")
check("mean of 10 and 20 =", "15")
check("five km in miles =", "3.1069 miles")
check("5 plus 6 =", "11")
check("add 5 and 6 =", "11")
check("the sum of 5 and 6 =", "11")
check("sum of 1, 2 and 3 =", "6")
check("product of 3 and 4 =", "12")
check("the product of 2, 3 and 4 =", "24")
check("difference between 10 and 3 =", "7")
check("the difference of 10 and 3 =", "7")
check("quotient of 10 and 4 =", "2.5")
check("10 less 3 =", "7")
check("subtract 3 from 10 =", "7", replaced: "7")
check("add 5 to 3 =", "8")
check("multiply 6 by 7 =", "42")
check("divide 10 by 4 =", "2.5")
check("5 more than 6 =", "11")
check("3 less than 10 =", "7")
check("twenty less than one hundred =", "80")
check("average of 1 million and 3 million =", "2000000")
check("the total is 12+30 =", "42")
check("the sum is 12+30 =", "42")
check("is it 5 plus 3?", nil)
check("I paid 5 plus tax =", nil)
check("calculate 2 + 2 =", "4", replaced: "4")

// ans
Evaluator.lastAnswer = 16
check("ans * 2 =", "32")
Evaluator.lastAnswer = nil
check("ans * 2 =", nil)

// Number format
Evaluator.options.groupThousands = true
check("1000 * 1000 =", "1,000,000")
check("1,000,000 + 1 =", "1,000,001")
Evaluator.options.groupThousands = false
Evaluator.options.decimals = 2
check("1/3 =", "0.33")
check("10/4 =", "2.5")
Evaluator.options.decimals = nil

// Dates (today is Fri 20 Nov 2026)
check("today + 30 days =", "Sun, 20 Dec 2026", replaced: "Sun, 20 Dec 2026")
check("today - 1 week =", "Fri, 13 Nov 2026")
check("tomorrow + 2 weeks =", "Sat, 5 Dec 2026")
check("today plus thirty days =", "Sun, 20 Dec 2026")
check("3 weeks from 1 dec =", "Tue, 22 Dec 2026")
check("10 days ago =", "Tue, 10 Nov 2026")
check("days until 25 dec =", "35 days", replaced: "35 days")
check("so, days until 25 dec =", "35 days", replaced: "so, 35 days")
check("days until 25/12 =", "35 days")
check("days until 1 jan =", "42 days")
check("days since 1 sep =", "80 days")
check("weeks until 25 dec =", "5 weeks")
check("days between 1 jan 2026 and 1 mar 2026 =", "59 days")
check("days until friday =", "7 days")
check("days until 2027-01-01 =", "42 days")
check("days until tomorrow =", "1 day")

// Currency (fixed rates: 1 EUR = 1.25 USD = 0.8 GBP = 160 JPY)
check("100 usd in eur =", "80.00 EUR", replaced: "80.00 EUR")
check("$100 in eur =", "80.00 EUR")
check("€50 to $ =", "$62.50")
check("50€ to £ =", "£40.00")
check("10 pounds in yen =", "2000.00 yen")
check("5 pounds in kg =", "2.268 kg")
check("100 dollars in euros =", "80.00 euros")
check("100 usd in xyz =", nil)

// Selections
func checkSelection(_ text: String, _ expected: String?, line: Int = #line) {
    let got = Evaluator.selectionMatch(text)
    let answer = got?.answer ?? (got?.graph != nil ? "graph" : nil)
    if answer != expected {
        print("FAIL line \(line): selection \"\(text)\" -> \(answer ?? "nil"), expected \(expected ?? "nil")")
        failures += 1
    }
}
checkSelection("12*7", "84")
checkSelection(" 12*7 ", "84")
checkSelection("15% of 80", "12")
checkSelection("what's 15% of 80?", "12")
checkSelection("5 km in miles", "3.1069 miles")
checkSelection("x^2", "graph")
checkSelection("f(x) = x^2", "graph")
checkSelection("2024", nil)
checkSelection("the total is 12*7", nil)
checkSelection("hello", nil)

// History
func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL line \(line): \(message)"); failures += 1 }
}
let suite = "typemath.tests.\(UUID().uuidString)"
let store = UserDefaults(suiteName: suite)!
let history = History(defaults: store)
history.add(question: "4*4 =", answer: "16")
history.add(question: "4*4", answer: "16")
expect(history.entries.map(\.question) == ["4*4"], "same question listed once, without the =")
history.add(question: "what's 15% of 80?", answer: "12")
history.add(question: "4*4 = ", answer: "16")
expect(history.entries.map(\.question) == ["4*4", "what's 15% of 80"], "repeat moves to the top")
expect(History(defaults: store).entries.map(\.answer) == ["16", "12"], "history is saved")
for n in 0..<150 { history.add(question: "\(n)+1", answer: "\(n + 1)") }
expect(history.entries.count == History.limit, "history is capped")
history.clear()
expect(History(defaults: store).entries.isEmpty, "clear is saved")
store.removePersistentDomain(forName: suite)

// VBA built-in suggestions. "|" marks the caret.
func vba(_ module: String) -> [VBASuggestion] {
    let caret = module.distance(from: module.startIndex, to: module.firstIndex(of: "|")!)
    return VBASuggestions.suggest(module: module.replacingOccurrences(of: "|", with: ""), caret: caret)
}
func checkVBA(_ module: String, first expected: String?, line: Int = #line) {
    let got = vba(module).first?.text
    if got != expected {
        print("FAIL line \(line): VBA \(module.debugDescription) -> \(got.debugDescription), expected \(expected.debugDescription)")
        failures += 1
    }
}
checkVBA("for|", first: "For i = 1 To 10\n    \nNext i")
checkVBA("Sub Test()\n    if|", first: "If condition Then\n        \n    End If")
checkVBA("Sub Test()\n    select|", first: "Select Case value\n        Case 1\n            \n        Case Else\n            \n    End Select")
checkVBA("Sub Test()\n    For i = 1 To 10\n        x = i\n|", first: "    Next i")
checkVBA("Sub Test()\n    For i = 1 To 10\n        x = i\n        |", first: "    Next i")
checkVBA("Sub Test()\n    For Each c In Range(\"A1:A3\")\n        |", first: "    Next c")
checkVBA("Sub Test()\n    If x > 1 Then\n        y = 2\n    |", first: "    End If")
checkVBA("Sub Test()\n    If x > 1 Then y = 2\n    |", first: "End Sub")
checkVBA("Sub Test()\n    If x > 1 Then ' check\n        y = 2\n    |", first: "    End If")
checkVBA("Sub Test()\n    With ws\n        .Name = \"A\"\n    |", first: "    End With")
checkVBA("Sub Test()\n    Do While x < 3\n        x = x + 1\n    |", first: "    Loop")
checkVBA("Sub Test()\n    For i = 1 To 3\n    Next i\n|", first: "End Sub")
checkVBA("Private Function Total(ByVal a As Long) As Long\n    |", first: "End Function")
checkVBA("Sub Test()\nEnd Sub\n|", first: nil)
checkVBA("Sub Test()\n    Dim totalSales As Double\n    tot|", first: "totalSales")
checkVBA("Sub Report(ByVal sheetName As String, rowCount As Long)\n    row|", first: "rowCount")
checkVBA("Sub Report(ByVal sheetName As String)\n    she|", first: "sheetName")
checkVBA("Sub Test()\n    lastr|", first: "lastRow = Cells(Rows.Count, \"A\").End(xlUp).Row")
checkVBA("Sub Test()\n    Range(\"A1\").|", first: nil)
checkVBA("Sub Test()\n    MsgBox \"for|", first: nil)
checkVBA("Sub Test()\n    ' for|", first: nil)
checkVBA("for| x", first: nil)
expect(vba("Sub Test()\n    Dim total As Long, totalTax As Long\n    tot|").map(\.text) == ["total", "totalTax"],
       "names from a Dim list")

// VBA checker
func lint(_ module: String) -> [String] {
    VBALinter.lint(module).map { "\($0.line): \($0.message)" }
}
func checkLint(_ module: String, _ expected: [String], line: Int = #line) {
    let got = lint(module)
    if got != expected {
        print("FAIL line \(line): lint \(module.debugDescription)\n  got      \(got)\n  expected \(expected)")
        failures += 1
    }
}
let cleanModule = """
    Option Explicit

    ' Copies totals; "Next j" in a comment must not count
    Public Sub CopyTotals(ByVal sheetName As String, Optional rowCount As Long = 10)
        Dim ws As Worksheet, i As Long, total As Double
        Dim label As String
        Set ws = ThisWorkbook.Worksheets(sheetName)
        label = "If (this) has no Then"
        For i = 1 To rowCount
            If ws.Cells(i, 1).Value > 0 Then total = total + ws.Cells(i, 1).Value
            If total > 100 Then
                Exit For
            ElseIf total < 0 Then
                total = 0
            Else
                total = total + 1
            End If
        Next i
        With ws.Range("A1:B2")
            .Value = total
        End With
        Select Case total
            Case Is > 10
                MsgBox "Big " & _
                    "total"
            Case Else
                Beep
        End Select
    End Sub

    Function Double2(x As Double) As Double
        Double2 = x * 2
    End Function
    """
checkLint(cleanModule, [])
checkLint("Sub A()\n    Dim i As Long, j As Long\n    For i = 1 To 3\n    Next j\nEnd Sub",
          ["4: Next j doesn't match For i"])
checkLint("Sub A()\n    If x > 1 Then\n        y = 2\n    Loop\nEnd Sub",
          ["4: Loop without a Do to close", "5: If on line 2 never got its End If"])
checkLint("Sub A()\n    For i = 1 To 3\n        If i > 1 Then\n    Next i\nEnd Sub",
          ["4: Next closes the For i from line 2, but If from line 3 is still open"])
checkLint("Sub A()\n    For i = 1 To 3\nEnd Sub", ["3: For i on line 2 never got its Next"])
checkLint("Function F()\n    F = 1\nEnd Sub", ["3: End Sub closes the Function from line 1: use End Function"])
checkLint("Sub A()\n    x = 1\nSub B()\nEnd Sub", ["3: Sub starts before the Sub from line 1 has ended"])
checkLint("Sub A()\n    If x > 1\n        y = 2\n    End If\nEnd Sub", ["2: If needs a Then at the end"])
checkLint("Sub A()\n    MsgBox (\"Hi\"\nEnd Sub", ["2: Missing a )"])
checkLint("Sub A()\n    y = (1 + 2))\nEnd Sub", ["2: One ) too many"])
checkLint("Sub A()\n    MsgBox \"Hi\nEnd Sub", ["2: This string is missing its closing \""])
checkLint("Sub A()\n    If x Then\n        y = 1\n    Edn If\nEnd Sub",
          ["4: Edn? Did you mean End?", "5: If on line 2 never got its End If"])
checkLint("Sub A()\n    Dimm x As Long\nEnd Sub", ["2: Dimm? Did you mean Dim?"])
checkLint("Fucntion F()\nEnd Function",
          ["1: Fucntion? Did you mean Function?", "2: End Function without a Function to close"])
checkLint("Sub A()\n    Dim ws As Worksheet\n    ws = Worksheets(\"Data\")\nEnd Sub", ["3: Objects need Set: Set ws = …"])
checkLint("Sub A()\n    Dim d\n    d = CreateObject(\"Scripting.Dictionary\")\nEnd Sub", ["3: Objects need Set: Set d = …"])
checkLint("Sub A()\n    Dim v As Variant\n    v = Range(\"A1\")\nEnd Sub", [])
checkLint("Option Explicit\nSub A()\n    total = 5\n    total = 6\n    For k = 1 To 2\n    Next k\nEnd Sub",
          ["3: total isn't declared (Option Explicit is on): add Dim total",
           "5: k isn't declared (Option Explicit is on): add Dim k"])
checkLint("Sub A()\n    total = 5\nEnd Sub", [])
checkLint("Sub A()\n    Range(\"A1\").Select\n    Dim lastRow As Integer\nEnd Sub",
          ["2: Tip: you rarely need .Select, work with the range directly",
           "3: Tip: use Long for lastRow: Integer stops at 32,767"])
checkLint("Sub A()\n    Else\n    Case 1\nEnd Sub", ["2: Else outside an If block", "3: Case outside a Select Case"])
checkLint("Sub A()\n    For i = 1 To 3\n        x = i", [])
checkLint("Sub A()\n    Calc 5\nEnd Sub\nSub Calc(n As Long)\nEnd Sub", [])

// Grumpy mode
let t0 = Date(timeIntervalSince1970: 1_000_000)
func mistake(_ key: String, line: Int = 3) -> VBAIssue { VBAIssue(line: line, message: "msg \(key)", kind: .mistake, key: key) }
var mood = Grumpiness()
let first = mood.lineFinished(with: mistake("a"), at: t0)
expect(first?.level == 1 && first?.face == "🙂" && first?.title == "Line 3 · msg a", "first mistake: a little grumpy")
expect(mood.lineFinished(with: mistake("a"), at: t0 + 5)?.remark == "Again. The same one.", "same mistake gets a jab")
_ = mood.lineFinished(with: mistake("b"), at: t0 + 10)
let furious = mood.lineFinished(with: mistake("c"), at: t0 + 15)
expect(furious?.level == 4 && furious?.face == "🤬", "keeps escalating to furious")
expect(mood.lineFinished(with: mistake("d"), at: t0 + 20)?.level == 4, "tops out at furious")
let r1 = mood.lineFinished(with: mistake("e"), at: t0 + 21)?.remark
let r2 = mood.lineFinished(with: mistake("f"), at: t0 + 22)?.remark
expect(r1 != nil && r1 != r2, "remarks don't repeat back to back")
for n in 0..<3 { expect(mood.lineFinished(with: nil, at: t0 + 30 + Double(n)) == nil, "clean lines are quiet") }
expect(mood.level == 3, "three clean lines calm it one level")
expect(mood.mistakeFixed(at: t0 + 40)?.remark == "Finally. 😮‍💨" && mood.level == 2, "a fix calms it and says so")
expect(mood.lineFinished(with: mistake("g"), at: t0 + 40 + Grumpiness.cooldown + 1)?.level == 1,
       "two quiet minutes reset it to calm before the next mistake")
let tip = VBAIssue(line: 2, message: "Tip: x", kind: .style, key: "select")
var calm = Grumpiness()
expect(calm.lineFinished(with: tip, at: t0)?.level == 0 && calm.level == 0, "tips show while calm and don't count")
_ = calm.lineFinished(with: mistake("a"), at: t0 + 1)
expect(calm.lineFinished(with: tip, at: t0 + 2) == nil, "no tips while grumpy")
var neutral = Grumpiness()
neutral.enabled = false
let plain = neutral.lineFinished(with: mistake("a"), at: t0)
expect(plain?.remark == nil && plain?.face == "⚠️" && neutral.level == 0, "grumpy mode off: plain warnings")

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
