# TypeMath

A tiny macOS menu bar app that answers maths wherever you type.

Type an equation ending in `=` in any app, ask a question ending in `?`, or highlight some maths, and the answer appears next to it.

| You type | Press | You get |
|---|---|---|
| `so it's 4*4 = ` | `=` | `so it's 4*4 = 16` |
| `so it's 4*4 = ` | `Tab` | `so it's 16` |
| `what's 15% of 80?` | `Tab` | `12` |
| `5 km in miles =` | `Tab` | `3.1069 miles` |
| `100 usd in eur =` | `Tab` | the amount in EUR at today's rate |
| `days until 25 dec =` | `Tab` | `35 days` |
| `f(x) = x^2` | `Tab` | a live graph; Tab copies it as an image |
| `12*7` highlighted | `Tab` | `84` |

## What it understands

- **Arithmetic:** `+ - * / x × ÷ ^ **`, brackets, implicit multiplication (`2(3+4)`, `2pi`), thousands commas (`1,000`).
- **Percent, calculator-style:** `200 + 10% =` gives 220; `200*15% =` gives 30; `15% of 80`; `20% off 50`.
- **Plain words:** `five plus three`, `10 divided by 4`, `2 to the power of 10`, `5 squared`, `square root of 81`, `half of 40`, `double 12`, `average of 3, 4 and 5`, `two hundred and fifty`, `1.5 million`. Lead-ins like "what is" and "calculate" are understood, and a question such as `what's 5 plus 3?` triggers on the `?`.
- **Functions and constants:** `sin cos tan asin acos atan sinh cosh tanh sqrt cbrt ln log log2 exp abs round floor ceil`, `5!`, `90°`, `pi π e tau`.
- **`ans`:** the last answer, e.g. `ans * 2 =`.
- **Dates:** `today + 30 days`, `3 weeks from 1 dec`, `10 days ago`, `days until 25 dec`, `days since 1 sep`, `days between 1 jan and 1 mar`.
- **Currency:** `100 usd in eur`, `$100 in eur`, `50€ to £`, `20 pounds in yen`. Daily European Central Bank rates via [frankfurter.dev](https://frankfurter.dev), cached for offline use.
- **Unit conversion:** `<amount> <unit> in|to|as <unit> =` across length, area, mass, volume, temperature, time, speed, energy, power, pressure, angle, frequency, data and data rate.
- **Graphs:** any expression in `x` ending in `=` (`x^2 - 4 =`), or a definition typed as `f(x) = …` or `y = …`, which graphs live as you type.

`x` means multiply between numbers (`4x4`, `4 x (2+3)`) and is the variable otherwise (`2x`, `x(x+1)`).

## VBA helper

In Excel's VBA editor, TypeMath switches from maths to code suggestions in a list below the line you're typing. ↑/↓ choose, Tab inserts, Esc closes.

- **Suggestions, all offline:**
  - block templates when a line is just a keyword (`for`, `for each`, `if`, `select`, `do`, `while`, `with`, `sub`, `function`, `on error`);
  - the matching `Next i` / `End If` / `Loop` / `End Sub` on an empty line inside an open block;
  - names already in your module;
  - common Excel lines (`lastrow`, `ws`, `msgbox`, …).

Member lists after `.` are left to the editor's own IntelliSense.

**Check My Code** looks at each line as you finish it and shows what's wrong and where, above the line. It catches:
- `Next j` after `For i`, blocks never closed, `End Sub` closing a Function;
- `If` without `Then`, missing `)`, unclosed strings;
- typos like `Edn If`;
- objects assigned without `Set`;
- undeclared variables under `Option Explicit`.

With **Grumpy Mode** on, it gets comically crankier with every new mistake (😊 → 🙂 → 😐 → 😤 → 🤬, shaking and turning red at the end). It calms down after three clean lines, a fix, or two quiet minutes. Both switches are under VBA Helper.

## Install

Requires macOS 13 or later and the Xcode command line tools.

```bash
./build.sh
open ~/Applications/TypeMath.app
```

On first launch, allow TypeMath in **System Settings → Privacy & Security → Accessibility**. It needs this to read what you type and to type answers in. It skips password fields.

Highlight maths in any app that exposes its text to show the answer: Tab replaces the selection with it, `=` adds ` = answer` after it.

From the menu bar icon you can open **History** (every question with its answer; click one to copy the answer), turn TypeMath off or off for the app you're in, choose the number format (thousands grouping, decimals) and open it at login. History is kept on this Mac only (last 100 answers) and can be cleared.

## Development

```bash
./test.sh
```

Runs the parser tests in `Tests/main.swift`.

- `Sources/Evaluator.swift`: finds and evaluates the equation before the cursor or in a selection; parser; units table.
- `Sources/Normalizer.swift`: rewrites words into maths ("15 percent of eighty" to `15%*80`).
- `Sources/Dates.swift`: date arithmetic.
- `Sources/Currency.swift`: exchange rates.
- `Sources/History.swift`, `Sources/HistoryView.swift`: saved answers and the History panel.
- `Sources/VBALinter.swift`, `Sources/Grumpiness.swift`: code checks and the mood.
- `Sources/VBASuggestions.swift`, `Sources/VBAContext.swift`: the VBA helper.
- `Sources/main.swift`: keyboard and mouse event tap, reading text and selections via Accessibility, typing answers, menu.
- `Sources/Popup.swift`: the answer and graph popup.

`build.sh` signs with an Apple Development certificate if you have one, so the Accessibility permission survives rebuilds. Without one it signs ad-hoc, and macOS asks for the permission again after each build.

## License

MIT
