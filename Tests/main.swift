// Run with: ./test.sh
import Foundation
var failures = 0

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

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
